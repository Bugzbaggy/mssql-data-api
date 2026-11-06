/*
  appdb-data-api - Operations entities: the two tables that hold credentials and personal data, served
  through projection views WITHOUT those columns.

  Where: prod AppCatalog on the primary (an AG carries it to every readable secondary), and dev AppDb_dev.
  Run it in the database itself (no USE: SSMS or sqlcmd -d picks it). Dev first, then prod. Safe to run twice.

  Why views, not DAB field rules: DAB 2.0.9 reads every table and view entity at startup with
  SET FMTONLY ON; SELECT * FROM <object>. SQL Server checks column permissions even under FMTONLY, so a
  column-level DENY (or a GRANT on only some columns) on a served table stops the whole engine with Msg 230.
  A view that lists only the approved columns is what DAB serves instead; its owner (dbo) reads the table
  through ownership chaining, so the DAB login needs no grant on the table at all.

  What each view leaves out is recorded in ops-columns.json (the column contract): Gate OPS-ENTITIES checks
  the DAB entities against it and Gate SQL-VIEWS checks these views against it in a SQL Server container.

  Credentials inside a value are cut out as well as credential columns: a URL is reduced to scheme://host[:port]
  by dataapi.fnUrlParts, or to NULL when it does not parse cleanly, because a webhook URL can carry a token in
  its login, path or query string.

  No SCHEMABINDING: the base tables usually belong to another team's schema project, whose deploys would then
  fail on any change to a bound column (Msg 4922). The explicit column lists are what keep a column added to a
  base table later out of the API.

  Order: these views and grants -> the DAB entities pointed at the views -> only then, in prod,
  04-prod-deny-base-objects.sql. The other order stops DAB at its next start.
*/
/* Target guard. Anywhere but AppCatalog or AppDb_dev, or on a read-only copy, it raises an error and SET NOEXEC ON
   stops every later batch. SQL Server still compiles those batches, so in the wrong database the stop message is
   followed by Msg 208 errors for the views: that is expected, and nothing has run. */
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

/* dataapi.fnUrlParts: the one URL cut every view uses. It returns scheme://host[:port], or NULL when that cannot be
   shown safely:
     - the scheme counts only at the very start of the value (a letter, then letters, digits, + . -, then ://), so a URL
       inside a query string never moves the cut, and a value without one is not cut at all;
     - the authority ends at the first / ? # or backslash; the host is what follows its LAST @, so user:pass@ is dropped;
     - an @ anywhere after the host gives NULL (a password holding / ? # or a backslash would otherwise leave a piece);
     - the host must be a plain hostname or IPv4 address and the port all digits, otherwise NULL, so a value that is no
       URL (host:2775;password=...) never passes through.
   Inline, so the optimizer expands it inside each view. DAB never sees it: no entity, no grant. */
CREATE OR ALTER FUNCTION dataapi.fnUrlParts (@url nvarchar(4000))
RETURNS TABLE
AS
RETURN
SELECT CAST(CASE WHEN s.scheme IS NULL OR h.host = N'' OR LEN(h.host) > 253
                      OR h.host LIKE N'%[^A-Za-z0-9.-]%'
                      OR (h.port IS NOT NULL AND (h.port = N'' OR h.port LIKE N'%[^0-9]%' OR LEN(h.port) > 5))
                      OR CHARINDEX(N'@', a.after_authority) > 0
                 THEN NULL
                 ELSE s.scheme + N'://' + h.host + ISNULL(N':' + h.port, N'') END AS nvarchar(4000)) AS SchemeHost
FROM (SELECT CHARINDEX(N'://', @url) AS sep) AS x
-- n: the scheme's length, 0 when there is none. Computed apart so LEFT never sees a negative length: SQL Server does
-- not promise to stop evaluating an AND at its first false term.
CROSS APPLY (SELECT CASE WHEN x.sep > 1 THEN x.sep - 1 ELSE 0 END AS n) AS n
CROSS APPLY (SELECT CASE WHEN n.n > 0 AND LEFT(@url, 1) LIKE N'[A-Za-z]' AND LEFT(@url, n.n) NOT LIKE N'%[^A-Za-z0-9+.-]%'
                         THEN LOWER(LEFT(@url, n.n)) END AS scheme,
                    SUBSTRING(@url, x.sep + 3, 4000) AS rest) AS s
CROSS APPLY (SELECT PATINDEX(N'%[/?#\]%', s.rest + N'/') AS stop) AS e
CROSS APPLY (SELECT LEFT(s.rest, e.stop - 1) AS authority, SUBSTRING(s.rest, e.stop, 4000) AS after_authority) AS a
CROSS APPLY (SELECT CASE WHEN CHARINDEX(N'@', a.authority) > 0
                         THEN RIGHT(a.authority, CHARINDEX(N'@', REVERSE(a.authority)) - 1) ELSE a.authority END AS hostport) AS hp
CROSS APPLY (SELECT CASE WHEN CHARINDEX(N':', hp.hostport) > 0 THEN LEFT(hp.hostport, CHARINDEX(N':', hp.hostport) - 1) ELSE hp.hostport END AS host,
                    CASE WHEN CHARINDEX(N':', hp.hostport) > 0 THEN SUBSTRING(hp.hostport, CHARINDEX(N':', hp.hostport) + 1, 4000) END AS port) AS h;
GO

/* core.AppUser (7 served of 10 columns). Left out: Email, DisplayName (personal); PasswordHash, ApiKey (credential;
   ApiKey is served only as the HasApiKey flag). */
CREATE OR ALTER VIEW dataapi.vw_AppUser
AS
SELECT u.UserId, u.AccountUid, u.RoleName, u.IsActive, u.LastLoginAt, u.CreatedDate,
       CAST(CASE WHEN NULLIF(u.ApiKey, '') IS NULL THEN 0 ELSE 1 END AS bit) AS HasApiKey
FROM core.AppUser AS u;
GO

/* svc.Webhook (9 served of 9 columns, 2 of them derived). Left out: AuthHeader (credential; served as the HasAuthHeader
   flag) and Url (its login, path or query can carry a credential; served as UrlHost, scheme://host[:port] or NULL). */
CREATE OR ALTER VIEW dataapi.vw_Webhook
AS
SELECT w.WebhookId, w.AccountUid, w.EventType, w.ContentType, w.TimeoutSec, w.IsActive, w.UpdatedAt,
       CAST(CASE WHEN NULLIF(w.AuthHeader, N'') IS NULL THEN 0 ELSE 1 END AS bit) AS HasAuthHeader,
       CAST(u.SchemeHost AS nvarchar(300)) AS UrlHost
FROM svc.Webhook AS w
OUTER APPLY dataapi.fnUrlParts(w.Url) AS u;
GO

/* Grants: SELECT on each view, and nothing else, to the role of DAB's one SQL login: role_svc_dataapi (svc_dataapi) in
   prod, role_dev_svc_dataapi (dev_svc_dataapi) in dev. The function and the schema are granted to no one. There is no
   separate login for these entities: the JWT role in each entity's permissions keeps callers apart. Undo one with
   REVOKE SELECT ON <view> FROM <that role>. */
DECLARE @dab sysname = CASE DB_NAME() WHEN N'AppCatalog' THEN N'role_svc_dataapi' WHEN N'AppDb_dev' THEN N'role_dev_svc_dataapi' END;
IF DATABASE_PRINCIPAL_ID(@dab) IS NULL
BEGIN
    DECLARE @db sysname = DB_NAME();
    RAISERROR(N'%s does not exist in %s: create the DAB user and role first (deploy/01-, 02-...-create-login-and-grants.sql).', 16, 1, @dab, @db);
END
ELSE
BEGIN
    DECLARE @sql nvarchar(max) = N'';
    SELECT @sql += N'GRANT SELECT ON ' + v + N' TO ' + QUOTENAME(@dab) + N'; '
    FROM (VALUES (N'dataapi.vw_AppUser'), (N'dataapi.vw_Webhook')) AS t(v);
    EXEC sys.sp_executesql @sql;
END
GO

/* Verify (read-only): no left-out column is in either view. Expect 0 rows. */
SELECT OBJECT_SCHEMA_NAME(c.object_id) + N'.' + OBJECT_NAME(c.object_id) AS view_name, c.name AS left_out_column_found
FROM sys.columns AS c
WHERE (c.object_id = OBJECT_ID(N'dataapi.vw_AppUser') AND c.name IN (N'Email', N'DisplayName', N'PasswordHash', N'ApiKey'))
   OR (c.object_id = OBJECT_ID(N'dataapi.vw_Webhook') AND c.name IN (N'AuthHeader', N'Url'));
GO
SET NOEXEC OFF;
GO
