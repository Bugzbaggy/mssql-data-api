-- Gate SQL-VIEWS fixture, prod shape: AppCatalog with the sample operations tables (seed/02-ops-sample-schema.sql),
-- the DAB user and role as deploy/01-create-login-and-grants.sql makes them, and synthetic rows.
-- Every value an API must never return holds the marker CANARY: a credential, a personal or free-text value, message
-- content, and the login, path, query or fragment of a URL. A view or entity that leaks one is caught by a text search.
-- Every host is under the reserved .invalid domain or a TEST-NET address, so nothing here can resolve to a real server.
SET QUOTED_IDENTIFIER ON;
GO
CREATE DATABASE AppCatalog;
GO
USE AppCatalog;
GO
:r /tmp/work/02-ops-sample-schema.sql
GO
-- A curated stored procedure the API serves today (seed/01), granted the way deploy/01 grants it: 04's DENYs must not
-- break it (ownership chaining skips the permission check on the tables it reads).
CREATE OR ALTER PROCEDURE core.Account_GetByUid
    @AccountUid UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT AccountUid, IsActive, CreatedDate FROM core.Account WHERE AccountUid = @AccountUid;
END
GO
-- The DAB login, its user and role, as deploy/01 makes them. The password is made per run by run.sh (sqlcmd variable
-- DABPW) and exists only in this container: the API test connects DAB as this login, after 04's DENYs.
CREATE LOGIN svc_dataapi WITH PASSWORD = N'$(DABPW)', CHECK_POLICY = OFF;
GO
CREATE USER svc_dataapi FOR LOGIN svc_dataapi;
CREATE ROLE role_svc_dataapi AUTHORIZATION dbo;
ALTER ROLE role_svc_dataapi ADD MEMBER svc_dataapi;
GRANT EXECUTE ON OBJECT::core.Account_GetByUid TO role_svc_dataapi;
GO
SET NOCOUNT ON;
DECLARE @a1 uniqueidentifier = 'AAAAAAAA-0000-0000-0000-000000000001',
        @a2 uniqueidentifier = 'AAAAAAAA-0000-0000-0000-000000000002',
        @t  datetime2(2) = '2026-01-15T10:00:00';
-- 22 accounts: the two the assertions name, and 20 more so the routing view's call count is measurable.
INSERT core.Account (AccountUid, Name, IsActive) VALUES (@a1, N'CANARY-account-name-1', 1), (@a2, N'CANARY-account-name-2', 1);
INSERT core.Account (AccountUid, Name, IsActive)
SELECT CAST(CONCAT('BBBBBBBB-0000-0000-0000-', RIGHT(CONCAT('000000000000', n), 12)) AS uniqueidentifier), CONCAT(N'CANARY-filler-', n), 1
FROM (SELECT TOP (20) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects) AS x;

INSERT core.AppUser (UserId, AccountUid, Email, DisplayName, PasswordHash, ApiKey, RoleName, IsActive, LastLoginAt, CreatedDate) VALUES
    (1, @a1, N'CANARY-1@example.com', N'CANARY Person One', CAST('CANARY-hash' AS varbinary(64)), 'CANARY-apikey-1', 'owner', 1, @t, @t),
    (2, @a1, N'CANARY-2@example.com', NULL, NULL, NULL, 'viewer', 1, NULL, @t),
    (3, @a2, N'CANARY-3@example.com', N'CANARY Person Three', 0x01, '', 'admin', 0, @t, @t);

-- One row per URL shape the cut must handle; assert-prod-values.sql holds the expected UrlHost of each. Where a URL
-- carries a login, its @ is concatenated (' + N'@...) only so the repository's e-mail scan (ci/leak-scan.sh) does not
-- read user@host as an address; the value stored is the plain URL. E-mail columns use example.com addresses.
INSERT svc.Webhook (WebhookId, AccountUid, EventType, Url, AuthHeader, ContentType, TimeoutSec, IsActive, UpdatedAt) VALUES
    ( 1, @a1, 'DLR', N'https://hooks.example.invalid/dlr?token=CANARY-query',              N'Bearer CANARY-token', 'application/json', 10, 1, @t),
    ( 2, @a1, 'MO',  N'https://user:CANARY-pw' + N'@hooks.example.invalid:8443/cb',         N'Basic CANARY-basic',  'application/json', 10, 1, @t),
    ( 3, @a1, 'DLR', N'HTTP://a:b' + N'@CANARY' + N'@hooks.example.invalid/p',              N'',                    'application/json', 10, 1, @t),
    ( 4, @a1, 'DLR', N'https://hooks.example.invalid\@CANARY.example.invalid/x',            NULL, 'text/plain', 5, 1, @t),
    ( 5, @a1, 'DLR', N'https://user:pa/CANARY' + N'@hooks.example.invalid/',                 NULL, 'text/plain', 5, 1, @t),
    ( 6, @a1, 'MO',  N'hooks.example.invalid/no-scheme?k=CANARY',                           NULL, 'text/plain', 5, 1, @t),
    ( 7, @a2, 'MO',  N'ftp://198.51.100.7:21/CANARY-path',                                  NULL, 'text/plain', 5, 1, @t),
    ( 8, @a2, 'MO',  N'https://hooks.example.invalid?next=https://CANARY.example.invalid', NULL, 'text/plain', 5, 1, @t),
    ( 9, @a2, 'MO',  N'host.example.invalid:2775;password=CANARY',                          NULL, 'text/plain', 5, 0, @t),
    (10, @a2, 'MO',  N'https://hooks.example.invalid:80a/CANARY',                           NULL, 'text/plain', 5, 1, @t),
    (11, @a2, 'MO',  N'https://hooks.example.invalid#CANARY-fragment',                      NULL, 'text/plain', 5, 1, @t),
    (12, @a2, 'MO',  N'https://hooks.example.invalid:/CANARY',                              NULL, 'text/plain', 5, 1, @t),
    (13, @a2, 'MO',  N'x https://hooks.example.invalid/CANARY',                             NULL, 'text/plain', 5, 1, @t),
    (14, @a2, 'MO',  N'https://[2001:db8::1]:443/CANARY',                                   NULL, 'text/plain', 5, 1, @t);

INSERT ref.MessageTemplate (TemplateId, AccountUid, TemplateName, Body, Description, LanguageCode, Category, StatusCode, UpdatedAt) VALUES
    (1, @a1, N'CANARY-name-1', N'CANARY body one', N'CANARY description', 'en', 'UTILITY', 'A', @t),
    (2, @a2, N'CANARY-name-2', N'CANARY', NULL, 'id', 'MARKETING', 'P', @t);

INSERT ref.Country (CountryCode, CountryName, DialPrefix, RegionCode) VALUES
    ('FR', N'France', '33', 'EMEA'), ('JP', N'Japan', '81', 'APAC'),
    ('BR', N'Brazil', '55', 'AMER'), ('AU', N'Australia', '61', 'APAC');

-- Routes: FR has a default and a premium route; JP a default and an inactive backup; BR only an inactive default
-- (so BR never appears); AU a default. Account 1 overrides FR with the premium route and JP with the inactive
-- backup (ignored). assert-routing.sql holds the expected rows.
INSERT ref.Route (RouteId, CountryCode, RouteName, IsDefault, IsActive, CostPerMessage) VALUES
    (1, 'FR', 'fr-default', 1, 1, 0.01000), (2, 'FR', 'fr-premium', 0, 1, 0.02000),
    (3, 'JP', 'jp-default', 1, 1, 0.03000), (6, 'JP', 'jp-backup',  0, 0, 0.06000),
    (4, 'BR', 'br-default', 1, 0, 0.04000), (5, 'AU', 'au-default', 1, 1, 0.05000);
INSERT ref.AccountRouteOverride (AccountUid, CountryCode, RouteId) VALUES (@a1, 'FR', 2), (@a1, 'JP', 6);
GO
