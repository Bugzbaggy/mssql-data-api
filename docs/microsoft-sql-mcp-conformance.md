---
status: implemented
---

# Conformance to Microsoft SQL MCP Server guidance

**Status:** Implemented · reviewed 2026-07-30

appdb-data-api is built on **Microsoft Data API builder (DAB) SQL MCP Server**. This note maps Microsoft's
own SQL MCP guidance (and the widely-cited DBA field guidance on it) to what this solution actually does, so
security review / SOX / stakeholders can confirm it meets — and where noted, **exceeds** — that guidance. Every
row was validated against the live config (`dab-config.json`, `config/dab-config.*.json`), not asserted.

## Conformance matrix

| Microsoft SQL MCP guidance | appdb-data-api implementation | Status |
|---|---|---|
| Toggle DML tools; disable delete/update at runtime, re-enable per entity | `runtime.mcp.dml-tools` enables **only** `describe-entities` + `execute-entity`; `read-records`, `create-record`, `update-record`, `delete-record`, `aggregate-records` are all `false` | **Exceeds** — all writes + table reads off globally, not just delete |
| Prefer NL2DAB (deterministic query builder) over NL2SQL (arbitrary AI-written T-SQL) | Exposes **stored procedures only** via `execute-entity` — no `read-records` on tables, no free-form SQL | **Exceeds** — strongest form of NL2DAB |
| "Agents only see what you tell them" — expose specific tables | **Zero** table/view entities (100% `stored-procedure`); never exposes `msg.MessageLog` or any raw table | **Exceeds** |
| Field-level exclusion of sensitive columns (`fields.include`/`exclude`) | N/A — no tables/views exposed. PII is masked **inside the SP** (`MaskSensitiveData` defaults to `true`: masks destination MSISDN, redacts body) | Handled at SP layer (arguably stronger — data never leaves the DB unmasked) |
| Treat agent access like a service account: minimum privilege, read-only | `svc_dataapi` login = `EXECUTE` on the curated SPs only, no `sysadmin`, no table rights; **readable secondary + `ApplicationIntent=ReadOnly`** | ✅ |
| RBAC configured once, applied across REST + GraphQL + MCP | One config; `permissions[].role` governs all three endpoints | ✅ |
| Add semantic descriptions so agents read documented meaning, not guesses | Rich per-tool descriptions with **enum/code decodings inlined** (SMS status, channel type, the messaging channel template status, product flags) | ✅ |
| GraphQL introspection off in production | Off in base/prod (`allow-introspection: false`); on only in the dev config | ✅ |
| Don't allow unsupervised writes to production | Read-only by charter; no write tool exists | ✅ |

## Where appdb-data-api goes beyond the guidance

Microsoft's quick-start examples use `anonymous:read`. This solution is materially stronger:

- **Inbound auth:** OIDC bearer JWT (DAB `EntraID` provider — ordinary OIDC bearer validation, any compliant
  provider works; RS256, issuer/audience `appdb-data-api-msg`) — no
  anonymous access; `anonymous`/`authenticated` roles are granted **nothing** so role inheritance can't widen access.
- **Per-person audit** despite a shared DB login: `set-session-context` pushes the caller's claims into
  `SESSION_CONTEXT()`, plus OpenTelemetry traces. See `docs/identity-and-audit.md`.
- **PII masking** pinned in config (not left to the caller or the SP default).
- **Multi-region** via `data-source-files` (global config source + region-local `AppDb_Data`).

## Deliberately out of scope (not gaps)

- **DMV / performance-troubleshooting entities** (`sys.dm_exec_query_stats`, `sys.dm_os_wait_stats`) — that is DBA
  diagnostics, owned by the separate **`appdb-sql-mcp`** server, not this app-data API.
- **Write tools / per-entity write re-enable** — this API is read-only by charter.
- **`anonymous:read`** — explicitly forbidden here.

## Deploy gates (enforce this conformance)

Both are pre-deploy gates in `deploy/README.md` (step 0), run for every environment:

- `dab validate -c dab-config.json` — config conforms to the pinned DAB 2.x schema.
- `dab configure --show-effective-permissions` — proves `appdb-data-api-msg-reader` sees only its tools and
  `anonymous`/`authenticated` see none.
