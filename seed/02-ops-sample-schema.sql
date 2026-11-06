-- Sample operations tables: the example that deploy/ops-expansion/ serves through projection views.
--
-- Each table carries the kinds of column a governed API must never return, so the views, the gates
-- and the container test have something real to leave out:
--   core.AppUser            personal data (Email, DisplayName) and credentials (PasswordHash, ApiKey)
--   svc.Webhook             a credential column (AuthHeader) and a URL that can carry one (Url)
--   ref.MessageTemplate     message content (Body) and customer-written free text (TemplateName, Description)
--   ref.Route + ref.fnAccountRoute   a per-account function with a commercial column (CostPerMessage)
--   ref.Country             a lookup with nothing to hide
--   core.vwAppUserDirectory a legacy reporting view that exposes the personal columns again
--
-- No USE: it runs in the current database. The demo stack runs it in AppDb_Demo after 01;
-- ci/sql-views/run.sh runs it in AppCatalog (prod shape) and AppDb_dev (dev shape).
-- Safe to run twice. Shapes are illustrative, not a copy of any real schema.
SET QUOTED_IDENTIFIER ON;
GO
IF SCHEMA_ID(N'core') IS NULL EXEC (N'CREATE SCHEMA core');
IF SCHEMA_ID(N'svc')  IS NULL EXEC (N'CREATE SCHEMA svc');
IF SCHEMA_ID(N'ref')  IS NULL EXEC (N'CREATE SCHEMA ref');
GO
-- The same definition as 01-demo-schema.sql, for a database that did not run 01.
IF OBJECT_ID(N'core.Account', N'U') IS NULL
CREATE TABLE core.Account (
    AccountUid  UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_Account PRIMARY KEY,
    Name        NVARCHAR(200)    NOT NULL,
    IsActive    BIT              NOT NULL CONSTRAINT DF_Account_IsActive DEFAULT (1),
    CreatedDate DATETIME2(3)     NOT NULL CONSTRAINT DF_Account_Created  DEFAULT (SYSUTCDATETIME())
);
GO
IF OBJECT_ID(N'core.AppUser', N'U') IS NULL
CREATE TABLE core.AppUser (
    UserId       INT              NOT NULL CONSTRAINT PK_AppUser PRIMARY KEY,
    AccountUid   UNIQUEIDENTIFIER NOT NULL,
    Email        NVARCHAR(320)    NOT NULL,   -- personal
    DisplayName  NVARCHAR(200)    NULL,       -- personal
    PasswordHash VARBINARY(64)    NULL,       -- credential
    ApiKey       VARCHAR(64)      NULL,       -- credential
    RoleName     VARCHAR(30)      NOT NULL,
    IsActive     BIT              NOT NULL CONSTRAINT DF_AppUser_IsActive DEFAULT (1),
    LastLoginAt  DATETIME2(2)     NULL,
    CreatedDate  DATETIME2(2)     NOT NULL CONSTRAINT DF_AppUser_Created DEFAULT (SYSUTCDATETIME())
);
GO
IF OBJECT_ID(N'svc.Webhook', N'U') IS NULL
CREATE TABLE svc.Webhook (
    WebhookId   INT              NOT NULL CONSTRAINT PK_Webhook PRIMARY KEY,
    AccountUid  UNIQUEIDENTIFIER NOT NULL,
    EventType   VARCHAR(10)      NOT NULL,
    Url         NVARCHAR(1000)   NOT NULL,   -- may carry a credential in its login, path or query
    AuthHeader  NVARCHAR(1000)   NULL,       -- credential
    ContentType VARCHAR(50)      NOT NULL,
    TimeoutSec  INT              NOT NULL,
    IsActive    BIT              NOT NULL,
    UpdatedAt   DATETIME2(2)     NOT NULL
);
GO
IF OBJECT_ID(N'ref.MessageTemplate', N'U') IS NULL
CREATE TABLE ref.MessageTemplate (
    TemplateId   INT              NOT NULL CONSTRAINT PK_MessageTemplate PRIMARY KEY,
    AccountUid   UNIQUEIDENTIFIER NOT NULL,
    TemplateName NVARCHAR(100)    NOT NULL,   -- free text the customer wrote
    Body         NVARCHAR(MAX)    NOT NULL,   -- message content
    Description  NVARCHAR(500)    NULL,       -- free text
    LanguageCode VARCHAR(10)      NOT NULL,
    Category     VARCHAR(20)      NOT NULL,
    StatusCode   CHAR(1)          NOT NULL,
    UpdatedAt    DATETIME2(2)     NOT NULL
);
GO
IF OBJECT_ID(N'ref.Country', N'U') IS NULL
CREATE TABLE ref.Country (
    CountryCode CHAR(2)       NOT NULL CONSTRAINT PK_Country PRIMARY KEY,
    CountryName NVARCHAR(100) NOT NULL,
    DialPrefix  VARCHAR(5)    NOT NULL,
    RegionCode  VARCHAR(10)   NOT NULL
);
GO
IF OBJECT_ID(N'ref.Route', N'U') IS NULL
CREATE TABLE ref.Route (
    RouteId        INT          NOT NULL CONSTRAINT PK_Route PRIMARY KEY,
    CountryCode    CHAR(2)      NOT NULL,
    RouteName      VARCHAR(50)  NOT NULL,
    IsDefault      BIT          NOT NULL,
    IsActive       BIT          NOT NULL,
    CostPerMessage DECIMAL(9,5) NOT NULL    -- commercial
);
GO
IF OBJECT_ID(N'ref.AccountRouteOverride', N'U') IS NULL
CREATE TABLE ref.AccountRouteOverride (
    AccountUid  UNIQUEIDENTIFIER NOT NULL,
    CountryCode CHAR(2)          NOT NULL,
    RouteId     INT              NOT NULL,
    CONSTRAINT PK_AccountRouteOverride PRIMARY KEY (AccountUid, CountryCode)
);
GO
-- The route each country uses for one account: the account's own override beats the country's
-- default route; inactive routes never apply. Multi-statement on purpose: like many real routing
-- functions, it cannot be inlined, so a view that applies it per account runs it once per account
-- it reads (ci/sql-views/assert-routing.sql measures that).
CREATE OR ALTER FUNCTION ref.fnAccountRoute (@AccountUid UNIQUEIDENTIFIER)
RETURNS @r TABLE (CountryCode CHAR(2) NOT NULL, RouteId INT NOT NULL, RouteName VARCHAR(50) NOT NULL,
                  IsOverride BIT NOT NULL, CostPerMessage DECIMAL(9,5) NOT NULL)
AS
BEGIN
    INSERT @r (CountryCode, RouteId, RouteName, IsOverride, CostPerMessage)
    SELECT r.CountryCode, r.RouteId, r.RouteName, 0, r.CostPerMessage
    FROM ref.Route AS r
    WHERE r.IsDefault = 1 AND r.IsActive = 1;

    UPDATE x SET RouteId = r.RouteId, RouteName = r.RouteName, IsOverride = 1, CostPerMessage = r.CostPerMessage
    FROM @r AS x
    JOIN ref.AccountRouteOverride AS o ON o.AccountUid = @AccountUid AND o.CountryCode = x.CountryCode
    JOIN ref.Route AS r ON r.RouteId = o.RouteId AND r.IsActive = 1;
    RETURN;
END
GO
-- A reporting view of the kind that grows up around a user table. No API serves it, but it reads the
-- personal columns, so deploy/ops-expansion/04-prod-deny-base-objects.sql denies it as well ("deny-also").
CREATE OR ALTER VIEW core.vwAppUserDirectory
AS
SELECT u.UserId, u.AccountUid, a.Name AS AccountName, u.Email, u.DisplayName, u.RoleName, u.IsActive
FROM core.AppUser AS u
JOIN core.Account AS a ON a.AccountUid = u.AccountUid;
GO
