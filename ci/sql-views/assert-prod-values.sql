-- Gate SQL-VIEWS, prod shape: the value-level cuts, read as the DAB user. Each line starts with OK or FAIL.
-- The expected values follow the fixture rows in fixtures/prod-schema.sql, one per URL shape.
USE AppCatalog;
SET NOCOUNT ON;
GO
EXECUTE AS USER = N'svc_dataapi';
DECLARE @r TABLE (line nvarchar(1000));
DECLARE @exp TABLE (WebhookId int PRIMARY KEY, UrlHost nvarchar(300) NULL, why nvarchar(200));
INSERT @exp VALUES
    ( 1, N'https://hooks.example.invalid',       N'path and query dropped'),
    ( 2, N'https://hooks.example.invalid:8443',  N'user:password@ dropped, the port kept'),
    ( 3, N'http://hooks.example.invalid',        N'the host is what follows the LAST @; the scheme is lower-cased'),
    ( 4, NULL,                                    N'a backslash ends the host and an @ follows it: nothing served'),
    ( 5, NULL,                                    N'a password holding / leaves user:pa as the authority: nothing served'),
    ( 6, NULL,                                    N'no scheme at the start: not cut, so not served'),
    ( 7, N'ftp://198.51.100.7:21',                N'an IPv4 host with its port'),
    ( 8, N'https://hooks.example.invalid',        N'a URL inside the query string does not move the cut'),
    ( 9, NULL,                                    N'host:port;password=... is no URL: nothing served'),
    (10, NULL,                                    N'a port that is not all digits: nothing served'),
    (11, N'https://hooks.example.invalid',        N'the fragment dropped'),
    (12, NULL,                                    N'an empty port: nothing served'),
    (13, NULL,                                    N'text before the scheme: nothing served'),
    (14, NULL,                                    N'a bracketed IPv6 host is not a plain host: nothing served');
INSERT @r
SELECT CASE WHEN EXISTS (SELECT e.UrlHost INTERSECT SELECT w.UrlHost)
            THEN CONCAT(N'OK webhook ', e.WebhookId, N' -> ', ISNULL(w.UrlHost, N'NULL'), N' (', e.why, N')')
            ELSE CONCAT(N'FAIL webhook ', e.WebhookId, N': UrlHost = ', ISNULL(w.UrlHost, N'NULL'), N', want ', ISNULL(e.UrlHost, N'NULL'), N' (', e.why, N')') END
FROM @exp AS e LEFT JOIN dataapi.vw_Webhook AS w ON w.WebhookId = e.WebhookId;
-- The credential flags: 1 where a value is set, 0 for NULL or an empty string, never the value.
INSERT @r
SELECT CASE WHEN SUM(CASE WHEN (WebhookId IN (1, 2) AND HasAuthHeader = 1) OR (WebhookId NOT IN (1, 2) AND HasAuthHeader = 0) THEN 1 ELSE 0 END) = COUNT(*)
            THEN 'OK HasAuthHeader is 1 exactly where a header is set (an empty header counts as none)'
            ELSE 'FAIL HasAuthHeader' END
FROM dataapi.vw_Webhook;
INSERT @r
SELECT CASE WHEN SUM(CASE WHEN (UserId = 1 AND HasApiKey = 1) OR (UserId IN (2, 3) AND HasApiKey = 0) THEN 1 ELSE 0 END) = 3 AND COUNT(*) = 3
            THEN 'OK HasApiKey is 1 exactly where a key is set; all 3 users served'
            ELSE 'FAIL HasApiKey' END
FROM dataapi.vw_AppUser;
-- A computed column: the body's length, never the body.
INSERT @r
SELECT CASE WHEN SUM(CASE WHEN (TemplateId = 1 AND BodyLength = 15) OR (TemplateId = 2 AND BodyLength = 6) THEN 1 ELSE 0 END) = 2
            THEN 'OK BodyLength is LEN(Body) for both templates'
            ELSE 'FAIL BodyLength' END
FROM dataapi.vw_MessageTemplate;
REVERT;
SELECT line FROM @r;
GO
