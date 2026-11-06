-- Gate SQL-VIEWS: checks that hold in the prod and dev shapes alike. sqlcmd variables: DABUSER (svc_dataapi or
-- dev_svc_dataapi) and DABROLE (role_svc_dataapi or role_dev_svc_dataapi). Every result line starts with OK or FAIL;
-- run.sh fails the gate on any FAIL.
SET NOCOUNT ON;
GO
-- 1. Grants: each dataapi view holds exactly one permission, SELECT granted to the DAB role, and nothing else in the
--    schema (the URL function, the schema itself) is granted to anyone.
DECLARE @views int = (SELECT COUNT(*) FROM sys.views WHERE schema_id = SCHEMA_ID(N'dataapi'));
DECLARE @bad int = (
    SELECT COUNT(*) FROM sys.database_permissions AS p
    JOIN sys.objects AS o ON o.object_id = p.major_id
    WHERE p.class = 1 AND o.schema_id = SCHEMA_ID(N'dataapi')
      AND NOT (o.type = 'V' AND p.permission_name = N'SELECT' AND p.state = 'G'
               AND p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'$(DABROLE)')));
DECLARE @ungranted int = (
    SELECT COUNT(*) FROM sys.views AS v WHERE v.schema_id = SCHEMA_ID(N'dataapi')
      AND NOT EXISTS (SELECT 1 FROM sys.database_permissions AS p
                      WHERE p.major_id = v.object_id AND p.permission_name = N'SELECT' AND p.state = 'G'
                        AND p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'$(DABROLE)')));
DECLARE @schema_grants int = (SELECT COUNT(*) FROM sys.database_permissions WHERE class = 3 AND major_id = SCHEMA_ID(N'dataapi'));
SELECT CASE WHEN @views > 0 AND @bad = 0 AND @ungranted = 0 AND @schema_grants = 0
            THEN CONCAT('OK grants: ', @views, ' dataapi views, each SELECT to $(DABROLE) only; the function and the schema granted to no one')
            ELSE CONCAT('FAIL grants: ', @views, ' views, ', @bad, ' unexpected grants, ', @ungranted, ' views without the DAB grant, ',
                        @schema_grants, ' schema-level grants') END;
GO
-- 2. DAB's startup read (SET FMTONLY ON; SELECT *) works on every view as the DAB user, and 3. no CANARY value
--    reaches the output: the fixtures put CANARY in every value the API must never return, so a view that serves one,
--    or cuts a URL in the wrong place, shows it here.
DECLARE @r TABLE (line nvarchar(4000));
DECLARE @v nvarchar(300), @s nvarchar(max), @j nvarchar(max), @n int = 0;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + N'.' + QUOTENAME(name) FROM sys.views
    WHERE schema_id = SCHEMA_ID(N'dataapi') ORDER BY name;
OPEN c; FETCH NEXT FROM c INTO @v;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @n += 1;
    BEGIN TRY
        EXECUTE AS USER = N'$(DABUSER)';
        EXEC (N'SET FMTONLY ON; SELECT * FROM ' + @v + N'; SET FMTONLY OFF;');
        SET @s = N'SET @j = (SELECT TOP (5000) * FROM ' + @v + N' FOR JSON PATH, INCLUDE_NULL_VALUES);';
        EXEC sys.sp_executesql @s, N'@j nvarchar(max) OUTPUT', @j = @j OUTPUT;
        REVERT;
        IF @j LIKE N'%CANARY%'
            INSERT @r VALUES (CONCAT(N'FAIL canary: ', @v, N' returns a value it must withhold: ',
                                     SUBSTRING(@j, CHARINDEX(N'CANARY', @j) - 60, 140)));
        IF @j IS NULL
            INSERT @r VALUES (CONCAT(N'FAIL ', @v, N' returned no rows, so the CANARY check proved nothing'));
    END TRY
    BEGIN CATCH
        IF USER_NAME() = N'$(DABUSER)' REVERT;
        INSERT @r VALUES (CONCAT(N'FAIL read as $(DABUSER): ', @v, N': Msg ', ERROR_NUMBER(), N' ', ERROR_MESSAGE()));
    END CATCH;
    FETCH NEXT FROM c INTO @v;
END;
CLOSE c; DEALLOCATE c;
IF NOT EXISTS (SELECT 1 FROM @r)
    INSERT @r VALUES (CONCAT(N'OK ', @n, N' views: FMTONLY SELECT * works as $(DABUSER), every view returns rows, and none holds a CANARY value'));
SELECT line FROM @r;
GO
-- 4. A served host never keeps a login (@), a query string, a fragment or a path.
EXECUTE AS USER = N'$(DABUSER)';
DECLARE @bad int = (SELECT COUNT(*) FROM dataapi.vw_Webhook
                    WHERE UrlHost LIKE N'%@%' OR UrlHost LIKE N'%?%' OR UrlHost LIKE N'%#%' OR UrlHost LIKE N'%://%/%'
                       OR UrlHost LIKE N'%\%' OR UrlHost LIKE N'% %');
REVERT;
SELECT CASE WHEN @bad = 0 THEN 'OK no served UrlHost keeps a login, a query, a fragment or a path'
            ELSE CONCAT('FAIL ', @bad, ' served UrlHost values keep a login, query, fragment or path') END;
GO
