---
status: implemented
---

# Identity & audit — appdb-data-api

**Status:** Implemented

## Chain
```
Person ──(an upstream gateway that issues JWTs: it signs the person in and picks their roles)
       ──> bearer JWT (iss, aud, exp, roles claim) on every request to /mcp
       ──> the mesh (Istio RequestAuthentication) validates the JWT; in prod only /mcp is open to JWT callers
       ──> DAB runtime.host.authentication validates the same JWT again (issuer + audience)
       ──> X-MS-API-ROLE names one role from the roles claim → DAB permissions[].role (per-entity authorization)
       ──> DAB connects to SQL under one least-privilege login (connection string)
       ──> set-session-context: true pushes the person's claims into SQL SESSION_CONTEXT()
```

## Authorization (two layers)
1. **API layer (DAB):** each SP entity lists `permissions[].role`. A caller whose JWT role isn't listed
   can't invoke the tool. The curated staging/prod config uses a **single role
   `appdb-data-api-msg-reader`**; **scoped per-team roles come later for production** — add more
   `permissions[].role` entries when access splits.

   > **Dev `dab-config.dev-all.json` already splits this way:** one deployment, audience
   > `appdb-data-api`, with `appdb-data-api-msg-reader` on the messaging entities and
   > `appdb-data-api-voi-reader` on the voice ones (the `config/dev-all/*.vo.*.json` children — Gate
   > RBAC pins the role by filename). The role, not the deployment, is what
   > stops a messaging caller reading voice — so the OIDC provider must issue exactly the roles a
   > caller is entitled to, and access reviews must cover both.
   > **The staged Ops entities** (`deploy/ops-expansion/`, not loaded by any config here) use a second
   > role, `appdb-data-api-ops-reader`, on the same deployment and the same SQL login. The JWT role keeps
   > those callers apart from the curated ones; there is no second login.
2. **SQL layer:** in staging and prod the connection login has EXECUTE on the curated SPs **only** — no
   table access, no `sysadmin` (`deploy/01-` and `03-…-create-login-and-grants.sql`). Even if the API
   layer were bypassed, the login can do nothing else. Serving a table adds `SELECT` on its projection view
   only, never on the table, and a `DENY SELECT` on every object behind the views for the login's user
   ([`adding-tables-safely.md`](adding-tables-safely.md)). Use a **readable secondary +
   `ApplicationIntent=ReadOnly`** so writes are impossible at the engine. The dev login is broader by
   design: strict read-only across every dev database (`deploy/02-dev-create-login-and-grants.sql`).

## Inbound authentication — the token issuer
The inbound token is an **ordinary OIDC bearer JWT**. In the intended deployment it comes from an upstream
gateway that issues JWTs: the gateway signs the person in (company SSO) and decides which roles they hold, then
calls `/mcp` with a token it signs. Any compliant OIDC issuer works the same way: Entra ID, Okta, Auth0, Keycloak,
Cognito, or an in-house issuer. API keys are not an option, and DAB's `Unauthenticated` provider is not
acceptable for prod.

**How the API is configured.** Every non-local config carries the same block:

```json
"authentication": {
  "provider": "EntraID",
  "jwt": { "audience": "@env('AUTH_JWT_AUDIENCE')", "issuer": "@env('AUTH_JWT_ISSUER')" }
}
```

`EntraID` is DAB's name for its JWT bearer handler; despite the name it validates any issuer that serves OIDC
discovery, not only Entra ID. The values are plain environment variables, public OIDC values rather than secrets:
`AUTH_JWT_ISSUER` is the issuer URL exactly as the token's `iss` carries it (for example
`https://issuer.example.com/`), and `AUTH_JWT_AUDIENCE` is this API's registered audience (for example
`appdb-data-api`). The Helm chart takes them as `auth.jwtIssuer` and `auth.jwtAudience`, plus `auth.jwksUri` for the
mesh; all three are `required`, so an empty one fails the render instead of shipping an API that trusts nothing.

**Two places validate the token.** The mesh's `RequestAuthentication` checks signature, issuer, audience and expiry
against `auth.jwksUri`, before any request reaches a pod; DAB checks issuer, audience and signature again, from the
issuer's discovery document. A missing or invalid token never reaches DAB's entities.

**Roles.** The token's `roles` claim is a string array. DAB matches each entry to `permissions[].role` **by exact
string**: no case folding, no trimming. A caller names the role it acts as in the `X-MS-API-ROLE` header, which must
be one of the token's roles; without the header DAB evaluates the request as `authenticated`, which holds no
grants here, so it gets 403. The `sub`, `email` and `name` claims give per-person audit even though all database
traffic shares the `svc_dataapi` login.

**Only the MCP endpoint, in prod.** The mesh's `AuthorizationPolicy` (`deploy/chart/templates/authpolicy.yaml`)
lets anyone reach `/health`, which reports the data-source check only, and lets a caller with a validated token reach
exactly the paths in `istio.allowedPaths`. A request with no token matches no rule (403 at the mesh); a token that
fails validation gets 401 from `RequestAuthentication` on every path. Production pins `istio.allowedPaths: ["/mcp"]`,
so `/api` and `/graphql` are refused at the mesh and agents reach only the MCP endpoint. Dev leaves the list empty,
so the post-deploy access smoke can run its REST checks there; in prod the smoke proves instead that REST and
GraphQL are closed (`ci/access-smoke.sh --expect-rest closed`). The chart tests render both shapes (dev, and the
production shape: two replicas, MCP only, session affinity) and pin each one's policy rules.

**MCP sessions.** DAB keeps each MCP session in the memory of the pod that answered `initialize`. The gateway sends
the same bearer token on every request of a session (`initialize`, `notifications/initialized`, `tools/call`), so a
render with more than one replica hashes on the `authorization` header in its `DestinationRule`
(`istio.destinationRule.consistentHashHeader`) to keep a session on one pod; the chart tests fail a multi-replica
render without it.

**Split of responsibility:** the gateway owns *user* authentication and role assignment; **this API only validates
the token the gateway presents** and maps its role to `permissions[].role`.

**Provider + config are environment-specific** (proc layout verified 2026-07-22):

| Env | Config | Provider | Notes |
|-----|--------|----------|-------|
| local | `dab-config.json` + `DAB_ENVIRONMENT=Local` | `Simulator` | offline only — pass header `X-MS-API-ROLE: appdb-data-api-msg-reader`; no token |
| dev | chart: `dab-config.dev-all.json` (CLI `start -c`); EC2 path: `config/dab-config.dev.json` (CLI `start -c`) | `EntraID` | chart: broad read-only across both dev hosts, roles split per entity. EC2: standalone, single `AppDb_dev`, `_v5` SMS proc (no masking). Caller presents a **DEV**-environment OIDC bearer token |
| staging | `dab-config.json` + `DAB_ENVIRONMENT=Staging` | `EntraID` | prod-shaped (`AppCatalog` + `AppDb_Data`, v2); caller presents a **STG**-environment OIDC bearer token |
| prod | `dab-config.json` *(no `DAB_ENVIRONMENT`)* | `EntraID` | validates a **PRD**-environment OIDC bearer JWT: `AUTH_JWT_ISSUER` = the issuer's URL, `AUTH_JWT_AUDIENCE` = this API's registered audience (for example `appdb-data-api`, one audience for every environment, roles split per entity) |

**Auth = ordinary OIDC bearer.** All non-local envs validate an OIDC JWT (signature from the issuer's JWKS, `iss`,
`aud`, `exp`, a `roles` string array). Whichever issuer you use, a gateway or an identity provider, it must:
1. serve `{issuer}/.well-known/openid-configuration` (DAB discovers the JWKS from it);
2. issue tokens whose `iss` equals `AUTH_JWT_ISSUER` and whose `aud` matches `AUTH_JWT_AUDIENCE`;
3. emit a `roles` claim containing the exact role strings the configs expect (`appdb-data-api-msg-reader`, and
   `appdb-data-api-ops-reader` if the Ops entities are enabled) — DAB matches role strings exactly, it does not
   normalise case or trim; check the literal string in a decoded token, not a label in the provider's console;
4. expose a JWKS URI reachable from the cluster (`auth.jwksUri`), for the mesh's `RequestAuthentication`;
5. carry a claim that names the person (`sub`, `email` or `name`), for the audit trail below.

Before go-live, decode one token from each environment's issuer and confirm all five against the values the chart
and the configs carry.

## The audit caveat (important for SOX)
DAB connects with **one shared login per team role**, so `sys.dm_exec_sessions.login_name` shows the
**role login, not the person**. Two mitigations, use both:

- **Primary identity record = the gateway's and DAB's request logs.** The gateway that issues the token has
  the verified person on every call; ensure those logs are retained and queryable for access reviews.
- **`set-session-context: true`** (already set in every data source) copies the JWT claims into
  `SESSION_CONTEXT()`. So a login trigger / Extended Events / an SP can capture
  `SESSION_CONTEXT(N'<claim>')` and record the **person** alongside the role login — recovering
  per‑person attribution at the SQL layer. Confirm which claim carries the UPN/email and read that key.

## Why not OBO (On-Behalf-Of)? — evaluated, rejected
DAB 2.0 adds **OBO / user-delegation**: it exchanges the caller's inbound JWT for a downstream SQL token so
the database authenticates **as the real person** — which would fully solve the shared-login attribution gap
above (no `set-session-context` reconstruction needed). We **rejected** it for this fleet because it requires:
- **MSSQL configured to accept Microsoft Entra ID tokens** — our SQL 2022 nodes are on GCP/AWS VMs, not
  Entra-authenticated Azure SQL; and inbound identity here comes from **an upstream gateway's JWT**, not Entra.
- **`runtime.cache` disabled** (OBO keeps per-user connection pools; DAB forbids caching with OBO) — we
  depend on caching to protect the config DBs from repeated identical lookups.
- Entra app registration + `DAB_OBO_CLIENT_ID`/`_TENANT_ID`/`_CLIENT_SECRET`.

So the chosen mitigation stays **`set-session-context: true`** (person recoverable at the SQL layer) + the
gateway's request log (primary identity record) + OpenTelemetry traces of MCP tool execution once enabled (`dab-config.json`
and `config/dab-config.dev.json` carry a `runtime.telemetry.open-telemetry` block, set `enabled: false` until an OTLP endpoint exists). Revisit OBO only
if the fleet moves to Entra-authenticated SQL and we can drop caching on a specific path.

## Authorization guardrail: role inheritance (DAB 2.0)
DAB 2.0 resolves permissions along `named-role → authenticated → anonymous`. Because `appdb-data-api-msg-reader`
is a named role, **any grant on `anonymous` or `authenticated` would be inherited by it**. Keep both
**ungranted** (they appear nowhere in `permissions[]`); with `provider: EntraID`, a validly-authenticated caller
whose role isn't `appdb-data-api-msg-reader` then resolves to *no* entity access. Verify with
`dab configure --show-effective-permissions` before deploy.

## SOX access-review implications
A quarterly user-access review (UAR) of SQL logins enumerates **per-user SQL logins**.
`appdb-data-api` adds an access path that is **role-login + JWT-role**, so the review must also cover:
(a) who is assigned the role `appdb-data-api-msg-reader` in the OIDC provider (and any scoped roles added later), and (b) the EXECUTE
grants on the curated SPs for those role logins. Document this so the reviewer doesn't miss the DAB path.
