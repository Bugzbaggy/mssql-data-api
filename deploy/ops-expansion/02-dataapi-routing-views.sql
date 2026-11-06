/*
  appdb-data-api - Operations entities: a function-backed view, ref.fnAccountRoute per account.

  DAB serves tables, views and stored procedures, not table-valued functions. To serve a function's answer per
  account, a view applies it to every account row: dataapi.vw_AccountRoute = core.Account CROSS APPLY
  ref.fnAccountRoute(AccountUid), without the function's commercial column (CostPerMessage).

  The cost of that shape is the point of this file. ref.fnAccountRoute is a multi-statement function, so SQL Server
  runs it once per account row the view reads: once when the read filters on AccountUid (the predicate is pushed
  into core.Account), and once per account when it does not. DAB applies no filter of its own, so the gateway in
  front of /mcp must require AccountUid eq <uuid> for Ops_AccountRoute (ops-gateway-policy.json).
  ci/sql-views/assert-routing.sql measures the call counts on every change and fails if they move.

  Where and when: as 01 (AppCatalog in prod, AppDb_dev in dev; no USE), after 01. Safe to run twice.
*/
DECLARE @db sysname = DB_NAME(), @srv sysname = @@SERVERNAME;
IF @db NOT IN (N'AppCatalog', N'AppDb_dev')
   OR CAST(DATABASEPROPERTYEX(@db, 'Updateability') AS varchar(20)) <> 'READ_WRITE'
BEGIN
    RAISERROR(N'Stopped: run this in AppCatalog (prod primary) or AppDb_dev (dev), on a writable copy. Current: %s on %s.', 16, 1, @db, @srv);
    SET NOEXEC ON;
END;
GO
IF SCHEMA_ID(N'dataapi') IS NULL EXEC (N'CREATE SCHEMA dataapi AUTHORIZATION dbo;');
GO

/* ref.fnAccountRoute per account (5 served of the function's 5 outputs plus the account key). Left out:
   CostPerMessage (commercial). */
CREATE OR ALTER VIEW dataapi.vw_AccountRoute
AS
SELECT a.AccountUid, r.CountryCode, r.RouteId, r.RouteName, r.IsOverride
FROM core.Account AS a
CROSS APPLY ref.fnAccountRoute(a.AccountUid) AS r;
GO

/* Grants: SELECT on the view, and nothing else, to the DAB login's role (as 01). */
DECLARE @dab sysname = CASE DB_NAME() WHEN N'AppCatalog' THEN N'role_svc_dataapi' WHEN N'AppDb_dev' THEN N'role_dev_svc_dataapi' END;
IF DATABASE_PRINCIPAL_ID(@dab) IS NULL
BEGIN
    DECLARE @db sysname = DB_NAME();
    RAISERROR(N'%s does not exist in %s: create the DAB user and role first.', 16, 1, @dab, @db);
END
ELSE
BEGIN
    DECLARE @sql nvarchar(400) = N'GRANT SELECT ON dataapi.vw_AccountRoute TO ' + QUOTENAME(@dab) + N';';
    EXEC sys.sp_executesql @sql;
END
GO

/* 04-prod-deny-base-objects.sql (prod only, last) denies the DAB login every object this view reads, here
   core.Account, ref.fnAccountRoute and the tables behind the function. */

/* Verify (read-only): the commercial column is not in the view. Expect 0 rows. */
SELECT c.name AS left_out_column_found
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID(N'dataapi.vw_AccountRoute') AND c.name = N'CostPerMessage';
GO
SET NOEXEC OFF;
GO
