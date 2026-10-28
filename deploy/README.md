# Deploy — appdb-data-api

Production deployment artifacts. **No secret ever lives in this folder, in git, or in the image** — the
connection strings (which contain the SQL password) and the inbound JWT settings (issuer/audience for your OIDC provider) are pulled from
**AWS Secrets Manager** at runtime and injected as environment variables.

## Files
| File | Purpose |
|---|---|
| `01-create-login-and-grants.sql` | **PROD**: least-privilege `svc_dataapi` login (every replica, matching SID) + `role_svc_dataapi` + EXECUTE grants (once per AG-database primary). Includes the region2/region3 read-only-routing fix. |
| `02-dev-create-login-and-grants.sql` | **DEV** (`DEV-NODE1`, single node): login `dev_svc_dataapi`, **strict read-only across every online user database** on the instance (`db_datareader` + `db_denydatawriter`, plus `GRANT SELECT` / `EXECUTE` / `VIEW DEFINITION`; no write role, no server role). Supersedes the earlier 6-proc grant. Re-runnable; no SID matching. |
| `03-staging-create-login-and-grants.sql` | **STAGING** (`ag-staging1`, 2-node AG): login on both nodes (matching SID) + grants in `AppCatalog` (global) and `AppDb_Data` (SMS, `core.MessageLog_SearchByFilter_v2`) on the primary. |
| `02-resource-governor-dataapi.sql` | **Every replica the API reads** (Resource Governor is per instance and not replicated by the AG): pool `rp_dataapi` (CPU cap 10%, memory 5%, `MAX_IOPS_PER_VOLUME` sized from the host) + workload group `rg_dataapi` (`MAX_DOP 1`, 4 concurrent requests, 30 s CPU, `LOW` importance) + a classifier branch for `svc_dataapi`, in a new classifier or spliced into the one already attached. Splicing first saves the attached classifier's body to `master.dbo.DataApi_RgClassifierBackup` (one row per change); the PART F rollback restores the body from that table and then drops it. Online, re-runnable. |
| `03-enable-tf2422.ps1` | **Every replica** (Windows, dbatools): trace flag 2422, so `REQUEST_MAX_CPU_TIME_SEC` aborts a request instead of only raising an event. `DBCC TRACEON` now and `-T2422` appended to the startup parameters, no restart; it backs up every node's startup flags first and fails if one was lost. |
| `external-secret.yaml` | **PROD** External Secrets Operator → pulls `CONN_*` / `AUTH_*` from AWS Secrets Manager into a k8s Secret. |
| `deployment.yaml` | **PROD** stateless Deployment + Service. **SUPERSEDED-PENDING — do not apply as-is** (see the banner in the file): it references the raw base image with no config baked in and hard-codes `DAB_ENVIRONMENT=Staging`. Becomes `chart/values/prod.yaml` when the prod pipeline lands. |
| `chart/` | **The deployable.** One Helm chart for every environment; DEV is `chart/values/dev.yaml`. Supersedes the hand-written `dev/` manifests. Installed by a deploy pipeline (see `docs/ci-cd-dev.md` §6) or by hand with `helm upgrade --install` (DEV step 5 below). |
| `dev/deployment.yaml` + `dev/external-secret.yaml` | The pre-chart **DEV** manifests: standalone `config/dab-config.dev.json`, a single `CONN_DEV` key, an `external-secrets.io/v1beta1` `ExternalSecret` on a `ClusterSecretStore`, and `runAsNonRoot` with no `runAsUser`. Superseded by `chart/`. |
| `staging/deployment.yaml` + `staging/external-secret.yaml` | **STAGING (Kubernetes)** (acct 222222222222): base config + `DAB_ENVIRONMENT=Staging`, secrets `CONN_GLOBAL_CONFIG` + `CONN_REGION2_MSGDATA`. `deployment.yaml` is **SUPERSEDED-PENDING** — see its banner. |
| `ec2/` (`docker-compose.yml`, `appdb-data-api.service`, `README.md`) | **EC2 (Docker)** — a fast path: run the container on an EC2 box next to the SQL-MCP EC2 for dev/PoC. Use this first; k8s (`chart/`, `staging/`) later. See `ec2/README.md`. |

## Order of operations
0. **Pre-deploy gates.** The credential-free gates run in this repository's CI
   (`.github/workflows/ci.yml`, on every push and pull request to `main`): the config gates, the gate
   self-tests, the chart tests (`helm lint` + render assertions), the leak scan, the vendor tests and a
   stack smoke test — see the root `README.md`, "CI gates". What needs the dev network — the live
   `dab validate`, building the image that is deployed, a server-side dry-run, and the deploy itself —
   belongs to a deploy pipeline with that access (designed in `docs/ci-cd-dev.md` §6); its workflow is
   not part of this repository.

   Run the credential-free checks locally, from the repo root:

   ```bash
   ci/gate-protection.sh          # DEV-ALL-TREE, NO-WRITE-TOOLS, KEY-FIELDS, HEALTH-PROBE, DEV-ALL-PROTECTED,
                                  # CONN-KEYS, DML-TOOLS and RBAC (jq assertion only), as one command
   # RBAC with the Docker effective-permissions cross-check; the role is pinned per config by filename
   ci/gate-rbac.sh dab-config.json config/dab-config.region2.json config/dab-config.dev.json \
     dab-config.dev-all.json config/dev-all/*.json
   ci/gate-config-flag.sh         # no compose file or manifest passes --config-file
   ci/gate-version.sh             # DAB pin agrees everywhere
   ci/gate-vendor-drift.sh        # services/dba-mcp/ matches its pin
   ci/tests/run-gate-tests.sh     # proves the gates fail on their breakages (GATE_RBAC_CLI=auto adds the CLI check)
   ci/tests/run-chart-tests.sh    # helm lint + closed-defaults + rendered-output assertions
   ```

   The live-DB gate validates the base against **both** hosts it serves, so it needs VPN/bastion
   access to `192.0.2.22:1433` (messaging) and `192.0.2.28:1433` (voice). The `dab` CLI comes
   from the DAB image, so the validator is the same build as the runtime — no .NET SDK.

   `ci/validate-base.sh` is that live gate (Gate C): it derives the config's `CONN_*` keys, pulls them
   from the named secret, and passes them to `dab validate` by name (no value on a command line). It
   needs AWS credentials for the secret's account, so the repository's CI does not run it.

   ```bash
   export DAB_IMAGE=mcr.microsoft.com/azure-databases/data-api-builder:2.0.9
   export AWS_REGION=ap-southeast-1

   # the dev-all base — every source it lists, across both hosts, one secret
   ci/validate-base.sh appdb-data-api/dev/connstrings dab-config.dev-all.json
   # the curated dev config: its 6 SPs are checked nowhere else (the dev-all tree does not include them).
   # All 6 live in AppDb_dev, hence the alias.
   ci/validate-base.sh appdb-data-api/dev/connstrings config/dab-config.dev.json \
     --alias CONN_DEV=CONN_DEV_AppDb_MSG_DEV

   docker build -t appdb-data-api:test .
   ```

   > On Apple Silicon, running the DAB image needs Rancher Desktop with **Rosetta disabled** (VZ is fine).
   > With Rosetta on it fails with `rosetta error: unhandled auxillary vector type 29`. `docker build`,
   > `docker export`, and every non-container check work either way.

1. **DBA — run `01-create-login-and-grants.sql`** (PART A on every node with a matching SID; PART B on the
   global-config primary; PART C on each region's `AppDb_Data` primary). Apply the region2/region3 routing fix in the same file.
2. **Create the secrets** in AWS Secrets Manager — one full connection string per key (see `external-secret.yaml`
   header), e.g. `appdb-data-api/CONN_REGION2_MSGDATA`, plus `AUTH_JWT_ISSUER` / `AUTH_JWT_AUDIENCE`.
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
voice boundary carried by **RBAC per entity** rather than by two deployments. **Auth
(role from JWT):** the VPC-attached adapter injects `X-MS-API-ROLE` from the OIDC bearer JWT; DAB enforces
the per-entity role; no client header — see `docs/identity-and-audit.md`.

| Item | Value |
|---|---|
| SQL hosts | `DEV-NODE1` `192.0.2.22:1433` (9 msg DBs, `CONN_DEV_*`) **+** `DEV-VOICE-NODE1` `192.0.2.28:1433` (`AppDb_VOICE_dev`, `AppDb_Routing_dev`, `CONN_DEVVO_*`) |
| Base config | `dab-config.dev-all.json` + its `config/dev-all/*.json` children (this repository carries a two-child example of the tree — see `docs/dev-all-status.md`) |
| Values | `chart/values/dev.yaml` |
| Helm release / ServiceAccount | `appdb-data-api` |
| Audience | `appdb-data-api` |
| Roles | `appdb-data-api-msg-reader` (messaging entities) · `appdb-data-api-voi-reader` (entities in `config/dev-all/*.vo.*.json`) |
| SM secret | `appdb-data-api/dev/connstrings` (every `CONN_DEV_*` / `CONN_DEVVO_*` key the tree needs; `ci/gate-conn-keys.sh` prints them) |
| AWS account | `111111111111` |
| EKS cluster | `dev-eks-cluster` |
| VPC | `vpc-0dev00000000000` / `subnet-0dev0private1` |
| ESO IRSA role | `…:role/dev-eks-appdb-data-api-eso` |
| Istio gateway / host | `istio-system/private-gateway` · `appdb-data-api-msg.appdb.dev` |
| GH environment | `dev` |
| CI roles (repo vars) | `AWS_ASSUME_ROLE_MSG_DEV{,_GATE}` |

> The ingress host keeps its `-msg` name. It predates the split and the record survives the voi
> decommission (only the `-voi` alias was removed), so renaming it
> would cost a new Route53 record to buy nothing.

> **The role is the access boundary, not the deployment.** A `msg-reader` token reading a voice
> entity gets a `PermissionDenied`, and vice-versa; `anonymous`/`authenticated` are granted nothing,
> so an unrecognised role resolves to no entity access at all. `ci/gate-rbac.sh` pins the role per
> config file, and `ci/gate-dev-all-tree.sh` pins the file-name ↔ host correspondence that pinning
> keys off.

Dev uses the **IP** + `TrustServerCertificate=True` (dev certs untrusted / hostnames may not resolve
from the pod; `Encrypt=True` still encrypts, just doesn't verify). Staging/prod keep `False`.

1. **DBA — grants.** Run `02-dev-create-login-and-grants.sql` on **both** hosts (strict read-only,
   every user DB per host); one `dev_svc_dataapi` login per host.
2. **Configs + key list.** Add or update the child configs under `config/dev-all/` and list each in
   the base (see `docs/dev-all-status.md`, "Adding a database"); `ci/gate-conn-keys.sh` then prints
   the `CONN_*` keys the tree needs — `CONN_DEV_*` (messaging) and `CONN_DEVVO_*` (voice).
3. **One secret, every key** — the pod resolves both hosts, so both prefixes live here:
   ```bash
   aws secretsmanager create-secret --region ap-southeast-1 --name appdb-data-api/dev/connstrings \
     --secret-string '{"CONN_DEV_AppDb_MSG_DEV":"Server=192.0.2.22,1433;Database=AppDb_dev;User ID=dev_svc_dataapi;Password=<sg>;ApplicationIntent=ReadOnly;Encrypt=True;TrustServerCertificate=True;Application Name=appdb-data-api", "CONN_DEV_<DB>":"…", "CONN_DEVVO_AppDb_VOICE_DEV":"Server=192.0.2.28,1433;Database=AppDb_VOICE_dev;User ID=dev_svc_dataapi;Password=<vo>;…", "CONN_DEVVO_AppDb_Routing_DEV":"…"}'
   ```
   `ExternalSecret` uses `dataFrom[].extract`, so it picks up every property — adding a DB needs no
   template change, only the new key.
4. **Security groups / routing.** Pod SG → `192.0.2.22/32` **and** `192.0.2.28/32` on TCP 1433.
   The voice host is in another account's VPC, reached over the transit gateway; its security
   group already admits the msg dev VPC's range, so a connection refused there is routing, not a
   missing SG rule.
5. **Deploy.** With the deploy pipeline designed in `docs/ci-cd-dev.md` §6 (its workflow is not part
   of this repository), a merge deploys and a PR is gated but never deployed; a branch is deployed by
   dispatching that workflow against the ref:
   ```bash
   gh workflow run appdb-data-api --ref <branch>                     # build HEAD of <branch>, deploy it
   gh workflow run appdb-data-api --ref <branch> -f image_tag=<sha>  # redeploy an existing tag
   ```
   By hand, with no pipeline:
   ```bash
   helm upgrade --install appdb-data-api deploy/chart -n appdb-data-api \
     --values deploy/chart/values/dev.yaml --set image.tag=<sha> --atomic --timeout 8m
   ```
6. Roll back with `helm -n appdb-data-api rollback appdb-data-api <revision>`, or, with the deploy
   pipeline, redeploy a known-good image: `gh workflow run appdb-data-api --ref master -f image_tag=<sha>`.
   **Never roll back by re-pushing a tag.**

### STAGING — acct 222222222222 · `ap-southeast-1` · 2-node AG
| Item | Value |
|---|---|
| SQL target | listener `ag-staging-listener`, nodes `192.0.2.29` / `192.0.2.30` (DBs `AppCatalog` + `AppDb_Data`) |
| Config | base `dab-config.json` + `DAB_ENVIRONMENT=Staging` → `dab-config.Staging.json` (EntraID provider, ordinary OIDC bearer JWT); SMS proc = `core.MessageLog_SearchByFilter_v2` |
| Auth env | `AUTH_JWT_ISSUER` = the staging OIDC provider's issuer URL (⛳ still a placeholder — fill in once a staging issuer is registered) · `AUTH_JWT_AUDIENCE` = `appdb-data-api-msg` (plain env in `staging/deployment.yaml`) |
| Secrets | `appdb-data-api/staging/CONN_GLOBAL_CONFIG` + `appdb-data-api/staging/CONN_REGION2_MSGDATA` |
| VPC / subnets | `vpc-0stg00000000000` / `subnet-0stg0private1` + `subnet-0stg0private2` (private-1/2) |

> Staging AG has **no** `read_only_routing_url`, so `ApplicationIntent=ReadOnly` reads land on the **primary**. Add
> `MultiSubnetFailover=True` (done in the secret template) so connects follow the listener across the two subnets.

1. DBA: run `03-staging-create-login-and-grants.sql` (login both nodes, matching SID; grants in `AppCatalog` +
   `AppDb_Data` on the current primary).
2. Create both secrets (see `staging/external-secret.yaml` header).
3. SG: allow the pod SG → `192.0.2.29` and `192.0.2.30` TCP 1433.
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
| Dev | chart: `dab-config.dev-all.json` (CLI `start -c`, image root) — broad read-only, both dev hosts. EC2 path: `config/dab-config.dev.json` (CLI `start -c`) — standalone, single `AppDb_dev`, `_v5` SMS proc | `EntraID` | DEV-environment OIDC bearer token; role from `roles` claim |
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
`dab-config.dev-all.json` (base at image root) + `config/dev-all/*.json` (the example tree in this repository
serves two reference-data stored procedures instead; see `docs/dev-all-status.md`) — **strict read-only** (the login
holds `db_datareader` + `db_denydatawriter`; the config's `dml-tools` disable create/update/delete). Dev data
is **unmasked — test data only.** Deploy with `command: ["dotnet","/App/Microsoft.DataApiBuilder.dll","start","-c","/App/dab-config.dev-all.json"]`
— the image ENTRYPOINT is the service and ignores a bare config flag (OIDC bearer JWT; callers present a
DEV-environment bearer token). The `CONN_DEV_*` / `CONN_DEVVO_*` keys come from the one JSON Secrets Manager secret
`appdb-data-api/dev/connstrings` (ESO `dataFrom[].extract`); `AUTH_JWT_ISSUER`/`AUTH_JWT_AUDIENCE` are plain
env (public OIDC values, not secrets). The curated `config/dab-config.dev.json` (6 procs) is no longer what the dev
chart serves; it stays the curated-SP reference, the EC2 path's config, and is live-validated on its own (step 0).

**Staging (prod-shaped `ag-staging-listener`):** `AppCatalog` (global) + `AppDb_Data` (region), **v2** procs —
identical to prod, so staging **reuses the base `dab-config.json` + `config/dab-config.region2.json`**; just point
`CONN_GLOBAL_CONFIG` / `CONN_REGION2_MSGDATA` at staging and set `DAB_ENVIRONMENT=Staging` (`dab-config.Staging.json`
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
- **Fence the login with Resource Governor** (`02-resource-governor-dataapi.sql`, then `03-enable-tf2422.ps1`) on
  every replica it can reach. Least privilege bounds *what* the login reads, not *how much* of the instance one
  runaway read can take; unclassified, it runs in `default` with unlimited parallelism and concurrency.
- **If you ever add table or view entities**, hide columns with `fields.exclude` in the read action (Gate
  DEV-ALL-PROTECTED checks those lists) or with a projection view — **never with a column `DENY`** or a
  column-only `GRANT`. DAB 2.0.9 reads every entity's columns at startup; a column `DENY` fails that read with
  error 230 and the whole engine exits on its next start. Declare `source.key-fields` too (Gate KEY-FIELDS).
- **Read-only grants bound the grants, not the host.** A linked server whose default mapping covers every login,
  pointing at a login with more rights (sysadmin, on another host), lets any login — this one included — run
  statements with those rights. Replace default linked-server mappings with explicit, least-privileged ones on
  every host the API's logins can reach.
