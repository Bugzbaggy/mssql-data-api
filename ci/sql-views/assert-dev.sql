-- Gate SQL-VIEWS, dev shape (AppDb_dev drifted as fixtures/dev-schema.sql makes it). Each line starts with OK or FAIL.
USE AppDb_dev;
SET NOCOUNT ON;
GO
DECLARE @r TABLE (line nvarchar(1000));
INSERT @r SELECT CASE WHEN OBJECT_ID(N'dataapi.vw_Country') IS NULL
                      THEN 'OK dev: vw_Country skipped (ref.Country is not in AppDb_dev); its entity is prod only'
                      ELSE 'FAIL dev: vw_Country exists' END;
INSERT @r SELECT CASE WHEN COUNT(*) > 0 AND COUNT(Category) = 0 THEN 'OK dev: MessageTemplate.Category is NULL (no such base column in dev)'
                      ELSE 'FAIL dev: MessageTemplate.Category' END FROM dataapi.vw_MessageTemplate;
INSERT @r SELECT CASE WHEN TYPE_NAME(c.system_type_id) = N'varchar' AND c.max_length = 20
                      THEN 'OK dev: Category keeps the prod type varchar(20), so the entity is the same in dev and prod'
                      ELSE CONCAT('FAIL dev: Category is ', TYPE_NAME(c.system_type_id), '(', c.max_length, ')') END
FROM sys.columns AS c WHERE c.object_id = OBJECT_ID(N'dataapi.vw_MessageTemplate') AND c.name = N'Category';
INSERT @r SELECT CASE WHEN COUNT(*) = 0 THEN 'OK dev: no DENY exists (04 is prod only)' ELSE 'FAIL dev: DENY rows exist' END
FROM sys.database_permissions WHERE state = 'D';
SELECT line FROM @r;
GO
