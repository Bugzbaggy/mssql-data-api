# Deploy — appdb-data-api

Production deployment artifacts. **No secret ever lives in this folder, in git, or in the image** — the
connection strings (which contain the SQL password) and the inbound JWT settings (issuer/audience for your OIDC provider) are pulled from
**AWS Secrets Manager** at runtime and injected as environment variables.

## Files
| File | Purpose |
|---|---|
| `01-create-login-and-grants.sql` | **PROD**: least-privilege `svc_dataapi` login (every replica, matching SID) + `role_svc_dataapi` + EXECUTE grants (once per AG-database primary). Includes the ID/UK read-only-routing fix. |
| `02-dev-create-login-and-grants.sql` | **DEV** (`DEV-NODE1`, single node): login + grants in `AppDb_dev` on the 6 dev procs (SMS = `…BQ_v5`). No SID matching. |
| `03-staging-create-login-and-grants.sql` | **STAGING** (`ag-staging1`, 2-node AG): login on both nodes (matching SID) + grants in `AppCatalog` (global) and `AppDb_Data` (SMS, `…BQ_v2`) on the primary. |
| `external-secret.yaml` | **PROD** External Secrets Operator → pulls `CONN_*` / `AUTH_*` from AWS Secrets Manager into a k8s Secret. |
| `deployment.yaml` | **PROD** stateless Deployment + Service. **SUPERSEDED-PENDING — do not apply as-is** (see the banner in the file): stale base image and a hard-coded `DAB_ENVIRONMENT=Staging`. Becomes `chart/values/prod.yaml` when the prod pipeline lands. |
| `chart/` | **The deployable.** One Helm chart for every environment; DEV is `chart/values/dev.yaml`. Replaces the former `dev/` manifests, which are deleted. Installed by `.github/workflows/appdb-data-api.yml`. |
| `staging/deployment.yaml` + `staging/external-secret.yaml` | **STAGING (Kubernetes)** (acct 222222222222): base config + `DAB_ENVIRONMENT=Staging`, secrets `CONN_GLOBAL_CONFIG` + `CONN_ID_MSGDATA`. `deployment.yaml` is **SUPERSEDED-PENDING** — see its banner. |
| `ec2/` (`docker-compose.yml`, `.env.ec2-dev.example`, `appdb-data-api.service`, `README.md`) | **EC2 (Docker)** — a fast path: run the container on an EC2 box next to the SQL-MCP EC2 for dev/PoC. Use this first; k8s (`chart/`, `staging/`) later. See `ec2/README.md`. |

## Order of operations
0. **Pre-deploy gates — automated.** Two workflows, both blocking, both on `appdb-devops-general`.
   `appdb-data-api-lint.yml` holds the credential-free checks (config assertions, the version-pin gate,
   `helm lint`, chart render tests, actionlint) so they report as their own status check and fail fast.
   `appdb-data-api.yml` does what needs the dev VPC: the live `dab validate`, `docker build`, a
   server-side dry-run, and the deploy.

   Run the same checks locally:

   ```bash
   cd appdb-data-api
   # RBAC — same argument list as the lint workflow; the role is pinned per config by filename
   ci/gate-rbac.sh dab-config.json config/dab-config.id.json config/dab-config.dev.json \
     dab-config.dev-all.json config/dev-all/*.json
   ci/gate-dev-all-tree.sh                                                              # dev-all config-tree invariant
   ci/gate-dml-tools.sh dab-config.json config/dab-config.dev.json                      # MCP dml-tools
   ci/gate-version.sh                                                                   # DAB pin agrees everywhere
   ci/tests/run-gate-tests.sh     # proves the gates fail on their breakages (GATE_RBAC_CLI=auto adds the CLI check)
   ci/tests/run-chart-tests.sh    # helm lint + closed-defaults + rendered-output assertions
   ```

   The live-DB gate validates the base against **both** hosts it serves, so it needs VPN/bastion
   access to `192.0.2.22:1433` (messaging) and `192.0.2.28:1433` (voice). The `dab` CLI comes
   from the DAB image, so the validator is the same build as the runtime — no .NET SDK.

   `ci/validate-base.sh` is exactly what CI runs: it derives the config's `CONN_*` keys, pulls them
   from the named secret, and passes them to `dab validate` by name (no value on a command line).

   ```bash
   export DAB_IMAGE=mcr.microsoft.com/azure-databases/data-api-builder:2.0.9
   export AWS_REGION=ap-southeast-1

   # the dev-all base — 11 sources across both hosts, one secret
   ci/validate-base.sh appdb-data-api/dev/connstrings dab-config.dev-all.json
   # the curated dev config: its 6 SPs are checked nowhere else (dev-all has no stored procedures).
   # All 6 live in AppDb_dev, hence the alias.
   ci/validate-base.sh appdb-data-api/dev/connstrings config/dab-config.dev.json \
     --alias CONN_DEV=CONN_DEV_AppDb_MSG_DEV

   docker build -t appdb-data-api:test .
   ```

   > On Apple Silicon, running the DAB image needs Rancher Desktop with **Rosetta disabled** (VZ is fine).
   > With Rosetta on it fails with `rosetta error: unhandled auxillary vector type 29`. `docker build`,
   > `docker export`, and every non-container check work either way.

1. **DBA — run `01-create-login-and-grants.sql`** (PART A on every node with a matching SID; PART B on the
   global-config primary; PART C on each region's `AppDb_Data` primary). Apply the ID/UK routing fix in the same file.
2. **Create the secrets** in AWS Secrets Manager — one full connection string per key (see `external-secret.yaml`
   header), e.g. `appdb-data-api/CONN_ID_MSGDATA`, plus `AUTH_JWT_ISSUER` / `AUTH_JWT_AUDIENCE`.
3. **Build the image** from `../Dockerfile` (bakes only the config), push to your registry, set that tag in `deployment.yaml`.
4. `kubectl apply -f external-secret.yaml` then `-f deployment.yaml` (namespace `appdb-data-api`).
5. Point AgentCore/ingress at the Service → `…/mcp`. Verify each role sees only its tools:
   `dab configure --show-effective-permissions`.

## Deploy per environment (dev / staging)

Dev and staging are **separate AWS accounts** with their own EKS cluster, registry, ESO/IRSA, and Secrets Manager.
Same image build recipe (`../Dockerfile`, DAB 2.x, config baked in); only the config selected at runtime and the
secret keys differ. DEV is the Helm chart in `deploy/chart/` (values in `chart/values/dev.yaml`); staging is
still the hand-maintained `deploy/staging/` until its pipeline lands.

### DEV — `ap-southeast-1` · ONE release serving BOTH SQL hosts

One DAB, read-only across every DB on both dev hosts, under **one audience** with the messaging /
voice boundary carried by **RBAC per entity** rather than by two deployments (ADR-0005). **Auth
(role from JWT):** the VPC-attached adapter injects `X-MS-API-ROLE` from the OIDC bearer JWT; DAB enforces
the per-entity role; no client header — see `docs/identity-and-audit.md`.

| Item | Value |
|---|---|
| SQL hosts | `DEV-NODE1` `192.0.2.22:1433` (9 msg DBs, `CONN_DEV_*`) **+** `DEV-VOICE-NODE1` `192.0.2.28:1433` (`AppDb_VOICE_dev`, `AppDb_Routing_dev`, `CONN_DEVVO_*`) |
| Base config | `dab-config.dev-all.json` — 11 `data-source-files`, 1131 entities |
| Values | `chart/values/dev.yaml` |
| Helm release / ServiceAccount | `appdb-data-api` |
| Audience | `appdb-data-api` |
| Roles | `appdb-data-api-msg-reader` (messaging entities) · `appdb-data-api-voi-reader` (`vo_*` entities) |
| SM secret | `appdb-data-api/dev/connstrings` (all 11 `CONN_*` keys) |
| AWS account | `111111111111` |
| EKS cluster | `dev-eks-cluster` |
| VPC | `vpc-0dev00000000000` / `subnet-0dev0private1` |
| ESO IRSA role | `…:role/dev-msg-apse1-eks-appdb-data-api-eso` |
| Istio gateway / host | `istio-system/private-gateway` · `appdb-data-api-msg.appdb.dev` |
| GH environment | `dev-msg` |
| CI roles (repo vars) | `AWS_ASSUME_ROLE_MSG_DEV{,_GATE}` |

> The ingress host keeps its `-msg` name. It predates the split and the record survives the voi
> decommission (`example/appdb-terragrunt-msg#445` removed only the `-voi` alias), so renaming it
> would cost a new Route53 record in the msg-prod zone to buy nothing.

> **The role is the access boundary, not the deployment.** A `msg-reader` token reading a `vo_*`
> entity gets a `PermissionDenied`, and vice-versa; `anonymous`/`authenticated` are granted nothing,
> so an unrecognised role resolves to no entity access at all. `ci/gate-rbac.sh` pins the role per
> config file, and `ci/gate-dev-all-tree.sh` pins the file-name ↔ host correspondence that pinning
> keys off.

Dev uses the **IP** + `TrustServerCertificate=True` (dev certs untrusted / hostnames may not resolve
from the pod; `Encrypt=True` still encrypts, just doesn't verify). Staging/prod keep `False`.

1. **DBA — grants.** Run `02-dev-create-login-and-grants.sql` on **both** hosts (strict read-only,
   every user DB per host); one `dev_svc_dataapi` login per host.
2. **Generate configs + key list.** `tools/README.md` (two-host run) writes the base + the linked
   files and prints the `CONN_*` keys — `CONN_DEV_*` (messaging) and `CONN_DEVVO_*` (voice).
3. **One secret, all 11 keys** — the pod resolves both hosts, so both prefixes live here:
   ```bash
   aws secretsmanager create-secret --region ap-southeast-1 --name appdb-data-api/dev/connstrings \
     --secret-string '{"CONN_DEV_AppDb_MSG_DEV":"Server=192.0.2.22,1433;Database=AppDb_dev;User ID=dev_svc_dataapi;Password=<sg>;ApplicationIntent=ReadOnly;Encrypt=True;TrustServerCertificate=True;Application Name=appdb-data-api", "CONN_DEV_<DB>":"…", "CONN_DEVVO_AppDb_VOICE_DEV":"Server=192.0.2.28,1433;Database=AppDb_VOICE_dev;User ID=dev_svc_dataapi;Password=<vo>;…", "CONN_DEVVO_AppDb_Routing_DEV":"…"}'
   ```
   `ExternalSecret` uses `dataFrom[].extract`, so it picks up every property — adding a DB needs no
   template change, only the new key.
4. **Security groups / routing.** Pod SG → `192.0.2.22/32` **and** `192.0.2.28/32` on TCP 1433.
   The voice host is in another account's VPC (`192.0.2.27/16`), reached over the transit gateway;
   `vo-st-int-mssql-sg` (`sg-0stg000000000`) already admits `172.16.0.0/12`, which covers the
   msg dev VPC — so a connection refused there is routing, not a missing SG rule. That SG is
   untagged and in no terraform state; leave it alone.
5. **Deploy.** CI does it **on merge to `master`** — a PR is gated but never deployed. To deploy a
   branch (e.g. to prove a PR against the real cluster), dispatch the workflow against that ref:
   ```bash
   gh workflow run appdb-data-api --ref <branch>                     # build HEAD of <branch>, deploy it
   gh workflow run appdb-data-api --ref <branch> -f image_tag=<sha>  # redeploy an existing tag
   ```
   By hand, bypassing CI entirely:
   ```bash
   helm upgrade --install appdb-data-api deploy/chart -n appdb-data-api \
     --values deploy/chart/values/dev.yaml --set image.tag=<sha> --atomic --timeout 8m
   ```
6. Roll back with `helm -n appdb-data-api rollback appdb-data-api <revision>`, or redeploy a known-good
   image: `gh workflow run appdb-data-api --ref master -f image_tag=<sha>`.
   **Never roll back by re-pushing a tag.**

### STAGING — acct 222222222222 · `ap-southeast-1` · 2-node AG
| Item | Value |
|---|---|
| SQL target | listener `ag-staging-listener`, nodes `192.0.2.29` / `192.0.2.29` (DBs `AppCatalog` + `AppDb_Data`) |
| Config | base `dab-config.json` + `DAB_ENVIRONMENT=Staging` → `dab-config.Staging.json` (EntraID provider, ordinary OIDC bearer JWT); SMS proc = `…BQ_v2` |
| Auth env | `AUTH_JWT_ISSUER` = the staging OIDC provider's issuer URL (⛳ still a placeholder — fill in once a staging issuer is registered) · `AUTH_JWT_AUDIENCE` = `appdb-data-api-msg` (plain env in `staging/deployment.yaml`) |
| Secrets | `appdb-data-api/staging/CONN_GLOBAL_CONFIG` + `appdb-data-api/staging/CONN_ID_MSGDATA` |
| VPC / subnets | `vpc-0stg00000000000` / `subnet-0stg0private1` + `subnet-0stg0private2` (private-1/2) |

> Staging AG has **no** `read_only_routing_url`, so `ApplicationIntent=ReadOnly` reads land on the **primary**. Add
> `MultiSubnetFailover=True` (done in the secret template) so connects follow the listener across the two subnets.

1. DBA: run `03-staging-create-login-and-grants.sql` (login both nodes, matching SID; grants in `AppCatalog` +
   `AppDb_Data` on the current primary).
2. Create both secrets (see `staging/external-secret.yaml` header).
3. SG: allow the pod SG → `192.0.2.29` and `192.0.2.29` TCP 1433.
4. Build/push image to the staging registry, set the tag in `staging/deployment.yaml`.
5. `kubectl apply -f staging/external-secret.yaml -f staging/deployment.yaml` (ns `appdb-data-api`).

> **Runtime = EKS assumed.** If dev/staging run **ECS Fargate** instead of EKS, translate: `deployment.yaml` → a task
> definition (same image, same CLI `command` with `-c`), `external-secret.yaml` → task-def `secrets[]` pulling the same
> Secrets Manager ARNs (drop ESO), and the Service → an ALB target group. The config, secret keys, and SG rules are
> identical either way.

## Environments & authentication
Config + auth are environment-specific (verified proc layout, 2026-07-22):

| Env | Config used | Provider | How a caller authenticates |
|-----|-------------|----------|----------------------------|
| Local | `dab-config.json` + `DAB_ENVIRONMENT=Local` (`dab-config.Local.json`) | `Simulator` | header `X-MS-API-ROLE: appdb-data-api-msg-reader` (offline only, no token) |
| Dev | `config/dab-config.dev.json` (CLI `start -c`) — standalone, single `AppDb_dev`, `_v5` SMS proc | `EntraID` | DEV-environment OIDC bearer token; role from `roles` claim |
| Staging | `dab-config.json` + `DAB_ENVIRONMENT=Staging` (`dab-config.Staging.json`) — prod-shaped (`AppCatalog` + `AppDb_Data`) | `EntraID` | STG-environment OIDC bearer token; role from `roles` claim |
| Prod | `dab-config.json` (no `DAB_ENVIRONMENT`) | `EntraID` | PRD-environment OIDC bearer token (`AUTH_JWT_*`) |

> **OIDC bearer auth (dev/staging/prod).** All three validate an ordinary OIDC bearer JWT via DAB's `EntraID`
> provider — despite the name, this is generic OIDC bearer validation, not tied to any specific vendor. Any
> compliant OIDC provider works: Entra ID, Okta, Auth0, Keycloak, Cognito, or an in-house issuer. The provider must:
> (1) serve `{issuer}/.well-known/openid-configuration` (DAB discovers the JWKS from it); (2) issue tokens whose
> `aud` matches `AUTH_JWT_AUDIENCE` (RS256, `kid: appdb-oidc-1`); (3) emit a `roles` claim containing the exact role
> string DAB is configured for — initially the single role `appdb-data-api-msg-reader` (scoped ops/eng roles come
> later for prod) — DAB matches role strings **exactly**, it does not normalise case or trim. Confirm the provider's
> registered audience emits the role string this config expects (some provider consoles show a shorter alias in a
> group/claim-mapping UI — verify the literal string, not the display label). Only **Local** still uses `Simulator`
> (header `X-MS-API-ROLE`, no token) for offline work.

**Dev (broad read-only, two hosts):** the dev API exposes the **readable data surface** (tables with a
PK + views; SPs stay curated, not broadly exposed — broad SP `execute` isn't read-only) across every DB on
`DEV-NODE1` (192.0.2.22, messaging) and `DEV-VOICE-NODE1` (192.0.2.28, voice) via the generated
`dab-config.dev-all.json` (base at image root) + `config/dev-all/*.json` — **strict read-only** (the login
holds `db_datareader` + `db_denydatawriter`; the config's `dml-tools` disable create/update/delete). Dev data
is **unmasked — test data only.** Deploy with `command: ["dotnet","/App/Microsoft.DataApiBuilder.dll","start","-c","/App/dab-config.dev-all.json"]`
— the image ENTRYPOINT is the service and ignores a bare config flag (OIDC bearer JWT; callers present a
DEV-environment bearer token). The `CONN_DEV_*` / `CONN_DEVVO_*` keys come from the one JSON Secrets Manager secret
`appdb-data-api/dev/connstrings` (ESO `dataFrom[].extract`); `AUTH_JWT_ISSUER`/`AUTH_JWT_AUDIENCE` are plain
env (public OIDC values, not secrets). The earlier curated `config/dab-config.dev.json` (6 procs) is superseded for dev.

**Staging (prod-shaped `ag-staging-listener`):** `AppCatalog` (global) + `AppDb_Data` (region), **v2** procs —
identical to prod, so staging **reuses the base `dab-config.json` + `config/dab-config.id.json`**; just point
`CONN_GLOBAL_CONFIG` / `CONN_ID_MSGDATA` at staging and set `DAB_ENVIRONMENT=Staging` (`dab-config.Staging.json`
overlays the `EntraID`/OIDC-bearer-JWT provider onto the base config).

**Simulator fallback (Local only):** `dab-config.Local.json` keeps the `Simulator` provider so the service can be
run offline with no token (header `X-MS-API-ROLE`). Do **not** reintroduce Simulator in dev/staging/prod — they
validate a real OIDC bearer token. And **never grant `anonymous` in the base config** (it would open prod).

**Local auth test** (the "test it locally" item):
```bash
DAB_ENVIRONMENT=Local dab start
dab configure --show-effective-permissions        # confirm appdb-data-api-msg-reader resolves
# then call /mcp with header:  X-MS-API-ROLE: appdb-data-api-msg-reader   → only that role's tools should appear
```

**Prod (your OIDC provider):** `dab-config.json` with no `DAB_ENVIRONMENT` (base `EntraID`). Set `AUTH_JWT_ISSUER`
(the provider's OIDC issuer URL) + `AUTH_JWT_AUDIENCE` (this API's registered audience) from Secrets Manager. DAB
maps the token's `roles` claim to `permissions[].role` — confirm which claim your provider emits it under (the
standard `roles` claim, per the requirements above). Rationale: `../docs/identity-and-audit.md`.

## Security checklist (do not skip)
- **Encrypt etcd at rest** (EKS: KMS envelope encryption for Secrets) — a k8s Secret is base64, not encrypted, without it.
- **RBAC the Secret** — only the workload's ServiceAccount and the deploy pipeline may read `appdb-data-api-conn`.
- **Rotation** — rotate the SQL password in Secrets Manager on a schedule; DAB reads env at start, so roll the
  Deployment (or use a reloader) to pick up a new value.
- **`TrustServerCertificate=False`** for staging/prod (validates the server cert, blocks MITM). If a node uses a
  self-signed cert, add that CA to the image trust store rather than flipping to `True`. **DEV is the one
  exception** — see the DEV steps above for why, and keep it dev-only.
- The login can only `EXECUTE` the ~6 curated procs on a readable secondary — so even a leaked credential can neither
  write nor read raw tables. That least privilege is the last line of defense; keep it that way.
