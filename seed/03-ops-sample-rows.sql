-- Demo rows for the sample operations tables (02-ops-sample-schema.sql). Illustrative only: every
-- e-mail, URL and secret below is made up; e-mail addresses use example.com and URL hosts the reserved .invalid domain.
-- No USE: the demo stack runs it in AppDb_Demo. ci/sql-views/ does NOT run it; its fixtures insert
-- their own rows, with a CANARY marker in every value an API must never return.
SET NOCOUNT ON;
GO
IF NOT EXISTS (SELECT 1 FROM core.Account WHERE AccountUid = '11111111-1111-1111-1111-111111111111')
    INSERT core.Account (AccountUid, Name, IsActive) VALUES ('11111111-1111-1111-1111-111111111111', N'Demo Account One', 1);
IF NOT EXISTS (SELECT 1 FROM core.Account WHERE AccountUid = '22222222-2222-2222-2222-222222222222')
    INSERT core.Account (AccountUid, Name, IsActive) VALUES ('22222222-2222-2222-2222-222222222222', N'Demo Account Two', 0);
GO
IF NOT EXISTS (SELECT 1 FROM core.AppUser)
INSERT core.AppUser (UserId, AccountUid, Email, DisplayName, PasswordHash, ApiKey, RoleName, IsActive, LastLoginAt) VALUES
    (1, '11111111-1111-1111-1111-111111111111', N'owner@example.com', N'Demo Owner', 0x00, 'demo-key-not-real', 'owner', 1, SYSUTCDATETIME()),
    (2, '11111111-1111-1111-1111-111111111111', N'viewer@example.com', NULL, 0x00, NULL, 'viewer', 1, NULL);
IF NOT EXISTS (SELECT 1 FROM svc.Webhook)
INSERT svc.Webhook (WebhookId, AccountUid, EventType, Url, AuthHeader, ContentType, TimeoutSec, IsActive, UpdatedAt) VALUES
    (1, '11111111-1111-1111-1111-111111111111', 'DLR', N'https://hooks.demo.invalid/dlr?token=not-real', N'Bearer not-real', 'application/json', 10, 1, SYSUTCDATETIME()),
    (2, '11111111-1111-1111-1111-111111111111', 'MO',  N'https://hooks.demo.invalid:8443/mo', NULL, 'application/json', 10, 1, SYSUTCDATETIME());
IF NOT EXISTS (SELECT 1 FROM ref.MessageTemplate)
INSERT ref.MessageTemplate (TemplateId, AccountUid, TemplateName, Body, Description, LanguageCode, Category, StatusCode, UpdatedAt) VALUES
    (1, '11111111-1111-1111-1111-111111111111', N'order_ready', N'Hi {{1}}, your order {{2}} is ready.', N'Order notification', 'en', 'UTILITY', 'A', SYSUTCDATETIME());
IF NOT EXISTS (SELECT 1 FROM ref.Country)
INSERT ref.Country (CountryCode, CountryName, DialPrefix, RegionCode) VALUES
    ('FR', N'France', '33', 'EMEA'), ('JP', N'Japan', '81', 'APAC'), ('BR', N'Brazil', '55', 'AMER');
IF NOT EXISTS (SELECT 1 FROM ref.Route)
INSERT ref.Route (RouteId, CountryCode, RouteName, IsDefault, IsActive, CostPerMessage) VALUES
    (1, 'FR', 'fr-default', 1, 1, 0.01000), (2, 'FR', 'fr-premium', 0, 1, 0.02000), (3, 'JP', 'jp-default', 1, 1, 0.03000);
IF NOT EXISTS (SELECT 1 FROM ref.AccountRouteOverride)
INSERT ref.AccountRouteOverride (AccountUid, CountryCode, RouteId) VALUES ('11111111-1111-1111-1111-111111111111', 'FR', 2);
GO
