---
status: implemented
---

# Identity & audit — appdb-data-api

**Status:** Implemented

## Chain
```
Employee ──(AWS AgentCore inbound)──> verified identity + JWT (role claim)
        ──> DAB runtime.host.authentication validates the JWT
        ──> role claim → DAB permissions[].role  (per-entity authorization)
        ──> DAB connects to SQL under a per-team least-privilege login (connection string)
        ──> set-session-context: true pushes the person's claims into SQL SESSION_CONTEXT()
```

## Authorization (two layers)
1. **API layer (DAB):** each SP entity lists `permissions[].role`. A caller whose JWT role isn't listed
   can't invoke the tool. The curated staging/prod config uses a **single role
   `appdb-data-api-msg-reader`**; **scoped per-team roles come later for production** — add more
   `permissions[].role` entries when access splits.

   > **Dev `dab-config.dev-all.json` already splits this way** (ADR-0005): one deployment, audience
   > `appdb-data-api`, with `appdb-data-api-msg-reader` on the messaging entities and
   > `appdb-data-api-voi-reader` on the `vo_*` (voice) ones. The role, not the deployment, is what
   > stops a messaging caller reading voice — so the OIDC provider must issue exactly the roles a
   > caller is entitled to, and access reviews must cover both.
2. **SQL layer:** the connection login has EXECUTE on the curated SPs **only** — no table access, no
   `sysadmin`. Even if the API layer were bypassed, the login can do nothing else. Use a **readable
   secondary + `ApplicationIntent=ReadOnly`** so writes are impossible at the engine.

## Inbound authentication (AgentCore → the API) — the token issuer
The inbound token is an **ordinary OIDC bearer JWT**: AgentCore (the agentic platform in front of this API)
acts as the issuer, so no separate OIDC-provider integration is needed for AgentCore itself to reach `/mcp` —
but any compliant OIDC provider works here in principle (Entra ID, Okta, Auth0, Keycloak, Cognito, or an
in-house issuer).
Validation is ordinary OIDC bearer: RS256, `kid appdb-oidc-1`, issuer + audience (`appdb-data-api-msg`).
The caller's role comes from the token's `roles` claim — initially the single `appdb-data-api-msg-reader`,
**scoped roles later for prod**. API keys are not an option; DAB's `Unauthenticated` provider is not acceptable for prod.

**Split of responsibility:** AgentCore owns *user* authentication + role resolution; **this API only
authenticates the AgentCore service token.** AgentCore verifies the person (example SSO / Okta / Slack), then
presents a per-role JWT to `/mcp`; DAB validates that JWT and maps its role claim to `permissions[].role`.

**Provider + config are environment-specific** (proc layout verified 2026-07-22):

| Env | Config | Provider | Notes |
|-----|--------|----------|-------|
| local | `dab-config.json` + `DAB_ENVIRONMENT=Local` | `Simulator` | offline only — pass header `X-MS-API-ROLE: appdb-data-api-msg-reader`; no token |
| dev | `config/dab-config.dev.json` (CLI `start -c`) | `EntraID` | standalone, single `AppDb_dev`, `_v5` SMS proc (no masking); caller presents a **DEV**-environment OIDC bearer token |
| staging | `dab-config.json` + `DAB_ENVIRONMENT=Staging` | `EntraID` | prod-shaped (`AppCatalog` + `AppDb_Data`, v2); caller presents a **STG**-environment OIDC bearer token |
| prod | `dab-config.json` *(no `DAB_ENVIRONMENT`)* | `EntraID` | validates a **PRD**-environment OIDC bearer JWT: `AUTH_JWT_ISSUER` = the OIDC provider's issuer URL, `AUTH_JWT_AUDIENCE` = this API's registered audience (`appdb-data-api-msg`) |

**Auth = ordinary OIDC bearer.** All non-local envs validate an OIDC JWT
(RS256, `kid: appdb-oidc-1`, `iss`/`aud`/`exp`, `roles` string-array, `sub = slack-<user_id>`). DAB matches the
token's `roles` entries to `permissions[].role` **by exact string**. The `sub`/`email`/`name` claims give per-person
audit even though all DB traffic shares the `svc_dataapi` login. Any compliant OIDC provider can issue this token
(Entra ID, Okta, Auth0, Keycloak, Cognito, or an in-house issuer) — the provider must:
1. serve `{issuer}/.well-known/openid-configuration` (DAB discovers the JWKS from it);
2. issue tokens whose `aud` matches `AUTH_JWT_AUDIENCE`;
3. emit a `roles` claim containing the exact role string the config expects — DAB matches role strings exactly,
   it does not normalise case or trim;
4. expose a JWKS URI reachable from the cluster, if the Istio `RequestAuthentication` is enabled.

**Still open for this deployment:** (1) confirm the audience `appdb-data-api-msg` resolves to a role of exactly
`appdb-data-api-msg-reader` in the `roles` claim, or rename the DAB role to match whatever string the provider
emits; (2) obtain the **STG + PRD** issuer/JWKS URLs (currently only DEV is registered) and confirm the registered
audience is `appdb-data-api-msg` in both.

## The audit caveat (important for SOX)
DAB connects with **one shared login per team role**, so `sys.dm_exec_sessions.login_name` shows the
**role login, not the person**. Two mitigations, use both:

- **Primary identity record = the AgentCore / DAB request log.** AgentCore has the verified employee
  identity on every call; ensure those logs are retained and queryable for access reviews.
- **`set-session-context: true`** (already set in every data source) copies the JWT claims into
  `SESSION_CONTEXT()`. So a login trigger / Extended Events / an SP can capture
  `SESSION_CONTEXT(N'<claim>')` and record the **person** alongside the role login — recovering
  per‑person attribution at the SQL layer. Confirm which claim carries the UPN/email and read that key.

## Why not OBO (On-Behalf-Of)? — evaluated, rejected
DAB 2.0 adds **OBO / user-delegation**: it exchanges the caller's inbound JWT for a downstream SQL token so
the database authenticates **as the real person** — which would fully solve the shared-login attribution gap
above (no `set-session-context` reconstruction needed). We **rejected** it for this fleet because it requires:
- **MSSQL configured to accept Microsoft Entra ID tokens** — our SQL 2022 nodes are on GCP/AWS VMs, not
  Entra-authenticated Azure SQL; and inbound identity here is **AWS AgentCore**, not Entra.
- **`runtime.cache` disabled** (OBO keeps per-user connection pools; DAB forbids caching with OBO) — we
  depend on caching to protect the config DBs from repeated identical lookups.
- Entra app registration + `DAB_OBO_CLIENT_ID`/`_TENANT_ID`/`_CLIENT_SECRET`.

So the chosen mitigation stays **`set-session-context: true`** (person recoverable at the SQL layer) + the
AgentCore request log (primary identity record) + OpenTelemetry traces of MCP tool execution. Revisit OBO only
if the fleet moves to Entra-authenticated SQL and we can drop caching on a specific path.

## Authorization guardrail: role inheritance (DAB 2.0)
DAB 2.0 resolves permissions along `named-role → authenticated → anonymous`. Because `appdb-data-api-msg-reader`
is a named role, **any grant on `anonymous` or `authenticated` would be inherited by it**. Keep both
**ungranted** (they appear nowhere in `permissions[]`); with `provider: EntraID`, a validly-authenticated caller
whose role isn't `appdb-data-api-msg-reader` then resolves to *no* entity access. Verify with
`dab configure --show-effective-permissions` before deploy.

## SOX access-review implications
The quarterly UAR (see the SQL access-review automation) enumerates **per-user SQL logins**.
`appdb-data-api` adds an access path that is **role-login + JWT-role**, so the review must also cover:
(a) who is assigned the role `appdb-data-api-msg-reader` in the OIDC provider (and any scoped roles added later), and (b) the EXECUTE
grants on the curated SPs for those role logins. Document this so the reviewer doesn't miss the DAB path.
