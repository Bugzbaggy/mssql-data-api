/* ============================================================================
   appdb-data-api — least-privilege login + EXECUTE grants
   ----------------------------------------------------------------------------
   A SQL login is a SERVER principal and does NOT travel inside the AG, so it must
   be created on EVERY replica node with a MATCHING SID (or users orphan after a
   failover / when read-only routing lands you on a secondary).
   The database USER + role + grants live inside the AG database and REPLICATE
   automatically — create them ONCE on each AG's primary.

   Order:
     PART A  — run on EVERY prod SQL node (all replicas of every AG the API reads)
     PART B  — run ONCE on the global-config AG primary (AppCatalog / AppDb)
     PART C  — run ONCE on EACH region's AppDb_Data AG primary (ID, UK, US)

   Replace <StrongPwd> with a value from the secret store (NOT committed here).
   ============================================================================ */

/* ---------- PART A · LOGIN — every replica node, matching SID ------------- */
-- A1. On the FIRST node only: create the login and copy its SID.
CREATE LOGIN svc_dataapi WITH PASSWORD = N'<StrongPwd>', CHECK_POLICY = ON;
GO
SELECT CONVERT(varchar(100), sid, 1) AS sid_hex
FROM sys.sql_logins WHERE name = N'svc_dataapi';   -- copy the 0x... value
GO
-- A2. On EVERY OTHER replica node: same password, SAME sid.
-- CREATE LOGIN svc_dataapi WITH PASSWORD = N'<StrongPwd>', SID = 0x<paste_from_A1>, CHECK_POLICY = ON;
-- GO
-- Nodes to cover: REGION1-NODE1, REGION1-NODE2, region2-node4, region2-node5,
--                 REGION3-NODE1, REGION3-NODE2, REGION4-NODE1, REGION4-NODE2.

/* ---------- PART B · GLOBAL CONFIG DB — once on the SG AG primary --------- */
USE AppCatalog;   -- (AppDb on the regional subscriber copies, if granted separately)
GO
CREATE USER svc_dataapi FOR LOGIN svc_dataapi;
CREATE ROLE role_svc_dataapi;
ALTER ROLE role_svc_dataapi ADD MEMBER svc_dataapi;
GO
GRANT EXECUTE ON OBJECT::core.Account_SubAccount_GetAll TO role_svc_dataapi;
GRANT EXECUTE ON OBJECT::svc.SubAccount_Get            TO role_svc_dataapi;
GRANT EXECUTE ON OBJECT::core.BillingBalance_Get        TO role_svc_dataapi;
GRANT EXECUTE ON OBJECT::core.Channels_ConfigGet        TO role_svc_dataapi;
GO
-- After deploying the drafted procs (appdb-data-api/proposed-procs/), also:
-- GRANT EXECUTE ON OBJECT::core.Account_GetByUid       TO role_svc_dataapi;
-- GRANT EXECUTE ON OBJECT::core.Account_ListLowBalance TO role_svc_dataapi;
-- GO

/* ---------- PART C · REGION-LOCAL DB — once per region's AppDb_Data primary */
USE AppDb_Data;     -- run on each secondary region's primary in turn
GO
CREATE USER svc_dataapi FOR LOGIN svc_dataapi;
CREATE ROLE role_svc_dataapi;
ALTER ROLE role_svc_dataapi ADD MEMBER svc_dataapi;
GO
GRANT EXECUTE ON OBJECT::core.MessageLog_SearchByFilter_v2 TO role_svc_dataapi;
GRANT EXECUTE ON OBJECT::msg.MessageRegionLookup_Get      TO role_svc_dataapi;
GO
-- After deploying the drafted proc:
-- GRANT EXECUTE ON OBJECT::msg.MessageLog_GetByUmid          TO role_svc_dataapi;
-- GO

/* ---------- Verify (run on each DB) --------------------------------------- */
-- SELECT p.name AS principal, o.name AS proc_granted, dp.permission_name, dp.state_desc
-- FROM sys.database_permissions dp
-- JOIN sys.objects o  ON o.object_id = dp.major_id
-- JOIN sys.database_principals p ON p.principal_id = dp.grantee_principal_id
-- WHERE p.name IN (N'svc_dataapi', N'role_svc_dataapi') AND dp.permission_name = 'EXECUTE'
-- ORDER BY o.name;

/* ============================================================================
   PREREQ FIX — ID & UK read-only routing point at :5022 (HADR endpoint), not :1433,
   so ApplicationIntent=ReadOnly will NOT route there until corrected. SG/US are fine.
   Run on the ID / UK AG primary:

   ALTER AVAILABILITY GROUP [ag-region2-cluster] MODIFY REPLICA ON N'region2-node4'
     WITH (SECONDARY_ROLE (READ_ONLY_ROUTING_URL = N'TCP://region2-node4.corp.example.com:1433'));
   ALTER AVAILABILITY GROUP [ag-region2-cluster] MODIFY REPLICA ON N'region2-node5'
     WITH (SECONDARY_ROLE (READ_ONLY_ROUTING_URL = N'TCP://region2-node5.corp.example.com:1433'));
   ALTER AVAILABILITY GROUP [ag-uk-cluster] MODIFY REPLICA ON N'REGION3-NODE1'
     WITH (SECONDARY_ROLE (READ_ONLY_ROUTING_URL = N'TCP://REGION3-NODE1:1433'));
   ALTER AVAILABILITY GROUP [ag-uk-cluster] MODIFY REPLICA ON N'REGION3-NODE2'
     WITH (SECONDARY_ROLE (READ_ONLY_ROUTING_URL = N'TCP://REGION3-NODE2:1433'));
   ============================================================================ */
