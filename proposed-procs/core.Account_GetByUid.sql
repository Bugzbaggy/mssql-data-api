-- =============================================
-- Author: Renz Bagasbas
-- Created date: 2026-07-14
-- Description: Return one account's identity, enabled products, currency and status by AccountUid.
--              Read-by-key replacement for the parameterless mage_ai.Account_Get. Deliberately EXCLUDES
--              sensitive billing tokens (Stripe/PayPal ids). Home DB: AppCatalog / AppDb (global).
-- Usage: EXEC core.Account_GetByUid @AccountUid = '00000000-0000-0000-0000-000000000000'
-- =============================================
-- PROPOSAL — not yet deployed. Review, register in AppDb_MSG.sqlproj, add GRANT, then deploy.
CREATE PROCEDURE core.Account_GetByUid
	@AccountUid UNIQUEIDENTIFIER
AS
BEGIN
	SET NOCOUNT ON;

	SELECT
		a.AccountUid,
		a.AccountId,
		a.AccountName,
		a.CompanyName,
		a.Country,
		a.AccountCurrency,
		a.CustomerType,
		a.CustomerCategory,
		a.BillingMode,
		a.RegionId,
		a.PartnerId,
		a.ManagerId,
		-- Enabled products (bit flags on core.Account)
		a.Product_SMS,
		a.Product_CA,
		a.Product_VI,
		a.Product_VO,
		a.Product_AT,
		a.Product_ALERT,
		a.Product_Verify,
		a.Product_SUBSCRIPTION,
		a.Flag_ShowBalance,
		a.Deleted,
		a.CreatedAt,
		a.UpdatedAt
	FROM core.Account AS a
	WHERE a.AccountUid = @AccountUid;
END
GO

-- GRANT EXECUTE ON OBJECT::core.Account_GetByUid TO <api_reader_role> AS dbo;
-- GO
