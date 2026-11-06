-- Gate SQL-VIEWS fixture, dev shape: AppDb_dev with the same sample tables, drifted the way a dev copy drifts:
-- ref.Country does not exist (its entity is prod only) and ref.MessageTemplate has no Category column yet (the contract
-- serves it as NULL there, "dev-null"). The dev DAB user is also in db_datareader, as
-- deploy/02-dev-create-login-and-grants.sql makes it, so the views must still be granted to its role explicitly.
SET QUOTED_IDENTIFIER ON;
GO
CREATE DATABASE AppDb_dev;
GO
USE AppDb_dev;
GO
:r /tmp/work/02-ops-sample-schema.sql
GO
DROP TABLE ref.Country;
ALTER TABLE ref.MessageTemplate DROP COLUMN Category;
GO
CREATE USER dev_svc_dataapi WITHOUT LOGIN;
CREATE ROLE role_dev_svc_dataapi AUTHORIZATION dbo;
ALTER ROLE role_dev_svc_dataapi ADD MEMBER dev_svc_dataapi;
ALTER ROLE db_datareader ADD MEMBER dev_svc_dataapi;
GO
SET NOCOUNT ON;
DECLARE @a uniqueidentifier = 'CCCCCCCC-0000-0000-0000-000000000001', @t datetime2(2) = '2026-01-15T10:00:00';
INSERT core.Account (AccountUid, Name, IsActive) VALUES (@a, N'CANARY-dev-account', 1);
INSERT core.AppUser (UserId, AccountUid, Email, DisplayName, PasswordHash, ApiKey, RoleName, IsActive, LastLoginAt, CreatedDate) VALUES
    (1, @a, N'CANARY-dev@example.com', N'CANARY Dev Person', NULL, 'CANARY-dev-key', 'owner', 1, @t, @t);
INSERT svc.Webhook (WebhookId, AccountUid, EventType, Url, AuthHeader, ContentType, TimeoutSec, IsActive, UpdatedAt) VALUES
    (1, @a, 'DLR', N'https://dev:CANARY' + N'@hooks.example.invalid/dlr?token=CANARY', N'Bearer CANARY-dev', 'application/json', 10, 1, @t);
INSERT ref.MessageTemplate (TemplateId, AccountUid, TemplateName, Body, Description, LanguageCode, StatusCode, UpdatedAt) VALUES
    (1, @a, N'CANARY-dev-name', N'CANARY dev body', N'CANARY dev description', 'en', 'A', @t);
INSERT ref.Route (RouteId, CountryCode, RouteName, IsDefault, IsActive, CostPerMessage) VALUES (1, 'FR', 'fr-default', 1, 1, 0.01000);
GO
