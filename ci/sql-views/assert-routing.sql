-- Gate SQL-VIEWS, prod shape: the function-backed view (02-dataapi-routing-views.sql). Run as sa after the fixture and
-- 01-03, before 04: the DAB user holds no grant on the ref objects, so they are refused already. Each line starts with
-- OK or FAIL; the call-count table is printed for the log.
USE AppCatalog;
SET NOCOUNT ON;
GO
-- 1. As the DAB user: the view reads, its startup read works, and the function and its tables are refused.
DECLARE @r TABLE (line nvarchar(1000));
EXECUTE AS USER = N'svc_dataapi';
BEGIN TRY
    EXEC (N'SET FMTONLY ON; SELECT * FROM dataapi.vw_AccountRoute; SET FMTONLY OFF;');
    INSERT @r VALUES (N'OK FMTONLY SELECT * on dataapi.vw_AccountRoute');
END TRY BEGIN CATCH INSERT @r VALUES (CONCAT(N'FAIL FMTONLY: Msg ', ERROR_NUMBER(), N' ', ERROR_MESSAGE())); END CATCH;
BEGIN TRY
    DECLARE @x int = (SELECT COUNT(*) FROM ref.fnAccountRoute('AAAAAAAA-0000-0000-0000-000000000001'));
    INSERT @r VALUES (N'FAIL the DAB user can call ref.fnAccountRoute directly (it serves CostPerMessage)');
END TRY BEGIN CATCH INSERT @r VALUES (CONCAT(N'OK ref.fnAccountRoute refused to the DAB user: Msg ', ERROR_NUMBER())); END CATCH;
BEGIN TRY
    DECLARE @y int = (SELECT COUNT(*) FROM ref.Route);
    INSERT @r VALUES (N'FAIL the DAB user can read ref.Route');
END TRY BEGIN CATCH INSERT @r VALUES (CONCAT(N'OK ref.Route refused to the DAB user: Msg ', ERROR_NUMBER())); END CATCH;
REVERT;
SELECT line FROM @r;
GO
-- 2. The rows equal the function's own answer per account: an override beats the default, an inactive route never applies.
DECLARE @exp TABLE (AccountUid uniqueidentifier, CountryCode char(2), RouteId int, RouteName varchar(50), IsOverride bit);
INSERT @exp VALUES
    ('AAAAAAAA-0000-0000-0000-000000000001', 'FR', 2, 'fr-premium', 1),   -- the account's override
    ('AAAAAAAA-0000-0000-0000-000000000001', 'JP', 3, 'jp-default', 0),   -- its JP override points at an inactive route
    ('AAAAAAAA-0000-0000-0000-000000000001', 'AU', 5, 'au-default', 0),
    ('AAAAAAAA-0000-0000-0000-000000000002', 'FR', 1, 'fr-default', 0),   -- no overrides
    ('AAAAAAAA-0000-0000-0000-000000000002', 'JP', 3, 'jp-default', 0),
    ('AAAAAAAA-0000-0000-0000-000000000002', 'AU', 5, 'au-default', 0);   -- the BR default is inactive: no BR row
DECLARE @got TABLE (AccountUid uniqueidentifier, CountryCode char(2), RouteId int, RouteName varchar(50), IsOverride bit);
EXECUTE AS USER = N'svc_dataapi';
INSERT @got SELECT AccountUid, CountryCode, RouteId, RouteName, IsOverride FROM dataapi.vw_AccountRoute
WHERE AccountUid IN ('AAAAAAAA-0000-0000-0000-000000000001', 'AAAAAAAA-0000-0000-0000-000000000002');
REVERT;
SELECT CASE WHEN NOT EXISTS (SELECT * FROM @exp EXCEPT SELECT * FROM @got) AND NOT EXISTS (SELECT * FROM @got EXCEPT SELECT * FROM @exp)
            THEN 'OK routing rows match the expected 6' ELSE CONCAT('FAIL routing rows differ (got ', (SELECT COUNT(*) FROM @got), ')') END;
GO
-- 3. How many times does each read shape run the function? Counted from the function's own statements in
--    sys.dm_exec_query_stats (sys.dm_exec_function_stats does not track multi-statement functions).
CREATE TABLE #sink (a uniqueidentifier, b char(2), c int, d varchar(50), e bit);
CREATE TABLE #calls (shape varchar(80), fn_calls bigint, rows_returned int);
GO
CREATE OR ALTER PROCEDURE #fn_calls @n bigint OUTPUT AS
    SELECT @n = ISNULL(MAX(qs.execution_count), 0)
    FROM sys.dm_exec_query_stats AS qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
    WHERE st.dbid = DB_ID(N'AppCatalog') AND st.objectid = OBJECT_ID(N'AppCatalog.ref.fnAccountRoute');
GO
DECLARE @b bigint, @a bigint, @n int;
DBCC FREEPROCCACHE WITH NO_INFOMSGS;
EXEC #fn_calls @b OUTPUT;
-- The shape DAB sends for GET /api/Ops_AccountRoute?$filter=AccountUid eq <uuid>: a parameter, TOP, ORDER BY the keys.
INSERT #sink EXEC sys.sp_executesql
    N'SELECT TOP (100) AccountUid, CountryCode, RouteId, RouteName, IsOverride FROM dataapi.vw_AccountRoute WHERE AccountUid = @param0 ORDER BY AccountUid, CountryCode',
    N'@param0 uniqueidentifier', @param0 = 'AAAAAAAA-0000-0000-0000-000000000001';
SET @n = @@ROWCOUNT; EXEC #fn_calls @a OUTPUT; INSERT #calls VALUES ('DAB shape: AccountUid = @p, TOP 100, ORDER BY keys', @a - @b, @n); SET @b = @a;
SELECT @n = COUNT(*) FROM dataapi.vw_AccountRoute
WHERE AccountUid IN ('AAAAAAAA-0000-0000-0000-000000000001', 'AAAAAAAA-0000-0000-0000-000000000002', 'BBBBBBBB-0000-0000-0000-000000000001');
EXEC #fn_calls @a OUTPUT; INSERT #calls VALUES ('AccountUid IN (3 values)', @a - @b, @n); SET @b = @a;
SELECT @n = COUNT(*) FROM dataapi.vw_AccountRoute WHERE CountryCode = 'JP';
EXEC #fn_calls @a OUTPUT; INSERT #calls VALUES ('CountryCode = JP only', @a - @b, @n); SET @b = @a;
SELECT @n = COUNT(*) FROM dataapi.vw_AccountRoute;
EXEC #fn_calls @a OUTPUT; INSERT #calls VALUES ('no filter', @a - @b, @n);
SELECT CONCAT('   ', shape, ': ', fn_calls, ' function call(s), ', rows_returned, ' row(s)') FROM #calls;
GO
-- 4. The call counts the gateway rule depends on: fail if they move, so the rule is rechecked.
DECLARE @accounts int = (SELECT COUNT(*) FROM core.Account);
SELECT CASE WHEN (SELECT fn_calls FROM #calls WHERE shape LIKE 'DAB shape%') = 1
             AND (SELECT fn_calls FROM #calls WHERE shape LIKE 'AccountUid IN%') = 3
             AND (SELECT fn_calls FROM #calls WHERE shape = 'no filter') = @accounts
             AND (SELECT fn_calls FROM #calls WHERE shape LIKE 'CountryCode%') = @accounts
            THEN CONCAT('OK function calls: 1 for DAB''s AccountUid read, 3 for IN (3 values), one per account (', @accounts,
                        ') without an AccountUid filter: the gateway must require AccountUid eq <uuid>')
            ELSE 'FAIL the function call counts changed: recheck the gateway rule for Ops_AccountRoute' END;
GO
