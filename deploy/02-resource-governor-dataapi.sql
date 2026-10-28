/* ============================================================================
   appdb-data-api — Resource Governor fence for the svc_dataapi login
   ----------------------------------------------------------------------------
   WHY
     A read API in front of a large, partitioned log table is one unbounded
     filter away from a full scan. The caller (an agent gateway, a CI gate, the
     curated stored procedures) is the first line that keeps every read bounded;
     this script is the BLAST-RADIUS layer for anything that still gets through:
     a runaway read is held to a small, low-importance slice of the instance
     instead of competing with the application on equal terms.

   WHAT IT FIXES
     - An unclassified login lands in the `default` workload group, which ships
       with MAX_DOP = 0 (one parallel scan can take every scheduler),
       GROUP_MAX_REQUESTS = 0 (unlimited concurrency), CAP_CPU_PERCENT = 100 and
       REQUEST_MAX_CPU_TIME_SEC = 0. Check yours:
         SELECT name, max_dop, group_max_requests, request_max_cpu_time_sec
         FROM sys.resource_governor_workload_groups;
     - MAX_IOPS_PER_VOLUME = 0 on the stock pools, so physical I/O is ungoverned.
       On an I/O-bound host a CPU cap tunes the wrong dial: the symptom is a low
       runnable-task count while hundreds of workers wait on PAGEIOLATCH_*.

   WHERE TO RUN
     EVERY replica the API can connect to. Resource Governor is instance-level
     configuration and is NOT replicated by an availability group. The API
     connects with ApplicationIntent=ReadOnly, so read-only routing lands it on
     whichever replica is the readable secondary at the time: configure only one
     node and the API runs ungoverned the moment the AG fails over.

   CLASSIFIER
     PART C handles both cases. With no classifier attached it creates and
     attaches dbo.rgClassifier_DataApi. With one already attached it injects ONE
     branch into that function, after the anchor statement named in PART C, and
     leaves the rest of the body byte-for-byte as it was.

   OBJECTS IT CREATES (all instance-level, in master)
     - resource pool rp_dataapi and workload group rg_dataapi (PARTS A and B);
     - function dbo.rgClassifier_DataApi — only when no classifier was attached;
     - table master.dbo.DataApi_RgClassifierBackup — only when it splices into an
       existing classifier: one row (function_name, definition_backup, taken_at)
       holding that function's body as it was before each change. PART F restores
       the body from the newest row and then drops the table. Nothing else
       reads it; keep it until the change has been verified on every node.

   SAFETY
     Online. No restart. Re-runnable: each part checks before it changes
     anything. Reversible — see PART F.
   ============================================================================ */
SET NOCOUNT ON;
USE master;
GO

/* ---------------------------------------------------------------------------
   PART A — resource pool
   MAX_IOPS_PER_VOLUME is the only Resource Governor knob that touches PHYSICAL
   I/O. It is per volume, so if the database's data files share one volume this
   figure is the API's whole read budget for that volume.

   Size it from the host, not from this file. Start at a small multiple (2-3x)
   of the database's current average read IOPS — ample for bounded point
   lookups (a key seek is a handful of I/Os) while holding a runaway scan well
   below the volume's saturation point. Measure before choosing or changing it
   (replace AppDb_Data with the database the API reads):
     SELECT SUM(vfs.num_of_reads) / NULLIF(DATEDIFF(SECOND, si.sqlserver_start_time, SYSDATETIME()), 0)
            AS avg_read_iops_since_start
     FROM sys.dm_io_virtual_file_stats(DB_ID(N'AppDb_Data'), NULL) AS vfs
     CROSS JOIN sys.dm_os_sys_info AS si;
   --------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.resource_governor_resource_pools WHERE name = N'rp_dataapi')
BEGIN
    CREATE RESOURCE POOL rp_dataapi
    WITH (MIN_CPU_PERCENT        = 0,
          CAP_CPU_PERCENT        = 10,    -- hard ceiling, cannot burst above it
          MIN_MEMORY_PERCENT     = 0,
          MAX_MEMORY_PERCENT     = 5,
          MIN_IOPS_PER_VOLUME    = 0,
          MAX_IOPS_PER_VOLUME    = 500);  -- the I/O fence: re-size it from the query above
    PRINT 'Created resource pool rp_dataapi.';
END
ELSE
BEGIN
    ALTER RESOURCE POOL rp_dataapi
    WITH (MIN_CPU_PERCENT = 0, CAP_CPU_PERCENT = 10,
          MIN_MEMORY_PERCENT = 0, MAX_MEMORY_PERCENT = 5,
          MIN_IOPS_PER_VOLUME = 0, MAX_IOPS_PER_VOLUME = 500);
    PRINT 'Updated existing resource pool rp_dataapi.';
END
GO

/* ---------------------------------------------------------------------------
   PART B — workload group
   MAX_DOP 1 x GROUP_MAX_REQUESTS 4 is the worker fence: the API tops out at
   about four workers. Ungoverned, one parallel scan of a large table can take
   every scheduler, with no limit on how many run at once — the worker-pinning
   shape behind THREADPOOL waits and login timeouts for everyone else.

   NOTE on REQUEST_MAX_CPU_TIME_SEC: it bounds CPU time, so it does NOT catch an
   I/O-bound runaway (which accrues little CPU). The reliable kill for that is a
   client-side command timeout on the API's connection (Command Timeout=30 in
   each CONN_* connection string). Both layers are needed; neither replaces the
   other. Without trace flag 2422 the CPU limit only raises an event (PART D).
   --------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.resource_governor_workload_groups WHERE name = N'rg_dataapi')
BEGIN
    CREATE WORKLOAD GROUP rg_dataapi
    WITH (IMPORTANCE                       = LOW,
          MAX_DOP                          = 1,   -- never parallel-scan the log tables
          GROUP_MAX_REQUESTS               = 4,   -- concurrency ceiling
          REQUEST_MAX_CPU_TIME_SEC         = 30,  -- enforced only with TF 2422 (PART D)
          REQUEST_MAX_MEMORY_GRANT_PERCENT = 5)
    USING rp_dataapi;
    PRINT 'Created workload group rg_dataapi.';
END
ELSE
BEGIN
    ALTER WORKLOAD GROUP rg_dataapi
    WITH (IMPORTANCE = LOW, MAX_DOP = 1, GROUP_MAX_REQUESTS = 4,
          REQUEST_MAX_CPU_TIME_SEC = 30, REQUEST_MAX_MEMORY_GRANT_PERCENT = 5)
    USING rp_dataapi;
    PRINT 'Updated existing workload group rg_dataapi.';
END
GO

/* ---------------------------------------------------------------------------
   PART C — classifier branch

   Case 1, no classifier attached: create dbo.rgClassifier_DataApi (the API's
   branch, everything else to `default`) and attach it.

   Case 2, a classifier is already attached (it routes other logins and jobs):
   inject ONE branch into it. The branch is spliced in PROGRAMMATICALLY right
   after @anchor in the CURRENT definition and returns early, rather than being
   hand-retyped into an IF/ELSE chain, so everything the function already does
   is preserved byte-for-byte. Set @anchor to a statement that appears EXACTLY
   ONCE in the function body, at a point where an early RETURN is safe (its
   first DECLARE is the usual choice). The script stops, with the instance
   unchanged, when the anchor is missing or appears more than once.

   The branch must NOT carry a primary-only test (for example a check that the
   database is READ_WRITE) the way some ad-hoc-user branches do: the API reads
   the readable SECONDARY, so a primary-only test would leave it ungoverned
   exactly where it runs.

   APP_NAME() is client-supplied, so any login can claim the API's application
   name. That is harmless here: the branch only ever moves a session INTO a
   smaller, low-importance group. Never use APP_NAME() to grant anything.
   --------------------------------------------------------------------------- */
DECLARE @anchor   nvarchar(400) = N'DECLARE @app NVARCHAR(128) = APP_NAME();';   -- Case 2 only: edit to match your classifier
DECLARE @crlf     nchar(2)      = NCHAR(13) + NCHAR(10);
DECLARE @fn_id    int           = (SELECT classifier_function_id FROM sys.resource_governor_configuration);
DECLARE @fn_name  nvarchar(600);
DECLARE @def      nvarchar(max);
DECLARE @branch   nvarchar(max);
DECLARE @newdef   nvarchar(max);
DECLARE @head     int;
DECLARE @attach   nvarchar(max);
DECLARE @detach   nvarchar(max) = N'ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = NULL); ALTER RESOURCE GOVERNOR RECONFIGURE;';

IF @fn_id = 0
BEGIN
    -- Case 1. A classifier must live in master and be schema-bound.
    IF OBJECT_ID(N'dbo.rgClassifier_DataApi', N'FN') IS NULL
        EXEC (N'CREATE FUNCTION dbo.rgClassifier_DataApi()
RETURNS sysname
WITH SCHEMABINDING
AS
BEGIN
    -- appdb-data-api: governed on PRIMARY *and* SECONDARY (no Updateability test).
    IF APP_NAME() LIKE N''appdb-data-api%'' OR SUSER_SNAME() = N''svc_dataapi''
        RETURN N''rg_dataapi'';
    RETURN N''default'';
END');
    ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = dbo.rgClassifier_DataApi);
    ALTER RESOURCE GOVERNOR RECONFIGURE;
    PRINT 'No classifier was attached: created and attached dbo.rgClassifier_DataApi.';
END
ELSE
BEGIN
    -- Case 2.
    SET @fn_name = QUOTENAME(OBJECT_SCHEMA_NAME(@fn_id)) + N'.' + QUOTENAME(OBJECT_NAME(@fn_id));
    SET @def     = OBJECT_DEFINITION(@fn_id);
    SET @attach  = N'ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = ' + @fn_name
                 + N'); ALTER RESOURCE GOVERNOR RECONFIGURE;';

    IF @def IS NULL
        THROW 50001, 'The attached classifier''s definition is not readable (encrypted, or no permission). Insert the branch by hand.', 1;

    IF @def LIKE N'%rg_dataapi%'
        PRINT 'Classifier ' + @fn_name + ' already routes rg_dataapi — no change.';
    ELSE
    BEGIN
        IF CHARINDEX(@anchor, @def) = 0
            THROW 50002, 'Classifier anchor not found. Set @anchor in PART C to a statement in the attached classifier, or insert the branch by hand.', 1;

        -- REPLACE swaps EVERY occurrence, so a duplicated anchor would inject the
        -- branch twice. Require exactly one.
        IF (LEN(@def) - LEN(REPLACE(@def, @anchor, N''))) / LEN(@anchor) <> 1
            THROW 50003, 'Classifier anchor appears more than once — insert the branch by hand.', 1;

        -- The stored definition starts with CREATE FUNCTION, however the function was
        -- created or last altered (SQL Server stores ALTER and CREATE OR ALTER as CREATE).
        -- Turn that first header into ALTER FUNCTION; refuse anything else.
        SET @head = PATINDEX(N'%CREATE%FUNCTION%', @def);
        IF @head = 0 OR LTRIM(REPLACE(REPLACE(REPLACE(SUBSTRING(@def, @head + 6, CHARINDEX(N'FUNCTION', @def, @head) - @head - 6),
                                                      NCHAR(9), N''), NCHAR(13), N''), NCHAR(10), N'')) <> N''
            THROW 50004, 'Could not find the CREATE FUNCTION header of the attached classifier — insert the branch by hand.', 1;

        -- Keep the current body before touching it (one row per change).
        IF OBJECT_ID(N'dbo.DataApi_RgClassifierBackup', N'U') IS NULL
            CREATE TABLE dbo.DataApi_RgClassifierBackup (
                function_name     nvarchar(600) NOT NULL,
                definition_backup nvarchar(max) NOT NULL,
                taken_at          datetime2(3)  NOT NULL DEFAULT SYSUTCDATETIME());
        INSERT dbo.DataApi_RgClassifierBackup (function_name, definition_backup) VALUES (@fn_name, @def);

        SET @branch = @anchor + @crlf
            + N'    -- appdb-data-api: governed on PRIMARY *and* SECONDARY (no Updateability test).' + @crlf
            + N'    IF APP_NAME() LIKE N''appdb-data-api%'' OR SUSER_SNAME() = N''svc_dataapi''' + @crlf
            + N'        RETURN N''rg_dataapi'';';
        SET @newdef = STUFF(@def, @head, CHARINDEX(N'FUNCTION', @def, @head) + 8 - @head, N'ALTER FUNCTION');
        SET @newdef = REPLACE(@newdef, @anchor, @branch);

        /* The function CANNOT be altered while it is the live classifier (Msg 10920:
           "It is being used as a resource governor classifier"), so detach it, alter,
           reattach.

           WINDOW: between detach and reattach NO classifier runs, so a login arriving
           in those milliseconds lands in `default` (ungoverned) for the life of its
           session. Existing sessions keep the group they already have. Run this in a
           quiet moment. The CATCH puts the classifier back even if the ALTER fails —
           never leave the instance unclassified. */
        EXEC (@detach);
        BEGIN TRY
            EXEC sys.sp_executesql @newdef;
        END TRY
        BEGIN CATCH
            EXEC (@attach);
            PRINT 'ALTER failed — original classifier reattached, no change applied.';
            THROW;
        END CATCH
        EXEC (@attach);
        PRINT 'Classifier ' + @fn_name + ' updated with the rg_dataapi branch.';
    END
END
GO

-- Applies PARTS A and B even when PART C changed nothing.
ALTER RESOURCE GOVERNOR RECONFIGURE;
GO

/* ---------------------------------------------------------------------------
   PART D — trace flag 2422
   Without it REQUEST_MAX_CPU_TIME_SEC only RAISES AN EVENT; it does not abort
   the request. TF 2422 makes Resource Governor actually terminate a request
   that exceeds the limit.

   DBCC TRACEON(-1) is instance-wide but lasts only until the next restart.
   Persist it as a -T2422 startup parameter too, or the fence silently weakens
   after the next reboot or patch cycle: 03-enable-tf2422.ps1 does both without
   a restart, and checks that no existing startup trace flag is lost.
   --------------------------------------------------------------------------- */
DBCC TRACEON (2422, -1) WITH NO_INFOMSGS;
GO

/* ---------------------------------------------------------------------------
   PART E — verification (run on EACH node after applying)
   --------------------------------------------------------------------------- */
-- 1. Pool + group settings, CONFIGURED vs RUNNING.
--    The sys.resource_governor_* views show what was *asked for*; the
--    sys.dm_resource_governor_* views show what is actually *in force*. They
--    differ if RECONFIGURE did not apply — which is exactly the failure this
--    check exists to catch, so compare both rather than trusting the first.
SELECT 'CONFIGURED' AS state, wg.name AS workload_group, rp.name AS pool,
       wg.max_dop, wg.group_max_requests, wg.request_max_cpu_time_sec,
       rp.cap_cpu_percent, rp.max_memory_percent, rp.max_iops_per_volume
FROM sys.resource_governor_workload_groups wg
JOIN sys.resource_governor_resource_pools rp ON rp.pool_id = wg.pool_id
WHERE wg.name = N'rg_dataapi'
UNION ALL
SELECT 'RUNNING', wg.name, rp.name,
       wg.max_dop, wg.group_max_requests, wg.request_max_cpu_time_sec,
       rp.cap_cpu_percent, rp.max_memory_percent, rp.max_iops_per_volume
FROM sys.dm_resource_governor_workload_groups wg
JOIN sys.dm_resource_governor_resource_pools rp ON rp.pool_id = wg.pool_id
WHERE wg.name = N'rg_dataapi';
-- EXPECT: TWO identical rows — max_dop 1, group_max_requests 4,
--         request_max_cpu_time_sec 30, cap_cpu_percent 10,
--         max_memory_percent 5, max_iops_per_volume 500 (or your sizing).
-- Only CONFIGURED present, or the two disagreeing => RECONFIGURE did not apply.

-- 1b. A classifier is attached (it is set to NULL briefly during PART C).
SELECT CASE WHEN classifier_function_id = 0 THEN 'NONE - everything lands in default!'
            ELSE 'attached: ' + QUOTENAME(OBJECT_SCHEMA_NAME(classifier_function_id)) + '.'
                 + QUOTENAME(OBJECT_NAME(classifier_function_id)) END AS classifier, is_enabled
FROM sys.resource_governor_configuration;
-- EXPECT: attached / is_enabled = 1

-- 2. TF 2422 active
DBCC TRACESTATUS (2422) WITH NO_INFOMSGS;   -- EXPECT: Status 1, Global 1

-- 3. THE REAL TEST — a live API session must land in rg_dataapi, not default.
--    Run while the API holds connections (DAB keeps a pool open).
SELECT s.session_id, s.login_name, s.program_name, wg.name AS workload_group
FROM sys.dm_exec_sessions s
JOIN sys.dm_resource_governor_workload_groups wg ON wg.group_id = s.group_id
WHERE s.login_name = N'svc_dataapi';
-- EXPECT: workload_group = rg_dataapi. 'default' means the classifier did not
-- match — check APP_NAME() actually arrives as 'appdb-data-api' (it is set by
-- `Application Name=appdb-data-api` in the CONN_* connection strings).

/* ---------------------------------------------------------------------------
   PART F — rollback
   ---------------------------------------------------------------------------
   -- Case 1 (this script created the classifier): detach and drop it.
   --   ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = NULL);
   --   ALTER RESOURCE GOVERNOR RECONFIGURE;
   --   DROP FUNCTION dbo.rgClassifier_DataApi;
   --
   -- Case 2 (the branch was injected): restore the previous body verbatim. The
   -- stored text starts with CREATE FUNCTION, so turn that header into ALTER first,
   -- and detach the classifier around the ALTER (Msg 10920):
   --   DECLARE @old nvarchar(max), @fn nvarchar(600);
   --   SELECT TOP (1) @old = definition_backup, @fn = function_name
   --   FROM dbo.DataApi_RgClassifierBackup ORDER BY taken_at DESC;
   --   SET @old = STUFF(@old, PATINDEX(N'%CREATE%FUNCTION%', @old),
   --                    CHARINDEX(N'FUNCTION', @old, PATINDEX(N'%CREATE%FUNCTION%', @old)) + 8
   --                    - PATINDEX(N'%CREATE%FUNCTION%', @old), N'ALTER FUNCTION');
   --   ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = NULL);
   --   ALTER RESOURCE GOVERNOR RECONFIGURE;
   --   EXEC sys.sp_executesql @old;
   --   EXEC (N'ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = ' + @fn + N');');
   --   ALTER RESOURCE GOVERNOR RECONFIGURE;
   --   -- Check the classifier is attached and no longer names rg_dataapi (PART E 1b), then
   --   -- drop the backup table this script created:
   --   DROP TABLE dbo.DataApi_RgClassifierBackup;
   --
   -- Then (optional) remove the pool, the group and the trace flag:
   --   DROP WORKLOAD GROUP rg_dataapi;
   --   DROP RESOURCE POOL  rp_dataapi;
   --   ALTER RESOURCE GOVERNOR RECONFIGURE;
   --   DBCC TRACEOFF (2422, -1);
   --------------------------------------------------------------------------- */
