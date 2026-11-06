-- Gate SQL-VIEWS, prod shape, after 04-prod-deny-base-objects.sql ran twice with @apply = 1. Each line starts with OK or
-- FAIL. run.sh generates /tmp/work/contract-lists.sql from ops-columns.json: #already_served, #deny_also and
-- #entity_sources, so these checks follow the contract rather than a second hand-kept list.
USE AppCatalog;
SET NOCOUNT ON;
GO
:r /tmp/work/contract-lists.sql
GO
DECLARE @r TABLE (line nvarchar(1000));
-- 1. Every object a dataapi view reads (walked through views and table-valued functions), and every deny-also object,
--    carries DENY SELECT for the DAB user; the already-served objects do not.
WITH deps AS (
    SELECT d.referenced_id AS object_id FROM sys.sql_expression_dependencies AS d JOIN sys.objects AS o ON o.object_id = d.referencing_id
    WHERE o.schema_id = SCHEMA_ID(N'dataapi') AND d.referenced_id IS NOT NULL
    UNION ALL
    SELECT d.referenced_id FROM deps JOIN sys.objects AS ro ON ro.object_id = deps.object_id AND ro.type IN ('V', 'IF', 'TF')
    JOIN sys.sql_expression_dependencies AS d ON d.referencing_id = deps.object_id WHERE d.referenced_id IS NOT NULL AND d.referenced_id <> d.referencing_id),
t AS (SELECT DISTINCT o.object_id FROM deps JOIN sys.objects AS o ON o.object_id = deps.object_id
      WHERE o.schema_id <> SCHEMA_ID(N'dataapi') AND o.type IN ('U', 'V', 'IF', 'TF')
        AND NOT EXISTS (SELECT 1 FROM #already_served AS s WHERE OBJECT_ID(s.n) = o.object_id)
      UNION SELECT OBJECT_ID(n) FROM #deny_also WHERE OBJECT_ID(n) IS NOT NULL)
INSERT @r
SELECT CASE WHEN COUNT(*) > 0 AND SUM(CASE WHEN p.major_id IS NULL THEN 1 ELSE 0 END) = 0
            THEN CONCAT('OK 04 denied svc_dataapi all ', COUNT(*), ' objects behind the views (and the deny-also objects)')
            ELSE CONCAT('FAIL ', SUM(CASE WHEN p.major_id IS NULL THEN 1 ELSE 0 END), ' of ', COUNT(*), ' objects behind the views have no DENY') END
FROM t LEFT JOIN sys.database_permissions AS p
  ON p.major_id = t.object_id AND p.minor_id = 0 AND p.permission_name = N'SELECT' AND p.state = 'D'
 AND p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'svc_dataapi')
OPTION (MAXRECURSION 20);
INSERT @r
SELECT CASE WHEN COUNT(*) = 0 THEN CONCAT('OK no already-served object is denied (', (SELECT COUNT(*) FROM #already_served), ' listed)')
            ELSE CONCAT('FAIL ', COUNT(*), ' already-served objects were denied') END
FROM sys.database_permissions AS p JOIN #already_served AS s ON OBJECT_ID(s.n) = p.major_id
WHERE p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'svc_dataapi') AND p.state = 'D';
-- 2. Not vacuous: each entity's own source object, as the contract names it, carries the DENY.
INSERT @r
SELECT CASE WHEN OBJECT_ID(e.n) IS NULL THEN CONCAT(N'FAIL entity source not found: ', e.n)
            WHEN EXISTS (SELECT 1 FROM sys.database_permissions AS p
                         WHERE p.major_id = OBJECT_ID(e.n) AND p.minor_id = 0 AND p.state = 'D' AND p.permission_name = N'SELECT'
                           AND p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'svc_dataapi'))
            THEN CONCAT(N'OK DENY on entity source ', e.n) ELSE CONCAT(N'FAIL no DENY on entity source ', e.n) END
FROM #entity_sources AS e;
SELECT line FROM @r;
GO
-- 3. As the DAB user: every base object and the deny-also view is refused with Msg 229; every view still reads
--    (ownership chaining), and so does the curated stored procedure that reads core.Account.
DECLARE @r TABLE (line nvarchar(1000));
DECLARE @o nvarchar(300), @s nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT v FROM (VALUES
    (N'core.Account'), (N'core.AppUser'), (N'svc.Webhook'), (N'ref.MessageTemplate'), (N'ref.Country'), (N'ref.Route'),
    (N'ref.AccountRouteOverride'), (N'core.vwAppUserDirectory'), (N'ref.fnAccountRoute(NULL)')) AS x(v);
OPEN c; FETCH NEXT FROM c INTO @o;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @s = N'SELECT TOP (1) * FROM ' + @o + N';';
    BEGIN TRY
        EXECUTE AS USER = N'svc_dataapi';
        EXEC sys.sp_executesql @s;
        REVERT;
        INSERT @r VALUES (CONCAT(N'FAIL svc_dataapi can read ', @o));
    END TRY
    BEGIN CATCH
        IF USER_NAME() = N'svc_dataapi' REVERT;
        INSERT @r VALUES (CONCAT(IIF(ERROR_NUMBER() = 229, N'OK ', N'FAIL '), @o, N' refused to svc_dataapi: Msg ', ERROR_NUMBER()));
    END CATCH;
    FETCH NEXT FROM c INTO @o;
END;
CLOSE c; DEALLOCATE c;
DECLARE @v nvarchar(300), @bad int = 0, @n int = 0;
DECLARE w CURSOR LOCAL FAST_FORWARD FOR
    SELECT QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + N'.' + QUOTENAME(name) FROM sys.views WHERE schema_id = SCHEMA_ID(N'dataapi');
OPEN w; FETCH NEXT FROM w INTO @v;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @n += 1;
    SET @s = N'SELECT TOP (1) * FROM ' + @v + N';';
    BEGIN TRY
        EXECUTE AS USER = N'svc_dataapi';
        EXEC sys.sp_executesql @s;
        REVERT;
    END TRY
    BEGIN CATCH
        IF USER_NAME() = N'svc_dataapi' REVERT;
        SET @bad += 1;
        INSERT @r VALUES (CONCAT(N'FAIL ', @v, N' no longer reads as svc_dataapi: Msg ', ERROR_NUMBER(), N' ', ERROR_MESSAGE()));
    END CATCH;
    FETCH NEXT FROM w INTO @v;
END;
CLOSE w; DEALLOCATE w;
IF @bad = 0 INSERT @r VALUES (CONCAT(N'OK all ', @n, N' dataapi views still read as svc_dataapi (ownership chaining)'));
BEGIN TRY
    EXECUTE AS USER = N'svc_dataapi';
    EXEC core.Account_GetByUid @AccountUid = 'AAAAAAAA-0000-0000-0000-000000000001';
    REVERT;
    INSERT @r VALUES (N'OK the curated stored procedure core.Account_GetByUid still runs as svc_dataapi');
END TRY
BEGIN CATCH
    IF USER_NAME() = N'svc_dataapi' REVERT;
    INSERT @r VALUES (CONCAT(N'FAIL core.Account_GetByUid as svc_dataapi: Msg ', ERROR_NUMBER(), N' ', ERROR_MESSAGE()));
END CATCH;
SELECT line FROM @r;
GO
-- 4. Running 04 twice changed nothing: the DENY count is stable (run.sh compares it with the count after the first run).
SELECT CONCAT('OK svc_dataapi DENY count: ', COUNT(*)) FROM sys.database_permissions
WHERE grantee_principal_id = DATABASE_PRINCIPAL_ID(N'svc_dataapi') AND state = 'D';
GO
