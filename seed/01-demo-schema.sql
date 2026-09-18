-- Demo data for the self-contained stack. Nothing here mirrors production; it exists
-- so both MCP endpoints have something real to answer questions about.
IF DB_ID('AppDb_Demo') IS NULL
    CREATE DATABASE AppDb_Demo;
GO
USE AppDb_Demo;
GO
IF SCHEMA_ID('core') IS NULL EXEC('CREATE SCHEMA core');
GO
IF OBJECT_ID('core.Account') IS NULL
CREATE TABLE core.Account (
    AccountUid  UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_Account PRIMARY KEY,
    Name        NVARCHAR(200)    NOT NULL,
    IsActive    BIT              NOT NULL CONSTRAINT DF_Account_IsActive DEFAULT (1),
    CreatedDate DATETIME2(3)     NOT NULL CONSTRAINT DF_Account_Created  DEFAULT (SYSUTCDATETIME())
);
GO
IF NOT EXISTS (SELECT 1 FROM core.Account)
INSERT core.Account (AccountUid, Name, IsActive) VALUES
    ('11111111-1111-1111-1111-111111111111', N'Demo Account One', 1),
    ('22222222-2222-2222-2222-222222222222', N'Demo Account Two', 0);
GO
CREATE OR ALTER PROCEDURE core.Account_GetByUid
    @AccountUid UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT AccountUid, Name, IsActive, CreatedDate
    FROM core.Account
    WHERE AccountUid = @AccountUid;
END
GO

-- The root Dockerfile bakes in the real dab-config.json (data-source: AppCatalog) plus
-- config/dab-config.id.json (data-source: AppDb_Data). DAB validates every configured
-- entity's stored procedure against the connected database at startup — unconditionally,
-- not just the ones a caller happens to exercise — so both data sources of this
-- self-contained stack need a matching stub for every object those two files reference,
-- or dab-mcp never finishes starting ("No stored procedure definition found ..."). Both
-- CONN_GLOBAL_CONFIG and CONN_ID_MSGDATA point at this same AppDb_Demo database, so all
-- six stubs live here. Shapes are plausible demo data, not a schema mirror of production.
IF SCHEMA_ID('svc') IS NULL EXEC('CREATE SCHEMA svc');
GO
IF SCHEMA_ID('msg') IS NULL EXEC('CREATE SCHEMA msg');
GO

-- dab-config.json: get_subaccounts_for_account
CREATE OR ALTER PROCEDURE core.Account_SubAccount_GetAll
    @AccountUid UNIQUEIDENTIFIER,
    @UserId     UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(1 AS INT) AS SubAccountUid, N'Demo Sub-Account' AS Name,
           N'SM' AS ProductFamily, CAST(1 AS BIT) AS Active
    WHERE @AccountUid IS NOT NULL;
END
GO

-- dab-config.json: get_subaccount
CREATE OR ALTER PROCEDURE svc.SubAccount_Get
    @AccountUid    UNIQUEIDENTIFIER,
    @SubAccountUid INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @SubAccountUid AS SubAccountUid, N'Demo Sub-Account' AS Name,
           CAST(1 AS BIT) AS Active, CAST(0 AS INT) AS ProtectionStatusId,
           CAST(0 AS INT) AS MsgProcessingFlags
    WHERE @AccountUid IS NOT NULL;
END
GO

-- dab-config.json: get_account_balance
CREATE OR ALTER PROCEDURE core.BillingBalance_Get
    @AccountUid UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(0.00 AS DECIMAL(18,2)) AS Balance, N'USD' AS Currency
    WHERE @AccountUid IS NOT NULL;
END
GO

-- dab-config.json: get_channels_config
CREATE OR ALTER PROCEDURE core.Channels_ConfigGet
    @AccountUid UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(1 AS BIT) AS Enabled, N'{}' AS ConfigJson
    WHERE @AccountUid IS NOT NULL;
END
GO

-- config/dab-config.id.json: id_search_sms
CREATE OR ALTER PROCEDURE core.MessageLog_SearchByFilter_v2
    @AccountUid        UNIQUEIDENTIFIER,
    @UserId             UNIQUEIDENTIFIER,
    @TimeframeStart      DATETIME2(3),
    @TimeframeEnd        DATETIME2(3),
    @UMID                UNIQUEIDENTIFIER = NULL,
    @MSISDN              VARCHAR(32)  = NULL,
    @SmsTypeId           INT          = NULL,
    @StatusIds           VARCHAR(200) = NULL,
    @MaskSensitiveData   BIT          = 1,
    @Limit               INT          = 50
AS
BEGIN
    SET NOCOUNT ON;
    -- No live message log in the demo stack; shape only (always empty).
    SELECT CAST(NULL AS UNIQUEIDENTIFIER) AS UMID, CAST(NULL AS INT) AS StatusId,
           CAST(NULL AS INT) AS SmsTypeId, CAST(NULL AS VARCHAR(32)) AS MSISDN
    WHERE 1 = 0;
END
GO

-- config/dab-config.id.json: id_lookup_sms_region_by_umid
CREATE OR ALTER PROCEDURE msg.MessageRegionLookup_Get
    @Umid          UNIQUEIDENTIFIER,
    @ConnUid        BIGINT        = 0,
    @CorrelationId  VARCHAR(100)  = ''
AS
BEGIN
    SET NOCOUNT ON;
    SELECT N'SG' AS RegionName
    WHERE @Umid IS NOT NULL;
END
GO
