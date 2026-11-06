/* ============================================================================
   appdb-data-api — STAGING least-privilege login + grants  (ag-staging1)
   ----------------------------------------------------------------------------
   Staging is a 2-node AG (STAGING-NODE1 / STAGING-NODE2) and prod-shaped:
     - global tools live in AppCatalog
     - region-local SMS tools live in AppDb_Data  (v2, same as prod)
   Confirm first that both AppCatalog and AppDb_Data are in AG 'ag-staging1';
   if they are, DB-level user/role/grants REPLICATE to the secondary — create them ONCE on
   the AG PRIMARY. A LOGIN is a server principal and does NOT replicate — create it
   on BOTH nodes with a MATCHING SID. Replace <StrongPwd> from the staging secret store.

   Order:
     PART A  -> both nodes (matching SID)
     PART B  -> AppCatalog on the AG PRIMARY (global tools)
     PART C  -> AppDb_Data  on the AG PRIMARY (region SMS tools)
   ============================================================================ */

/* ---- PART A · LOGIN on BOTH nodes, matching SID ---------------------------- */
-- A1. On the current PRIMARY: create + capture SID
CREATE LOGIN svc_dataapi WITH PASSWORD = N'<StrongPwd>', CHECK_POLICY = ON;
GO
SELECT CONVERT(varchar(100), sid, 1) AS sid_hex FROM sys.sql_logins WHERE name = N'svc_dataapi';  -- copy the 0x... value
GO
-- A2. On the OTHER node (STAGING-NODE1): same password, SAME sid
-- CREATE LOGIN svc_dataapi WITH PASSWORD = N'<StrongPwd>', SID = 0x<paste_from_A1>, CHECK_POLICY = ON;
-- GO

/* ---- PART B · AppCatalog (global tools) — once on the AG PRIMARY -------- */
USE AppCatalog;
GO
CREATE USER svc_dataapi FOR LOGIN svc_dataapi;
CREATE ROLE role_svc_dataapi;
ALTER ROLE role_svc_dataapi ADD MEMBER svc_dataapi;
GO
GRANT EXECUTE ON OBJECT::core.Account_SubAccount_GetAll TO role_svc_dataapi;  -- get_subaccounts_for_account
GRANT EXECUTE ON OBJECT::svc.SubAccount_Get            TO role_svc_dataapi;  -- get_subaccount
GRANT EXECUTE ON OBJECT::core.BillingBalance_Get        TO role_svc_dataapi;  -- get_account_balance
GRANT EXECUTE ON OBJECT::core.Channels_ConfigGet        TO role_svc_dataapi;  -- get_channels_config
GO

/* ---- PART C · AppDb_Data (region-local SMS tools) — once on the AG PRIMARY - */
USE AppDb_Data;
GO
CREATE USER svc_dataapi FOR LOGIN svc_dataapi;
CREATE ROLE role_svc_dataapi;
ALTER ROLE role_svc_dataapi ADD MEMBER svc_dataapi;
GO
GRANT EXECUTE ON OBJECT::core.MessageLog_SearchByFilter_v2 TO role_svc_dataapi;  -- region2_search_sms (staging v2)
GRANT EXECUTE ON OBJECT::msg.MessageRegionLookup_Get      TO role_svc_dataapi;  -- region2_lookup_sms_region_by_umid
GO

/* ---- Verify (run in AppCatalog, then AppDb_Data) ---------------------- */
-- SELECT s.name AS sch, o.name AS proc_granted, dp.permission_name, dp.state_desc
-- FROM sys.database_permissions dp
-- JOIN sys.objects o ON o.object_id = dp.major_id
-- JOIN sys.schemas s ON s.schema_id = o.schema_id
-- JOIN sys.database_principals p ON p.principal_id = dp.grantee_principal_id
-- WHERE p.name = N'role_svc_dataapi' AND dp.permission_name = 'EXECUTE' ORDER BY s.name, o.name;

/* Connections (staging; base dab-config.json + DAB_ENVIRONMENT=Staging):
     CONN_GLOBAL_CONFIG = Server=ag-staging-listener,1433;Database=AppCatalog;User ID=svc_dataapi;Password=<StrongPwd>;
       ApplicationIntent=ReadOnly;MultiSubnetFailover=True;Encrypt=True;TrustServerCertificate=False;Application Name=appdb-data-api
     CONN_REGION2_MSGDATA    = Server=ag-staging-listener,1433;Database=AppDb_Data;User ID=svc_dataapi;Password=<StrongPwd>;
       ApplicationIntent=ReadOnly;MultiSubnetFailover=True;Encrypt=True;TrustServerCertificate=False;Application Name=appdb-data-api
   NOTE: if ag-staging1 has no READ_ONLY_ROUTING_URL configured, ApplicationIntent=ReadOnly
   reads land on the PRIMARY (fine for testing; configure routing later if you want secondary offload). */
