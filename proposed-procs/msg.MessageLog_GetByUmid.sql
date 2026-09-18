-- =============================================
-- Author: Renz Bagasbas
-- Created date: 2026-07-14
-- Description: Fast single-message lookup by UMID from the live SMS log, PII masked by default.
--              Lightweight direct-index alternative to the the cloud data warehouse-backed core.MessageLog_SearchByFilter_v2
--              for hot lookups. Home DB: AppDb_Data (region-local). Sanctioned vetted-SP access to
--              msg.MessageLog — NOT raw table exposure. EXCLUDES commercial price/cost columns entirely.
-- Usage: EXEC msg.MessageLog_GetByUmid @Umid = '00000000-0000-0000-0000-000000000000', @MaskSensitiveData = 1
-- =============================================
-- PROPOSAL — not yet deployed. Review, register in AppDb_MSG_data.sqlproj, add GRANT, then deploy.
CREATE PROCEDURE msg.MessageLog_GetByUmid
	@Umid              UNIQUEIDENTIFIER,
	@MaskSensitiveData BIT = 1
AS
BEGIN
	SET NOCOUNT ON;

	SELECT
		l.UMID,
		l.SmsTypeId,             -- 0=MO,1=MT,2=RCS_MO,3=RCS_MT_TEXT,4=RCS_MT_MEDIA
		l.StatusId,              -- 10-level delivery model; decode via msg.DimMessageStatus
		l.Country,
		l.OperatorId,
		l.SubAccountUid,
		l.Source,                -- sender id / originator
		-- Destination number: masked unless explicitly unmasked (authorized)
		CASE WHEN @MaskSensitiveData = 1
			 THEN '******' + RIGHT(CONVERT(varchar(20), l.MSISDN), 3)
			 ELSE CONVERT(varchar(20), l.MSISDN) END AS MSISDN,
		-- Message body: withheld unless explicitly unmasked (authorized)
		CASE WHEN @MaskSensitiveData = 1 THEN NULL ELSE l.Body END AS Body,
		l.SegmentsReceived,
		l.DCS,
		l.ConnMessageId,
		l.ConnErrorCode,
		l.ClientMessageId,
		l.ClientBatchId,
		l.BatchId,
		l.TrafficCategory,
		l.RoutingPlanId,
		l.EndpointId,
		l.CreatedTime,
		l.UpdatedTime,
		l.ExpiryTime
	FROM msg.MessageLog AS l
	WHERE l.UMID = @Umid;
END
GO

-- GRANT EXECUTE ON OBJECT::msg.MessageLog_GetByUmid TO <api_reader_role> AS dbo;
-- GO
