# Proposed stored procedures (not yet deployed)

These are **proposals** for the read-by-key procedures `appdb-data-api` needs but that don't yet exist in
the database. They are **not** deployed and **not** wired into the live `dab-config.json` — wiring a DAB
`execute` entity to a non-existent procedure would make that tool throw at runtime.

## Why they exist
`appdb-data-api` deliberately exposes only vetted read-by-key SPs. Three needs had no clean proc (only
parameterless bulk procs, which are full-scan anti-patterns we refuse to expose):

| Proposed proc | DB (home) | Replaces the anti-pattern |
|---|---|---|
| `core.Account_GetByUid` | global — `AppCatalog`/`AppDb` (**appdb-msg-db** `AppDb_MSG`) | `mage_ai.Account_Get` (parameterless → returns everything) |
| `core.Account_ListLowBalance` | global — `AppCatalog`/`AppDb` (**appdb-msg-db** `AppDb_MSG`) | no proc existed; avoids a client-side scan |
| `msg.MessageLog_GetByUmid` | region-local — `AppDb_Data` (**appdb-msg-db** `AppDb_MSG_data`) | lighter than the the cloud data warehouse-backed `core.MessageLog_SearchByFilter_v2` for hot single-UMID lookups |

> The 4th original TODO — *per-sub-account SMS config* — is **already covered** by `svc.SubAccount_Get`
> (wired as `get_subaccount`), so no new proc is proposed for it.

## Status / caveats
- Bodies reference **real columns** verified against the live `core.Account` schema (2026-07-14), except lines
  marked `-- REVIEW:` where the column/table name must be confirmed (wallet balance column;
  `AppDb_Data.msg.MessageLog` projection). **A DBA must validate before deploy.**
- Sensitive columns are deliberately **excluded** from the projections (`Billing_StripeId`,
  `Billing_PaypalId`, full destination MSISDN / message body) — the API must not surface them.

## Activation (two steps)
1. **Deploy the SP.** Move the reviewed `.sql` into the **appdb-msg-db** repo under the right project
   (`AppDb_MSG/core/Stored Procedures/` for the global ones, `AppDb_MSG_data/msg/Stored Procedures/` for the SMS one),
   **register it in the `.sqlproj`** (`<Build Include=...>` — required or it won't compile into the dacpac),
   add the `GRANT EXECUTE ... TO <least-privilege api role>`, and deploy.
2. **Wire the DAB entity.** Copy the matching block from [`../config/dab-config.pending.json`](../config/dab-config.pending.json):
   the two **global** entities go into `dab-config.json` `entities`; the **region-local** `msg.MessageLog_GetByUmid`
   entity goes into each `config/dab-config.<region>.json` with a region-prefixed name (e.g. `id_get_sms_by_umid` — the true single-UMID lookup the BQ-backed `id_search_sms` cannot provide).
   Then `dab validate` and redeploy.
