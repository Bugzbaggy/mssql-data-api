-- =============================================
-- Author: Renz Bagasbas
-- Created date: 2026-07-14
-- Description: List accounts at/under a balance threshold (for Ops proactive top-up outreach).
--              Parameterised read — replaces a client-side scan. Home DB: AppCatalog / AppDb (global).
--              @Threshold NULL => use each wallet's own LowBalanceThreshold. Optional @Currency filter.
-- Usage: EXEC core.Account_ListLowBalance @Threshold = 10.00, @Currency = 'USD', @MaxRows = 200
-- =============================================
-- PROPOSAL — not yet deployed. Review, register in AppDb_MSG.sqlproj, add GRANT, then deploy.
CREATE PROCEDURE core.Account_ListLowBalance
	@Threshold DECIMAL(18,4) = NULL,
	@Currency  CHAR(3)       = NULL,
	@MaxRows   INT           = 200
AS
BEGIN
	SET NOCOUNT ON;

	SELECT TOP (@MaxRows)
		a.AccountUid,
		a.AccountId,
		a.AccountName,
		a.Country,
		w.Currency,
		w.Balance,
		w.OverdraftLimit,
		w.LowBalanceThreshold,
		w.LowBalanceAlerted,
		w.LastUpdatedAt
	FROM core.AccountBalanceGlobal AS w
	INNER JOIN core.Account AS a ON a.AccountUid = w.AccountUid
	WHERE a.Deleted = 0
	  AND (w.ValidBalance = 1 OR w.ValidBalance IS NULL)
	  AND (@Currency IS NULL OR w.Currency = @Currency)
	  AND w.Balance <= COALESCE(@Threshold, w.LowBalanceThreshold, 0)
	ORDER BY w.Balance ASC;
END
GO

-- GRANT EXECUTE ON OBJECT::core.Account_ListLowBalance TO <api_reader_role> AS dbo;
-- GO
