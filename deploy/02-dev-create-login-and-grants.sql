/* ============================================================================
   appdb-data-api — DEV login: STRICT READ-ONLY across ALL dev databases
   ----------------------------------------------------------------------------
   Run on DEV-NODE1 (192.0.2.22). Replace <StrongPwd> with a value from the
   dev secret store.

   PURPOSE (2026-08-13): dev_svc_dataapi gets READ-ONLY access to EVERY user
   database on the dev instance — SELECT on all tables/views, read functions/TVFs,
   EXECUTE read stored procedures, and VIEW DEFINITION — with NO write path.
   This SUPERSEDES the earlier "EXECUTE on 6 curated procs" grant for dev.

   STRICT READ-ONLY is enforced by:
     - Membership: db_datareader ONLY, plus db_denydatawriter (explicit DENY of
       direct INSERT/UPDATE/DELETE). NO db_datawriter / db_ddladmin / db_owner and
       NO server roles (no sysadmin).
     - Connection uses ApplicationIntent=ReadOnly (physical read-only guard on an AG
       secondary; a harmless no-op on single-node dev).
     - CAVEAT — GRANT EXECUTE is object-blind: it lets the login run any read proc/
       function, but a stored procedure that ITSELF writes can still write via
       ownership chaining (db_denydatawriter only blocks DIRECT DML). This residual
       is accepted in DEV (test data, single node). For ABSOLUTE strictness, delete
       the "GRANT EXECUTE" line below — reads still work via db_datareader + SELECT,
       but SP-/scalar-function-backed tools that need EXECUTE will stop.

   DEV-ONLY. Prod/staging keep the curated least-privilege posture (01/03 scripts):
   this broad read-only grant is deliberately dev-scoped.

   Covers all 15 dev user databases as of 2026-08-13 (AppDb_dev, AppDb_Data_dev,
   AppDb_Analytics_dev, AppDb_Routing_dev, AppDb_Fax_dev, AppDb_Fax_data_dev, AppDb_VIDEO_dev,
   AppDb_Support_dev, AppDb_ChatHelpdesk_DEV, AppDb_SIT, AppDb_Test, SIGNAL_DEV, DBA, HEAP,
   CdataGSheets) — the loop grants on whatever online user DBs exist, so new dev DBs
   are picked up on re-run.
   ============================================================================ */

/* ---- 1) Server login (SQL auth). No server roles, no sysadmin. ------------- */
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'dev_svc_dataapi')
    CREATE LOGIN dev_svc_dataapi WITH PASSWORD = N'<StrongPwd>', CHECK_POLICY = ON;
GO

/* ---- 2) STRICT read-only user in EVERY online, writeable user database ------ */
DECLARE @db sysname, @sql nvarchar(max);
DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE database_id > 4                 -- skip master / tempdb / model / msdb
      AND state_desc = 'ONLINE'
      AND is_read_only = 0
      AND source_database_id IS NULL       -- skip database snapshots
      AND name <> N'distribution';
OPEN dbs;
FETCH NEXT FROM dbs INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
USE ' + QUOTENAME(@db) + N';
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''dev_svc_dataapi'')
    CREATE USER dev_svc_dataapi FOR LOGIN dev_svc_dataapi;
IF NOT EXISTS (SELECT 1 FROM sys.database_role_members m
               JOIN sys.database_principals r ON r.principal_id = m.role_principal_id
               JOIN sys.database_principals u ON u.principal_id = m.member_principal_id
               WHERE r.name = N''db_datareader'' AND u.name = N''dev_svc_dataapi'')
    ALTER ROLE db_datareader ADD MEMBER dev_svc_dataapi;         -- SELECT on all tables + views
IF NOT EXISTS (SELECT 1 FROM sys.database_role_members m
               JOIN sys.database_principals r ON r.principal_id = m.role_principal_id
               JOIN sys.database_principals u ON u.principal_id = m.member_principal_id
               WHERE r.name = N''db_denydatawriter'' AND u.name = N''dev_svc_dataapi'')
    ALTER ROLE db_denydatawriter ADD MEMBER dev_svc_dataapi;     -- explicit DENY of direct DML
GRANT SELECT          TO dev_svc_dataapi;   -- TVFs / any SELECTable object beyond tables+views
GRANT EXECUTE         TO dev_svc_dataapi;   -- run read procs + functions (dev; see CAVEAT in header)
GRANT VIEW DEFINITION TO dev_svc_dataapi;   -- see object definitions (SPs, functions, views)
';
    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM dbs INTO @db;
END
CLOSE dbs;
DEALLOCATE dbs;
GO

/* The old curated role role_dev_svc_dataapi (6 EXECUTE grants in AppDb_dev) is now
   superseded by the database-wide GRANT EXECUTE above. It is harmless (a subset) but
   can be dropped for cleanliness:
     USE AppDb_dev; ALTER ROLE role_dev_svc_dataapi DROP MEMBER dev_svc_dataapi; DROP ROLE role_dev_svc_dataapi; */

/* ---- 3) Verify: read roles held per database ------------------------------- */
/* Expect each dev DB to show EXACTLY db_datareader + db_denydatawriter.
   Any db_datawriter / db_owner / db_ddladmin here is a problem. */
IF OBJECT_ID('tempdb..#roles') IS NOT NULL DROP TABLE #roles;
CREATE TABLE #roles (db sysname, role_name sysname);
DECLARE @d sysname, @q nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE database_id > 4 AND state_desc = 'ONLINE' AND is_read_only = 0
      AND source_database_id IS NULL AND name <> N'distribution';
OPEN c;
FETCH NEXT FROM c INTO @d;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @q = N'USE ' + QUOTENAME(@d) + N';
INSERT INTO #roles (db, role_name)
SELECT DB_NAME(), r.name
FROM sys.database_role_members m
JOIN sys.database_principals r ON r.principal_id = m.role_principal_id
JOIN sys.database_principals u ON u.principal_id = m.member_principal_id
WHERE u.name = N''dev_svc_dataapi'';';
    EXEC sys.sp_executesql @q;
    FETCH NEXT FROM c INTO @d;
END
CLOSE c;
DEALLOCATE c;
SELECT db, role_name FROM #roles ORDER BY db, role_name;
GO

/* Connection (dev, config/dab-config.dev.json -> @env('CONN_DEV')):
     Server=192.0.2.22,1433;Database=AppDb_dev;User ID=dev_svc_dataapi;Password=<StrongPwd>;
     ApplicationIntent=ReadOnly;Encrypt=True;TrustServerCertificate=True;Application Name=appdb-data-api
   Database=AppDb_dev is only the initial catalog — the login can now read every dev DB.
   ApplicationIntent=ReadOnly is harmless on single-node dev (no read-only routing).
   Server=IP + TrustServerCertificate=True because the dev cert isn't trusted / name may
   not resolve from the pod; switch to hostname + False only if the cert is trusted and resolvable. */
