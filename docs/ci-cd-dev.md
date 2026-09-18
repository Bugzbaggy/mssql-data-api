---
status: implemented
---

# CI/CD spec — appdb-data-api → DEV EKS

**Status:** Implemented · **Ticket:** [DEVOPS-3512](https://example.atlassian.net/browse/DEVOPS-3512)
· **Reference:** [AppDb Data API Builder](https://example.atlassian.net/wiki/spaces/SMS/pages/3133014061/AppDb+Data+API+Builder)

Registry is **Docker Hub** (`appdbsg`) and the connection-string secret comes from **AWS Secrets Manager
via External Secrets Operator** — matching the `deploy/dev/external-secret.yaml` this change replaces, and reusing
the pipeline's GitHub-OIDC→AWS identity, so **no new long-lived credential is introduced**. HashiCorp Vault
was evaluated and **not** adopted: it would put a static AppRole credential into GitHub secrets purely to
read one dev connection string. It's kept as an appendix in case the `shared-eks` platform standard turns out
to be Vault-via-ESO.

---

## 1. Scope

| Ticket AC | How this spec satisfies it |
|---|---|
| Deployment triggered from `master` | `on: push: branches: [master]`, path-filtered to `appdb-data-api/**` |
| Deploy to Kubernetes | `helm upgrade --install` against EKS `dev-eks-cluster` (`ap-southeast-1`, acct `111111111111`), namespace `appdb-data-api`, exposed through Istio |

**In scope:** DEV only, but the chart is authored so staging/prod are a values file, not a fork.
**Out of scope:** staging/prod pipelines, OIDC-provider registration, and the `0[123]-*-create-login-and-grants.sql`
DBA scripts (run once by a DBA, never by CI).

## 2. What gets built and deployed

There is no compiled application. The deployable is a **container image** built from
`appdb-data-api/Dockerfile`: Microsoft's `mcr.microsoft.com/azure-databases/data-api-builder:2.0.9` with
`dab-config*.json` + `config/` copied in. Everything else is runtime configuration.

> **2026-08-10 — base image repinned `2.4.29` → `2.0.9`.** `2.4.29` does not exist in MCR or on
> NuGet, so the image had never built; `2.0.9` is the newest published tag (same digest as
> `:latest`) and its bundled schema covers every feature these configs use. Must stay on 2.x.

```text
appdb-data-api/Dockerfile  ──build──▶  appdbsg/appdb-data-api:<sha>  ──push──▶  Docker Hub
                                                    │
deploy/chart + values/dev.yaml  ──helm upgrade──▶  EKS dev-eks-cluster  ns appdb-data-api
                                                    │
                          AWS Secrets Manager ──ESO──▶ Secret appdb-data-api-conn (11 CONN_* keys)
                                                    │
AgentCore ──▶ Istio Gateway ──VirtualService──▶ Service:80 ──▶ DAB:5000
                                                    │
                                             DAB ──read-only──▶ 192.0.2.22:1433 (messaging, 9 DBs)
                                                 └──read-only──▶ 192.0.2.28:1433 (voice, 2 DBs)
```

DEV runs the standalone config via the **CLI**, not the image's default entrypoint. Since 2026-08-13
that config is `dab-config.dev-all.json` at the **image root**, so its `data-source-files` resolve:

```yaml
command: ["dotnet", "/App/Microsoft.DataApiBuilder.dll", "start", "-c", "/App/dab-config.dev-all.json"]
```

> **2026-08-10 — `args: ["--config-file", …]` replaced by the `command:` above.** The image
> ENTRYPOINT is the *service*, which ignores every config flag and always loads
> `/App/dab-config.json`; only the CLI honours `-c`. As written, dev silently ran the **base prod
> config** — wrong databases, and the masked `_v2` SMS proc instead of dev's `_v5`.

### Running the DAB CLI

The CLI ships **inside the image**, so nothing installs the .NET SDK and the validator is always the
same build as the runtime. Three non-obvious facts, all verified on 2.0.9:

- Invoke it as **`dotnet /App/Microsoft.DataApiBuilder.dll`**. The native launcher
  `/App/Microsoft.DataApiBuilder` ships mode `-rw-rw-r--` — **no exec bit** — so using it as an
  entrypoint fails with "permission denied".
- The config flag is **`-c` / `--config`**, never `--config-file`.
- The image ENTRYPOINT is the *service* (`dotnet Azure.DataApiBuilder.Service.dll`), which ignores
  every config flag. Only the CLI's `start` honours `-c` — see §2 above.

```bash
dabx () { docker run --rm --entrypoint dotnet -v "$PWD:/work:ro" -w /work \
            mcr.microsoft.com/azure-databases/data-api-builder:2.0.9 \
            /App/Microsoft.DataApiBuilder.dll "$@"; }

dabx --version
dabx configure --show-effective-permissions -c config/dab-config.dev.json   # no DB needed
dabx validate -c config/dab-config.dev.json                                 # needs the live DB
```

## 3. Registry — Docker Hub

| Item | Value |
|---|---|
| Repository | `appdbsg/appdb-data-api` |
| Visibility | **Private** |
| Tags pushed | **short SHA** (7-char, immutable — what the Deployment references) and `dev` (moving convenience tag) |
| Never | `:latest` — `Dockerfile` header explicitly forbids floating tags |
| Pull secret | **`regcred`** in namespace `appdb-data-api`, provisioned by DevOps before CI is built |

Short SHA, not the full 40-char one — `${GITHUB_SHA::7}`, matching `git rev-parse --short`. It stays
unambiguous at this repo's size and keeps `helm history` and `kubectl get deploy -o jsonpath='{..image}'`
readable. The Deployment always pins it, so a rollback is a re-apply of a previous SHA, not a rebuild.
Enable Docker Hub's immutable-tags setting if the plan allows it.

## 4. Secrets — AWS Secrets Manager via External Secrets Operator

DAB reads its `@env('CONN_*')` references at process start. The pipeline never templates a connection string into a
manifest or an image — the pod gets it from AWS Secrets Manager via ESO. (The one exception is validation
Gate C, which needs a live DB connection; see §7.) **This carries over the intent of the `deploy/dev/external-secret.yaml` this change replaces, and reuses
the pipeline's GitHub-OIDC→AWS identity, so no new long-lived credential is introduced.** HashiCorp Vault was evaluated and rejected — see the appendix.

**Contract:** a k8s Secret named `appdb-data-api-conn` in namespace `appdb-data-api`, holding one key per
data source. `deployment.yaml`'s `envFrom: secretRef` stays exactly as it is today.

The secret lives in AWS Secrets Manager at **`appdb-data-api/dev/connstrings`** (acct `111111111111`,
`ap-southeast-1`). It is **one JSON secret whose properties are the env-var names** — 9 `CONN_DEV_*`
(messaging host) plus 2 `CONN_DEVVO_*` (voice host) — rather than 11 separate secrets. ESO with
`provider.aws` (SecretsManager) pulls **every** property into the k8s Secret via `dataFrom[].extract`,
using IRSA on the ServiceAccount named by the chart's `SecretStore`:

```yaml
apiVersion: external-secrets.io/v1        # the ONLY version shared-eks serves (v1beta1 is served=false)
kind: ExternalSecret
metadata: { name: appdb-data-api-conn, namespace: appdb-data-api }
spec:
  refreshInterval: 1h
  secretStoreRef: { name: appdb-data-api, kind: SecretStore }   # namespaced, created by the chart
  target: { name: appdb-data-api-conn, creationPolicy: Owner }
  dataFrom:                               # extract, not data[]: one JSON secret → all 11 keys
    - extract: { key: appdb-data-api/dev/connstrings }
```

> **Adding a DB is a secret edit, not a chart edit.** `dataFrom[].extract` copies whatever properties the
> JSON holds, so a new `CONN_DEV_*` key appears in the pod automatically once the generator emits a
> matching `@env()` reference. Gate VALIDATE (§6) derives its required-key list from the configs, so a
> key added to the config but not the secret fails the PR by name.

**Namespaced `SecretStore`, created by the chart.** `shared-eks` is shared with other teams, so a
cluster-scoped store — referenceable from any namespace — leaves IAM as the *only* boundary. We use a
namespaced `SecretStore` with its own IRSA role
(`arn:aws:iam::111111111111:role/dev-msg-apse1-eks-appdb-data-api-eso`), whose trust policy pins `sub` to
`system:serviceaccount:appdb-data-api:appdb-data-api`. That gives two independent boundaries: the
namespace **and** the IAM policy. Ownership splits — **DevOps installs ESO and owns the IAM role; the
chart owns the store**, so the store's config is versioned with the app that depends on it. The role's
policy needs both `secretsmanager:GetSecretValue` **and** `DescribeSecret`; with only the former the store
reports Ready but the ExternalSecret silently never syncs.

> **2026-08-10 — pins corrected.** `apiVersion` is `external-secrets.io/v1`: `v1beta1` is `served=false`
> on this cluster, so the manifest this section previously showed would have been **rejected by the API
> server**. There is also no `aws-secretsmanager` `ClusterSecretStore` on `shared-eks` at all.

Secrets Manager coordinates: acct **`111111111111`** · region **`ap-southeast-1`** · secret
**`appdb-data-api/dev/connstrings`**. The same secret serves Gate C on the runner (§7) — one secret, two
readers, **both authenticating with GitHub-OIDC→AWS** (the ESO controller role for the pod, the CI role for
the runner); no static credential anywhere.

Notes:

- **API version:** pin the `ExternalSecret` to whatever the freshly-installed ESO serves — `v1beta1` in the
  `external-secrets.io/v1` on `dev-eks-cluster` (verified 2026-08-10; `v1beta1` is
  `served=false`). Re-check with `kubectl get crd externalsecrets.external-secrets.io
  -o jsonpath='{.spec.versions[*].name}'` if ESO is reinstalled.
- The pod keeps `automountServiceAccountToken: false` — ESO uses the controller's SA (IRSA), not the
  workload's, so the workload needs no token.
- **IAM scoping is the backstop:** the ESO controller role's policy grants `secretsmanager:GetSecretValue`
  on exactly `appdb-data-api/dev/*` and nothing else. A mis-referenced store then fails, not leaks.
- `AUTH_JWT_ISSUER` / `AUTH_JWT_AUDIENCE` stay **plain env** in `deployment.yaml`. They are public OIDC
  values, not secrets.
- **Rotation:** DAB reads env only at start. Rotating the secret does not restart the pod — a
  `kubectl rollout restart` or a reloader is required. Already noted in `deploy/README.md`'s security
  checklist; carry it forward.

## 5. Validation gates

> **2026-08-10 — three schema defects fixed so Gate C can pass.** `dab validate` failed on the
> *unmodified* configs, independent of DB connectivity: `rest.methods` used `["GET"]` (the enum is
> lowercase), `authentication.provider` used `"EntraId"` (valid members are `EntraID` / `AzureAD`),
> and `telemetry` sat at the config root instead of `runtime.telemetry`, so OpenTelemetry was being
> **silently ignored**. It has been moved to the correct location and set `enabled: false` — no OTLP
> endpoint is configured anywhere yet, so enabling it in place would have activated export against
> an unset endpoint. All configs now validate clean against the schema bundled in the 2.0.9 image.


`deploy/README.md` §0 makes two commands blocking. Per Microsoft's CLI reference, **`dab validate` runs
five stages in order and cannot skip any** — it "accepts no flags other than `--config`". Stages 4
(*Database Connection*) and 5 (*Entity Metadata*) open a real TCP connection to SQL Server and check every
stored-procedure signature against the live database.

> **This is why the pipeline runs on a self-hosted runner with dev-VPC access.** A GitHub-hosted runner
> has no route to `192.0.2.22:1433` and would always fail at stage 4. With the self-hosted runner, the
> full five-stage validate runs **pre-merge** — a renamed or re-signatured stored procedure fails the PR
> instead of the rollout.

Gates run on **PR and `master`**. As implemented they are split across two workflows — the
credential-free ones (RBAC, `dml-tools`, VERSION, chart render) in `appdb-data-api-lint.yml`, the
live validate and build in `appdb-data-api.yml` — both on the self-hosted runner:

| Gate | Command | What it catches |
|---|---|---|
| **A — RBAC** | `dab configure --show-effective-permissions` **if it exists on 2.0.9**, else a `jq` assertion over `permissions[].role` | Assert `appdb-data-api-msg-reader` sees only its 6 entities and `anonymous`/`authenticated` see **none** (DAB 2.0 role inheritance can't widen access). |
| **B — `dml-tools`** | `jq` assertion on `runtime.mcp.dml-tools` in **both** `dab-config.json` **and** `config/dab-config.dev.json` | Exact 7-key set present in kebab-case; only `describe-entities` + `execute-entity` true, the other five `false`. **NOT applied to `dab-config.dev-all.json`** — that config is broad-read by design (`read-records` + `aggregate-records` true), so this assertion cannot fit it. Its write flags are covered by **NO-WRITE-TOOLS** below; only the read-profile split is deferred. |
| **NO-WRITE-TOOLS** (`ci/gate-no-write-tools.sh`) | `jq` assertion on **every** config, `dab-config.dev-all.json` included | `create-record`, `update-record` and `delete-record` each **present and `false`**. Presence matters: all 7 dml-tools default to `true`, so an omitted key is an enabled write tool that `dab validate` does not catch. |
| **C — full validate** | `dab validate -c dab-config.dev-all.json` | Schema, structure, permissions, **DB connectivity**, and **stored-procedure signatures** — across all 11 data sources on both dev hosts. Requires the 11 `CONN_*` keys (§7). |
| **D — build** | `docker build` (no push on PR) | A broken Dockerfile fails the PR. |
| **IMAGE-UID** (`ci/gate-image-uid.sh`) | `docker image inspect --format '{{.Config.User}}'` on the image Gate D just built, compared to `podSecurityContext.runAsUser` in `deploy/chart/values.yaml` | The Dockerfile says `USER $APP_UID`, resolved against the **base** image; the chart pins the number. A base bump that changes or drops `APP_UID` leaves both files looking correct while they disagree, and **nothing before the kubelet notices** — `helm template`, `dab validate` and `--dry-run=server` are all admission-time. An image with no `USER` is the §6a defect itself and fails here instead of eight minutes into `helm upgrade --atomic`. |
| **CONFIG-FLAG** (`ci/gate-config-flag.sh`) | grep every `docker-compose*.yml` and `*deployment.yaml` in the repo for `--config-file` in a `command:`/`args:`/`entrypoint:` | The flag is silently ignored (§2), so the container loads the base **prod** config — wrong databases and the masked `_v2` SMS proc — while looking healthy. The chart render tests only cover the chart; this catches the same foot-gun in the EC2 compose file and the standalone manifests. Prose naming the flag is allowed; only real uses fail. |
| **VERSION** (`ci/gate-version.sh`) | compare the DAB tag across `Dockerfile`, `docker-compose.yml`, `deploy/chart/Chart.yaml` (`appVersion`), `deploy/deployment.yaml`, the workflow `DAB_IMAGE`, `ci/gate-rbac.sh`'s default, **and every `data-api-builder:<tag>` in `deploy/README.md` + this file** | A bump that misses one pin skews the **validator from the deployed runtime** — the same class of drift the other gates exist to prevent. The doc commands count because they are runnable: `deploy/README.md` §0 tells you to paste them. The `Dockerfile` `FROM` tag is the source of truth; `CHANGELOG.md` is deliberately excluded, since it records the `2.4.29` → `2.0.9` correction and must keep the old tag. |
Implementation notes:

- **Gate A — verify the CLI surface first, then assert.** The doc previously assumed
  `dab configure --show-effective-permissions` exists; **confirm it on the 2.0.9 image
  (`dab configure --help`) before building the gate.** If the flag is absent, implement Gate A as a `jq`
  assertion over `permissions[].role` (env-agnostic, no CLI dependency) — that is what actually protects you.
  Either way it is an **assertion, not a printout**: parse and fail on mismatch. Pin the CLI to the image
  version by running the CLI **from the image** (see "Running the DAB CLI" below) —
  `dabx configure --help`. Confirmed present on 2.0.9.
  ```bash
  # Gate A (jq form — safe fallback): every entity permits ONLY appdb-data-api-msg-reader; no anon/auth.
  bad=$(jq -r '[ .entities[].permissions[].role ] | map(select(. != "appdb-data-api-msg-reader")) | unique | .[]' config/dab-config.dev.json)
  [ -n "$bad" ] && { echo "::error::Gate A FAIL — unexpected role(s): $bad"; exit 1; }
  ```
- **Gate B exists because of the typo trap** (wiki §2): DAB treats an *unknown* key as **enabled**, so
  `read_records` instead of `read-records` silently turns a write tool on. Assert the **exact 7-key set**
  exists (which catches the typo) and the values — not merely that no key is `true`. `dab validate` will not
  catch this. **Run it against both configs** — the typo trap also lives in the prod-bound base
  `dab-config.json`, and `jq` needs no DB so covering both is free:
  ```bash
  gate_b () {
    jq -e '.runtime.mcp["dml-tools"] as $d
      | ($d|keys|sort) == ["aggregate-records","create-record","delete-record","describe-entities","execute-entity","read-records","update-record"]
        and $d["describe-entities"]==true and $d["execute-entity"]==true
        and $d["read-records"]==false and $d["create-record"]==false and $d["update-record"]==false
        and $d["delete-record"]==false and $d["aggregate-records"]==false' "$1" >/dev/null \
      && echo "Gate B OK: $1" || { echo "::error::Gate B FAIL: $1"; exit 1; }
  }
  gate_b dab-config.json
  gate_b config/dab-config.dev.json
  ```
- **Gate C needs a credential on the runner** — see §7. It is a strict read-only dev login fetched
  from Secrets Manager via the CI's AWS OIDC role (no static credential), but it is still the one place CI
  touches a connection string.
- Gate C validates **only the resolved dev file**; per Microsoft, the validator "does not merge environment
  variants". The base config and the `Staging` overlay are not covered by Gate C — which is *why* Gate B
  (above) also runs against the base config.
- **Gate C validates what deploys.** It runs against `dab-config.dev-all.json`, the config the pod loads
  (`values/dev.yaml` → `configFile`), not the curated `config/dab-config.dev.json`. `data-source-files` are
  resolved relative to the base config, so the runner needs no `/App` layout — plain `-w /work` works,
  unlike the image, which needs the base at its root.
- **Closed (2026-08-14): `config/dab-config.dev.json` is live-validated again.** Gate C now also runs
  `dab validate -c config/dab-config.dev.json` with `CONN_DEV` aliased to the already-exported
  `CONN_DEV_AppDb_MSG_DEV` (all 6 curated procs live in `AppDb_dev`). This matters because
  `dab-config.dev-all.json` is generated with **no stored procedures**, so those 6 curated procs — the
  prod/staging contract — were otherwise checked **nowhere** in CI: a renamed proc would have surfaced at
  run time instead of on the PR. The file stays the curated-SP reference (and the local/EC2 path's config),
  still gated offline by RBAC, `dml-tools` and NO-WRITE-TOOLS. **Owner: `@example/appdb-database`.**
  *(Remaining deferred item: splitting Gate B into an invariant + per-file read profile so `dab-config.dev-all.json`'s broad-read profile can be asserted too — low priority; its write flags are already covered by NO-WRITE-TOOLS.)*

## 6. Pipeline

Two workflows, both on the **self-hosted runner** in the dev VPC:
`.github/workflows/appdb-data-api.yml` (`gate` + `deploy`, everything needing the VPC) and
`appdb-data-api-lint.yml` (the credential-free gates, as an independent fast status check).

```yaml
on:
  # Glob, not the exact filename: an edit to either workflow must trigger its own run.
  push:              { branches: [master], paths: ['appdb-data-api/**', '.github/workflows/appdb-data-api*.yml'] }
  pull_request:      { paths: [ same ] }
  workflow_dispatch: { inputs: { image_tag: { description: 'Existing SHA tag to redeploy' } } }

# item 6: concurrency is per JOB, not per workflow — the two jobs want opposite behaviour.
# A superseded PR still cancels its gate for fast feedback; deploys share one queue and are never
# cancelled MID-FLIGHT, since an interrupted `helm upgrade --atomic` leaves the release partially
# applied. `cancel-in-progress: false` protects only the RUNNING job — GitHub still drops a run
# left WAITING in the group when a newer one queues, so a rapid series of merges skips the
# intermediate deploys and the last one wins. Acceptable for one shared DEV release.
#   gate:   { group: appdb-data-api-gate-${{ github.ref }}, cancel-in-progress: true  }
#   deploy: { group: appdb-data-api-deploy,                 cancel-in-progress: false }
permissions: { id-token: write, contents: read }     # OIDC only — no long-lived credentials

jobs:
  gate:
    runs-on: appdb-devops-general
```

| Job | Condition | Steps |
|---|---|---|
| `gate` | always | Run the DAB CLI from the `2.0.9` image (no .NET SDK) → AWS OIDC → `ci/validate-base.sh` for the dev-all base (11 sources, both hosts) + the curated config → Gates A, B, C, D |
| `deploy` | **`if: github.event_name != 'pull_request'`** — push-to-master and `workflow_dispatch` only; `needs: gate` | Docker Hub login (org action, §7) → **build + push unless an `image_tag` was supplied** (`<sha>`; `dev` on master only) → AWS OIDC → `aws eks update-kubeconfig` → server-side dry-run → `helm upgrade --install` → health smoke |

**One gate, one build, one deploy.** The 2026-08-20 msg/voi split briefly made `deploy` a matrix over
two clusters in two AWS accounts, with `build` pulled out so both legs shipped the same image. That is
gone with the split (ADR-0005): one release on the shared cluster, so `build` folds back into `deploy` and the gate
assumes a single role against a single secret.

**A PR is gated, never deployed.** `deploy` carries `if: github.event_name != 'pull_request'`, so
merging to `master` is the automated path and everything else is an explicit manual act:

```bash
gh workflow run appdb-data-api --ref <branch>                     # build HEAD of <branch> and deploy it
gh workflow run appdb-data-api --ref <branch> -f image_tag=<sha>  # redeploy an existing tag, no rebuild
gh workflow run appdb-data-api --ref master  -f image_tag=<sha>   # roll DEV back to a known-good image
```

This is the load-bearing half of the identity split in §7. A `pull_request` run executes **the PR's
own copy of the workflow**, so any job that runs on that event is editable by whoever opened the PR;
keeping `deploy` off the PR path is what stops PR-authored code from reaching `DEPLOY_ROLE_ARN` and
the Docker Hub push token. Do not remove the guard to make a PR self-deploying — dispatch it instead,
which is attributable and needs the same repo access.

PRs still get real pre-merge proof: the `gate` job live-validates every config against the dev
databases and runs `docker build`, so a broken config or an unbuildable image fails the PR. What it
cannot prove is a defect that only a real rollout reaches (§6a, the 2026-08-14 case) — dispatch the
branch when a change is in that class.

The `dev` floating tag is pushed **only** from `master`, so it keeps meaning "latest merged" and a
dispatched branch build cannot move it. The chart always deploys the immutable short-SHA tag, never
`dev`. Every deploying event targets the one shared DEV release, so the last run wins.

```bash
# item 1: resolve the tag. The build+push guard is on the INPUT, not the event: a supplied
# image_tag means "redeploy that exact image" and must never be rebuilt under current code (which
# would corrupt an immutable tag), while a push or a blank dispatch means "deploy this commit"
# and therefore must build first.
#   Build and push:     if: github.event_name != 'workflow_dispatch' || github.event.inputs.image_tag == ''
#   Verify in registry: if: github.event_name == 'workflow_dispatch' && github.event.inputs.image_tag != ''
# The event is named explicitly rather than relying on `github.event.inputs` coercing to '' on a
# non-dispatch event — the failure mode is an 8-minute --atomic timeout, not a fast error.
#
# `deploy` never runs on pull_request, so GITHUB_SHA is always a real commit on a real branch and
# the job checks out the default ref with no `ref:` override. (While deploy DID run on PRs it had
# to check out github.event.pull_request.head.sha: GITHUB_SHA is then the synthetic merge commit,
# so building the default ref would push the merge tree under the head SHA's tag, and a re-run
# after master moved would rebuild a different tree under the SAME tag.) `gate` still runs on PRs
# and deliberately keeps the merge ref — its job is to test mergeability.
#
# The dispatch input reaches the shell through `env:`, never `${{ }}` — interpolating it directly is
# a command-injection sink for anyone who can dispatch the workflow. It is then regex-validated,
# which also enforces the immutable-tag rule (`dev` and `latest` are rejected). Use ${GITHUB_SHA::7}
# rather than `git rev-parse --short=7`, which extends past 7 characters when a short SHA is
# ambiguous and would fail the check.
#   env: { INPUT_TAG: "${{ github.event.inputs.image_tag }}" }
TAG="${INPUT_TAG:-${GITHUB_SHA:0:7}}"
[[ "$TAG" =~ ^[0-9a-f]{7}$ ]] || { echo "::error::image_tag must be a 7-char short SHA"; exit 1; }

# item 2: no --create-namespace — the ns is a DevOps prerequisite (§8) and the CI role is ns-scoped,
# so it cannot create a namespace anyway.
helm upgrade --install appdb-data-api deploy/chart \
  --namespace appdb-data-api \
  --values deploy/chart/values/dev.yaml \
  --set image.tag="$TAG" \
  --atomic --timeout 5m        # --atomic auto-rolls-back a failed release
```

`--atomic` replaces the separate `kubectl rollout status` step and reverts on failure. `helm template
… | kubectl apply --dry-run=server -f -` runs immediately before it in the **`deploy`** job, so a broken
template fails before anything is applied — not on the PR gate, which holds no cluster permissions (§7).

**Runner hygiene.** `appdb-devops-general` is **ephemeral** (one job per registration), so nothing leaks
from this pipeline's job to the next — which is what makes fetching the connection strings onto a shared,
general-purpose runner acceptable (§7). Two controls still matter, because ephemerality protects
*subsequent* jobs, not the job that holds the credential:

- Use `pull_request`, **never** `pull_request_target` — the latter runs PR-branch code with repo secrets.
- **Require approval for first-time / outside contributors.** A PR otherwise runs arbitrary code in the same
  job that has all 11 connection strings in its environment and a route to both dev SQL nodes. A fresh
  runner doesn't help there. Note the blast radius grew with the dev-all migration: one read-only login on
  one messaging DB became read access to 9 messaging DBs plus 2 voice DBs.
- Toolchain: Docker, .NET SDK (for the DAB CLI), `kubectl`, `helm`, `aws` CLI. Egress to Docker Hub, the
  EKS API, the Secrets Manager endpoint, and **both** `192.0.2.22:1433` (messaging) and
  `192.0.2.28:1433` (voice) — Gate C opens live connections to every data source.

Health smoke — through Istio, since the host exists. It reads the **body**, not just the status:

```bash
curl -fsS https://appdb-data-api-msg.appdb.dev/health \
| jq -e '.status == "Healthy"
         and ([.checks[] | select(.tags | index("data-source"))]
              | length > 0 and all(.status == "Healthy"))'
```

**The top-level `.status` is only meaningful because per-entity health is off.** Measured on the
first pod that actually ran (2026-08-14): DAB also emits entity-level `rest`/`endpoint` checks and
runs them as `"currentRole": "anonymous"`, which the RBAC posture (§5 Gate A) grants nothing — so
all **1,131** returned `The REST HealthEndpoint query failed with code: Forbidden` and held the
rollup at `Unhealthy` while `MSSQL` reported `Healthy` in 2 ms. Every entity now carries
`health: {enabled: false}` (and `tools/generate-dev-all-entities.mjs` emits it on regeneration), so
the data-source check is what remains and a non-`Healthy` rollup is a real signal again. If you ever
re-enable an entity check on an RBAC-gated entity, this assertion is what will fail.

What `/health` proves on 2.0.9 — measured against the pinned image, not inferred from the docs:

- **It does run a real query.** `data-source.health` makes DAB open a connection and execute `SELECT 1`
  (`HealthCheckHelper.UpdateDataSourceHealthCheckResultsAsync`), timed against `threshold-ms` and cached
  for `cache-ttl-seconds`. A failed query is reported as `response-ms: -1` → that check `Unhealthy`.
- **That verdict never reaches the HTTP status.** `/health` is an MVC controller (`HealthController`)
  whose writer sets only 403 / 404 / 500; an unhealthy report goes out as **HTTP 200 with
  `"status": "Unhealthy"` in the body**. `MapHealthChecks` is bound to `/` alone, and that check is
  hardcoded `Healthy`. So **no `httpGet` probe on this image can fail because of the database** — the
  smoke must read the body, hence `jq -e`. `length > 0` guards against an empty `checks` array passing
  vacuously.
- **A DB outage at startup is a CrashLoopBackOff, not an unready pod.** Metadata init opens a connection
  per stored procedure, so an unreachable server fails `PerformOnConfigChangeAsync` and the engine calls
  `StopApplication()` *before* Kestrel binds. Verified against an unroutable server: the container exits
  **255** with "Unable to launch the Data API builder engine" and serves nothing on any path. So this
  case is caught by `helm --atomic`, not by a probe.
- **A DB outage after startup is invisible to every probe we can express in Kubernetes.** The process
  stays up and requests fail at query time; only the `/health` body says so.

The probes are therefore **process-up checks, deliberately** — `httpGet /health` still earns its place
over `tcpSocket` because the runtime-not-ready middleware answers **503** on every path except `/` until
the config is loaded.

> **The HTTP probes must set `timeoutSeconds` explicitly.** `/health` is not a static handler: when
> DAB's health cache expires it re-runs `SELECT 1` per data source. Measured on the DEV pod
> (2026-08-14, while the 1,131 per-entity checks were still enabled): **1.2–2.7 s uncached vs
> ~0.5 s cached**, alternating call to call. The kubelet default is **1 s**, so every uncached probe
> timed out and the pod flapped out of `Ready` — and was never restarted, because liveness is
> `tcpSocket` and always passes. The symptom is a pod at `1/2 Running`, `RESTARTS 0`, with a Service
> that has no endpoints, *after* a green deploy that happened to probe during a cached window.
> Disabling per-entity health removed most of that cost, but the margin is still thin — 11 data
> sources across two hosts, with a cold connect measured at 657 ms — so the chart sets
> `timeoutSeconds: 5` rather than relying on the 1 s default. A body-aware `exec` readiness probe is possible if we later want one (the image
does ship `/usr/bin/curl`), but it should wait until the post-startup `Unhealthy` flip is confirmed on a
live DB — see "Still open" in §11.

DAB's **entity-level** health checks (`entities.<name>.health.{first,threshold-ms}`), which would issue a
real per-entity query, are not available here: `HealthCheckHelper` filters out
`EntitySourceType.StoredProcedure`, and all six curated entities are stored procedures. Enabling them
would mean exposing a table or view purely to be probed, against this API's no-raw-tables posture.

> **2026-08-11 — supersedes the 2026-08-10 note above and the PR review's "`/health` is DB-aware".**
> Both were wrong in the same direction: the 08-10 note assumed a DB outage leaves the port closed (the
> process exits instead), and the readiness-probe claim assumed a non-2xx that this version never emits.

See `deploy/chart/templates/deployment.yaml` and `config/dab-config.dev.json`.

## 6a. Packaging — Helm chart

`kubectl apply` over static manifests does not carry this. The deployable is **eight objects** whose values
diverge per environment, and the current `deploy/{dev,staging}/` directories are already near-duplicates
drifting apart by hand. Replace them with one chart:

```text
appdb-data-api/deploy/chart/
  Chart.yaml
  values.yaml              # defaults + everything prod-safe-off
  templates/
    deployment.yaml        serviceaccount.yaml    secretstore.yaml
    service.yaml           virtualservice.yaml    externalsecret.yaml
    destinationrule.yaml   authpolicy.yaml        _helpers.tpl
    NOTES.txt
  values/
    dev.yaml               # DEV — appdb-data-api, both SQL hosts
    staging.yaml           # later
```

Each values file is passed **alone** (`helm ... --values values/<file>`); the chart's own
`values.yaml` is the only shared parent, and Helm loads it automatically. A values file is a
release's whole identity — SM secret, ESO role, gateway, audience — so layering one under another
is a cross-tenant bug, not a convenience.

What actually varies per environment — this is the case for a chart rather than three copies:

| | Dev | Staging | Prod |
|---|---|---|---|
| Config file | `dab-config.dev-all.json` (CLI `start -c`, image root) | base + `DAB_ENVIRONMENT=Staging` | base |
| Secret keys | `CONN_DEV_*` + `CONN_DEVVO_*` (11, one JSON secret via `dataFrom`) | `CONN_GLOBAL_CONFIG` + `CONN_ID_MSGDATA` (2) | 2 per region |
| JWT issuer | OIDC DEV | OIDC STG | OIDC PRD |
| SMS masking | unmasked (`_v5`) | masked (`_v2`) | masked |
| Replicas / host | 1 · dev host | 2 · stg host | N · per-region host |

The 2-vs-1 secret-key difference is the clincher — it changes the `ExternalSecret`'s `data[]` shape, which
a Kustomize patch models badly and a Helm `range` models cleanly.

**Chart conventions:** `appVersion` tracks the DAB base image; the *chart* version is independent. CI passes
`--set image.tag=${GITHUB_SHA::7}` and nothing else — every other value lives in the versioned values file, so
what's deployed is reconstructible from git. Keep `values.yaml` defaults closed (no host, no `anonymous`,
introspection off) so a missing override fails loudly rather than opening something.

**Do not template `dab-config*.json`.** It is baked into the image and gated by §5's validation. Templating
it would move config out from under the gates.

**Pod security.** The DAB base image defines `APP_UID=1654` but never issues `USER`, so it runs as
root — `runAsNonRoot` with no `runAsUser` defers to the image and dies at kubelet container-create,
*after* every dry-run has passed (those are admission checks). The first DEV rollout failed exactly
that way on 2026-08-14, so the uid is pinned in both the Dockerfile and the chart. `/tmp` is an
`emptyDir` because `readOnlyRootFilesystem` leaves .NET nowhere for its diagnostic socket.

The chart side lives in `values.yaml` under `podSecurityContext` (`runAsUser`/`runAsGroup`/`fsGroup`),
not as template literals, and the template wraps each in `required` — per the closed-defaults rule
above, blanking one must fail the render rather than quietly reinstating `runAsNonRoot` with no uid.
The two halves are held together by **Gate IMAGE-UID** (§5): the Dockerfile's `USER $APP_UID`
resolves against whatever the base image defines, so only comparing the built image's real uid to
the chart's number catches a base bump that moves it. Keeping them in sync is not a convention here —
it is gated.

## 6b. Exposure — Istio + domain

DAB serves plain HTTP on **port 5000**, four paths from one process:

| Path | Surface | Consumer |
|---|---|---|
| `/mcp` | MCP, streamable HTTP | **AgentCore** — the reason this is deployed |
| `/api/<entity>` | REST, GET-only, all 6 entities | Ops / Eng / scripts |
| `/graphql` | GraphQL | Eng |
| `/health` | Health | Process-up probes + CI smoke (body-asserted, §6) |

The Service is `ClusterIP` today, so nothing off-cluster can reach it. With Istio in
`dev-eks-cluster`, the chart adds a `VirtualService` bound to the shared ingress Gateway, plus a
`DestinationRule` (mTLS `ISTIO_MUTUAL` for east-west).

**Suggested host — `appdb-data-api-msg.appdb.dev`.**

Rationale: the left label is this API's **registered tool name** (`appdb-data-api-msg`, wiki §8) — the identifier
callers already use, and the JWT audience string, so the URL and the registered name agree.

Consequence to be deliberate about: staging and prod get their **own zones**, not sibling labels under this
one. Their hostnames are a values-file entry in the chart (§6a) and are decided when those pipelines land —
don't infer them from this host.

Note this is the `appdb.dev` zone, not `mcp.example.com`. The only other MCP-ish host in this repo is
`mcp-appdb-sql-latest.mcp.example.com`, which is *auto-generated by the example MCP platform* from a registered
service name — a different platform with a different consumer, so it sets no precedent here.

Confirm a cert covers `*.appdb.dev` (or issue one for this host) before the first rollout.

**Internal zone only.** Dev runs `host.mode: development` with GraphQL `allow-introspection: true` and
unmasked SMS (`_v5`). AgentCore reaches it privately, so this belongs in a private hosted zone behind an
internal LB. Do not attach it to an internet-facing gateway.

**The streaming gotcha.** `/mcp` is long-lived streamable HTTP. Istio's default route timeout will cut agent
calls mid-flight, so the `/mcp` route needs an explicit long (or disabled) `timeout` and no response
buffering. Route `/api` and `/graphql` normally — they're ordinary request/response:

```yaml
spec:
  hosts: [appdb-data-api-msg.appdb.dev]
  gateways: [istio-system/private-gateway]   # shared, DevOps-owned — not created by this chart
  http:
    - match: [{ uri: { prefix: /mcp } }]
      route: [{ destination: { host: appdb-data-api, port: { number: 80 } } }]
      timeout: 1h        # streamable HTTP — must not inherit Istio's ~15s default
    - route: [{ destination: { host: appdb-data-api, port: { number: 80 } } }]
```

> **2026-08-10 — `timeout: 0s` does not work on Istio 1.29.** The conventional "disable the timeout"
> value is rejected by CRD validation (`must be a valid duration greater than 1ms`), caught by the
> `kubectl apply --dry-run=server` step on the deploy job. Use a long *finite* timeout instead — the
> chart ships `1h`, which is ~60x a normal MCP session while still bounding a wedged connection.

The `Gateway` is **`istio-system/private-gateway`** — shared and DevOps-owned. The chart templates the
`VirtualService` only; it must not create or mutate the `Gateway`.

**Authentication at the mesh, authorization in DAB** (revised 2026-08-25). The earlier guidance here was
"one enforcement point, keep it in DAB". That was wrong about one thing: DAB answers `/mcp` **metadata** —
`initialize`, `tools/list`, `describe_entities` — before any per-tool role check, so an anonymous caller
could enumerate the tool surface. The chart now templates a `RequestAuthentication` +
`AuthorizationPolicy` (`deploy/chart/templates/authpolicy.yaml`, gated on `istio.requireJwt`, default
**true**):

- **`RequestAuthentication`** validates issuer / audience / signature against the OIDC provider's JWKS
  (`auth.jwksUri`) and sets `forwardOriginalToken: true`, so the `Authorization` header still reaches DAB.
- **`AuthorizationPolicy`** requires a validated `requestPrincipals` for everything except `/health` — a
  no-token or bad-token request matches no rule and Istio returns **403 at the mesh**.
- **DAB still validates the token and maps `permissions[].role` behind it.** The two points are not
  redundant and cannot disagree in a way that widens access: the mesh only decides *authenticated or not*;
  DAB alone decides *what that identity may call*. Both fail closed.

> **This needs cluster RBAC before it can deploy.** The `appdb-data-api-deployer` Role (§7) must grant
> `security.istio.io` — `requestauthentications` + `authorizationpolicies` — alongside its
> `networking.istio.io` and `external-secrets.io` rules; `AmazonEKSEditPolicy` / `ClusterRole/edit` covers
> built-in API groups only and does not aggregate CRDs. Without it the deploy job's
> `kubectl apply --dry-run=server` fails `Forbidden`. Widened 2026-08-25 in `appdb-terragrunt-msg`
> (DEVOPS-3512).

## 7. Identity — what the pipeline authenticates to

| Target | Mechanism | Scope |
|---|---|---|
| **AWS Secrets Manager** | **AWS OIDC → IAM role**, with `secretsmanager:GetSecretValue` on `appdb-data-api/dev/*`. **No static credential.** | One read: `appdb-data-api/dev/connstrings` for Gate C. The wildcard already covers it, so the swap needed no IAM change. **Gate role only.** |
| **Docker Hub** | `example/appdb-devops-arc/actions/setup-dockerhub-credentials` (**pinned SHA**), then `docker/login-action`. | Exports `DOCKERHUB_USERNAME=appdbsg` + `DOCKERHUB_TOKEN`. **Not governed by our roles** — see the caveat below. |
| **EKS** | AWS OIDC → IAM role in `111111111111`. Already in place (§8). | **Deploy role only:** `eks:DescribeCluster` + an EKS access entry scoped to ns `appdb-data-api`. |

Two separate IAM roles: `gate` runs PR-authored code and must not hold the deploy identity — see below.

### Docker Hub — use the org action, don't hand-roll

```yaml
- uses: example/appdb-devops-arc/actions/setup-dockerhub-credentials@e631dedd138e1ae443e3709ca9864f1fe54ba51b
- uses: docker/login-action@c94ce9fb468520275223c153574b00df6fe4bcc9   # v3
  with:
    username: ${{ env.DOCKERHUB_USERNAME }}
    password: ${{ env.DOCKERHUB_TOKEN }}
```

Internally it assumes `arn:aws:iam::333333333333:role/cicd-github-actions-dockerhub-reader-role` via GitHub
OIDC and reads SSM `/dockerhub/keys/tokens/<dockerhub-team>`, exporting `DOCKERHUB_USERNAME=appdbsg` and a
masked `DOCKERHUB_TOKEN`. It requires `permissions: id-token: write` — which the workflow already declares.
Pin the SHA rather than `@main`.

**Pass `dockerhub-team: dba` explicitly.** The input defaults to the runner's `SSM_DOCKERHUB_TEAM` env var,
but the action's script runs `set -u`, so if that variable were ever unset the step would abort on an unbound
variable rather than fail clearly. Setting it also makes the SSM path (`/dockerhub/keys/tokens/dba`) visible
in the workflow instead of implicit in runner configuration.

This also settles the tagging convention: the org's `reusable-build.yaml` uses
`git rev-parse --short ${{ github.sha }}`, matching §3.

### Secrets Manager — reuse the AWS OIDC role, no static credential

Gate C reads the dev connection string straight from Secrets Manager over **GitHub OIDC→AWS** — so there is
**no long-lived credential in GitHub secrets** (the reason Vault was rejected; see appendix).
`secretsmanager:GetSecretValue` on
`arn:aws:secretsmanager:ap-southeast-1:111111111111:secret:appdb-data-api/dev/*` is the **gate** role's only
permission. The trailing `/*` is required — Secrets Manager appends a random suffix to every secret ARN.

Role ARNs are held in **repo variables**, not hard-coded — the dev roles are expected to churn. Both jobs
fail fast with a named error if theirs is unset, since an empty `role-to-assume` otherwise fails at AWS auth
with a message that doesn't point back at the variable.

#### Two roles, because `gate` runs PR-authored code

`gate` triggers on `pull_request` and executes code from the PR branch — `ci/*.sh`, the `Dockerfile`, and the
workflow's own `run:` blocks. Anyone with **push** access can therefore run arbitrary commands under whatever
identity that job holds, without passing the CODEOWNERS review that gates *merges*. A single shared role would
hand them the deploy identity, so the two are split:

```bash
gh variable set AWS_ASSUME_ROLE_MSG_DEV_GATE --body arn:aws:iam::111111111111:role/appdb-data-api-ci-gate
gh variable set AWS_ASSUME_ROLE_MSG_DEV      --body arn:aws:iam::111111111111:role/appdb-data-api-ci
```

| Role | Account | Assumed by | IAM permissions | Cluster reach |
|---|---|---|---|---|
| `appdb-data-api-ci-gate` | 111111111111 | `gate` (incl. `pull_request`) | `secretsmanager:GetSecretValue` on `appdb-data-api/dev/*` — **nothing else** | **None.** No `eks:DescribeCluster`, no access entry. |
| `appdb-data-api-ci` | 111111111111 | `deploy` | `eks:DescribeCluster` — **no secret grant**; only the gate reads `connstrings`, and the pod gets it from ESO | `AmazonEKSEditPolicy` scoped to ns `appdb-data-api`, plus the `appdb-data-api-deployer` Role for the Istio/ESO CRDs |

The two permission sets are **disjoint** — neither role is a superset of the other, so neither can
stand in for the other. Definitions: `appdb-terragrunt-msg` →
`aws/deployment/appdb-msg-dev/sg-devel/iam_role/`.

> The split-era `AWS_ASSUME_ROLE_VOI_DEV{,_GATE}` variables and the `dev-voi` GitHub environment are
> unused as of ADR-0005; the voice-account roles behind them were destroyed in
> `example/appdb-terragrunt-voice#118`. Delete them.

The two roles carry **different trust policies** — that is the point of the split, more than the permission
delta. The deploy role must **not** list `pull_request`:

```jsonc
// appdb-data-api-ci-gate  — PR code may assume this
"repo:example/appdb-dba-db:pull_request",
"repo:example/appdb-dba-db:ref:refs/heads/*"     // gate also runs on the master push

// appdb-data-api-ci  — NOT reachable from PR-authored code (deploy skips `pull_request`)
"repo:example/appdb-dba-db:environment:dev-msg"  // the ONLY entry; see below
```

**No `ref:` entry on the deploy role, deliberately.** When a job declares an `environment:`, GitHub
replaces the ref form of the `sub` claim with `repo:<org>/<repo>:environment:<name>` — so the single
entry above is what the deploy job actually presents, and it is strictly tighter than adding
`ref:refs/heads/master` alongside it (which would also match a master-push job that had *no*
environment, i.e. one that skipped the reviewers). Removing `environment: dev-msg` from the job
therefore breaks the deploy loudly at AWS auth rather than silently downgrading the control.
Drop `ref:refs/tags/*` and the wildcard `environment:*` from the existing role while you are there.

The `deploy` job additionally sits behind the GitHub environment **`dev-msg`**, which currently has
**no required reviewers**.

> **The role split only holds while `deploy` stays off the PR path.** A `pull_request` run executes
> **the PR's own copy of the workflow**, so any job running on that event can be rewritten by whoever
> opened the PR. If `deploy` ran on PRs, a PR could edit its `run:` steps and execute them holding
> `appdb-data-api-ci` and the Docker Hub push token — no merge, no review, since `dev-msg` has no
> required reviewers. The `if: github.event_name != 'pull_request'` guard on the job is therefore
> load-bearing, not a convenience: **do not remove it to make a PR self-deploying.** Deploy a branch
> with `gh workflow run appdb-data-api --ref <branch>`, which needs the same repo access but is an
> explicit, attributable act rather than a side effect of opening a PR.
>
> Residual: anyone with repo **write** can still dispatch a deploy of arbitrary branch code, because
> `dev-msg` gates on nothing. Accepted for DEV — the blast radius is the DEV cluster plus the Docker
> Hub token that the caveat below shows is already org-wide reachable. Adding required reviewers to
> `dev-msg` closes it, and is a prerequisite before this job is pointed at another environment.

> **Why the server-side dry-run runs on the deploy job, not the PR gate.** `kubectl apply --dry-run=server`
> is *authorized* as a real create/update — Kubernetes has no "dry-run only" permission — so keeping it on
> the PR gate would mean granting PR-authored code genuine write reach into the namespace. It moved to the
> deploy path so the gate role can hold **no cluster permissions at all**. The trade: a CRD-schema mismatch
> now fails the deploy instead of the PR. PRs still get the offline chart render tests (`lint` workflow),
> and `--atomic` reverts a release that fails.

> **Caveat — Docker Hub is outside this boundary.** `setup-dockerhub-credentials` assumes
> `arn:aws:iam::333333333333:role/cicd-github-actions-dockerhub-reader-role`, whose trust policy allows
> `repo:example/appdb-*:pull_request`. **PR-authored code in any `appdb-*` repo can therefore obtain the
> Docker Hub push token today**, regardless of the split above. That is an org-wide exposure owned by the
> shared ARC tooling, not something this pipeline can close; raise it separately if it matters.

Exposing the dev connection string to PR-authored code is **inherent** to a pre-merge live validate — the gate
cannot do its job without it. What bounds it is the credential itself (see below), not the role split.

```yaml
- uses: aws-actions/configure-aws-credentials@<pinned-sha>   # v4 — GitHub OIDC, no static keys
  with:
    role-to-assume: ${{ vars.AWS_ASSUME_ROLE_MSG_DEV_GATE }}
    aws-region: ap-southeast-1
- name: Gate C — validate
  run: |
    SECRET_JSON="$(aws secretsmanager get-secret-value \
      --secret-id appdb-data-api/dev/connstrings --query SecretString --output text)"
    echo "::add-mask::$SECRET_JSON"  # aws-cli does NOT mask; mask the blob before a jq error can dump it
    # Required keys derived from the configs, so a generator-added DB fails by name here.
    # Command substitution keeps the derivation's exit status visible to `set -e`.
    keys_raw="$(ci/gate-conn-keys.sh)"
    [ -n "$keys_raw" ] || { echo "::error::derived 0 connection-string keys"; exit 1; }
    mapfile -t need <<<"$keys_raw"
    env_args=()
    for k in "${need[@]}"; do
      v="$(jq -er --arg k "$k" '.[$k]' <<<"$SECRET_JSON")" || { echo "::error::missing key $k"; exit 1; }
      echo "::add-mask::$v"
      export "$k=$v"          # NOT $GITHUB_ENV: that would scope it to every later step in the job
      env_args+=( -e "$k" )   # by name — no value on a command line or in a process list
    done
    docker run --rm --network host -v "$PWD:/work:ro" -w /work "${env_args[@]}" \
      ... validate -c dab-config.dev-all.json
```

### About the connection strings on the runner

Gate C's five-stage validate needs live connections, so the runner holds all 11 dev connection strings.
Bounding that — they are fetched **inside the validate step and exported, never written to `$GITHUB_ENV`**,
so they are scoped to the one command that needs them rather than to every later step in the job:

- All 11 use the `dev_svc_dataapi` login — `ApplicationIntent=ReadOnly`, strict read-only across all dev
  databases (db_datareader + db_denydatawriter + read execute, no write path), no `sysadmin`. Worst case on
  leak is read access to dev test data — since the dev-all migration, across 9 messaging DBs and 2 voice DBs
  rather than one.
- **`aws-cli` does not mask** — you must `echo "::add-mask::…"` on the blob *and* each extracted value before
  either reaches another log line (unlike `vault-action`, which masked by default). Masking the blob first
  matters: it means a `jq` failure mid-loop cannot dump an unmasked string. Verify masking on the first run.
- The runner is ephemeral, so it doesn't outlive the job (§6).
- **Dev only.** Do not carry this to staging/prod without re-deciding: there, run validate as an in-cluster
  Job against the pod's own Secret so no credential ever reaches a runner.

Because fork PRs don't receive repo secrets, Gate C will fail (not silently skip) on a fork PR. Same-repo
branch PRs work normally. Decide which behaviour you want before turning on fork contributions.

## 8. Prerequisites

### Settled — DevOps provisions before CI is built

| # | Item | Value |
|---|---|---|
| 1 | Image pull secret | **`regcred`** in ns `appdb-data-api`. The chart references it; DevOps creates it. |
| 2 | Docker Hub repo + token | `appdbsg/appdb-data-api`, private. Covered by (1). |
| 3 | AWS Secrets Manager | acct **`111111111111`** · **`ap-southeast-1`** · secret **`appdb-data-api/dev/connstrings`** — one JSON object, 11 `CONN_*` properties (the `create-secret` command is in `deploy/README.md` §DEV step 2). |
| 4 | External Secrets Operator | DevOps **installs ESO** in `dev-eks-cluster` and owns the **IRSA role** `dev-msg-apse1-eks-appdb-data-api-eso` (read `appdb-data-api/dev/*` only, `GetSecretValue` + `DescribeSecret`). The **chart** creates the namespaced `SecretStore` — not a `ClusterSecretStore` (§4). |
| 5 | AWS IAM role (GitHub OIDC) + EKS access entry | **Already in place.** |
| 6 | Runner | **`appdb-devops-general`** → `runs-on: appdb-devops-general`. ARC in `shared-eks` (acct `111111111111`), `minRunners: 0` (ephemeral), `containerMode: dind` so `docker build` works. **Egress to `192.0.2.22:1433` confirmed allowed from the runner subnet** — Gate C can run. |
| 7 | Istio | Gateway **`private-gateway`** in ns **`istio-system`**; sidecar-injection annotation on ns `appdb-data-api` done by DevOps. |
| 8 | Docker Hub credentials | Org action + SSM `/dockerhub/keys/tokens/cicd`; `SSM_DOCKERHUB_TEAM=cicd` already set on the runner (§7). |

### Prerequisite status — verified 2026-08-10

| # | Item | State |
|---|---|---|
| 1 | DNS + cert for `appdb-data-api-msg.appdb.dev` | **Done, nothing to do.** Host already resolves via a `*.appdb.dev` wildcard on the internal LB; cert `cert-manager-le-appdb-dev` covers it and auto-renews. |
| 2 | `secretsmanager:GetSecretValue` on the CI + ESO roles | **Done, then re-split.** The grant now sits on `appdb-data-api-ci-gate` only — `appdb-data-api-ci` keeps `eks:DescribeCluster` and no secret access (§7). The ESO role has it **and** `DescribeSecret` — the latter is required or the store goes Ready while the ExternalSecret silently never syncs. |
| 3 | Namespace + ServiceAccount | **Done.** The namespace and its `istio-injection=enabled` label are IaC-managed — `appdb-data-api` is in `apps_cfg` in the shared-eks cluster Terragrunt. The chart owns the ServiceAccount. |
| 4 | DBA — `02-dev-create-login-and-grants.sql` on DEV-NODE1 (all dev DBs) | Login `dev_svc_dataapi` now has **strict read-only across all dev databases** (db_datareader + db_denydatawriter + read execute; no write path) — superseded the earlier 6-proc grant on 2026-08-13. Re-run the script after the change. |
| 5 | Pod SG → `192.0.2.22/32` **and** `192.0.2.28/32` TCP 1433 | **Confirm.** dev-all serves both hosts, so both rules are needed. The runner's route to both is proven; the pod's is a separate rule. |
| 6 | `master` branch protection | **Confirm.** Add `lint` and `gate` as required checks once both have run at least once. |
| 7 | Istio RBAC for the CI role | **Done.** `AmazonEKSEditPolicy` maps to the `edit` ClusterRole, and no Istio ClusterRole aggregates into `edit` or `admin` — so `helm upgrade` could not have created the VirtualService/DestinationRule. Fixed by adding `kubernetes_groups = ["appdb-data-api-deployer"]` to the access entry, bound to a namespaced Role. |

**`appdb-data-api/dev/connstrings` exists** and holds **one JSON object** whose 11 properties are the
env-var names (9 `CONN_DEV_*` + 2 `CONN_DEVVO_*`), each valued with a full connection string. ESO's
`dataFrom[].extract` splits the object into one k8s Secret key per property, so the pod sees 11 discrete
env vars. Both use the IP and `TrustServerCertificate=True`; see the note in
`deploy/02-dev-create-login-and-grants.sql` for why, and keep that dev-only.

> It replaced `appdb-data-api/dev/CONN_DEV`, a single plain (non-JSON) string that only worked with ESO
> `data[]`, which copies a value verbatim. `data[]` cannot extract from a JSON object — that is the reason
> the chart moved to `dataFrom[].extract` when dev-all needed 11 keys. Delete the old secret once a green
> gate run confirms nothing still reads it.

**Sequencing.** The `lint` workflow needs nothing at all — it can merge and start protecting PRs
immediately. The `gate` job needs the secret and the DBA grants; the `deploy` job additionally needs
`regcred` and the Docker Hub repository.

## 9. Rollback

1. **Automatic** — `--atomic` reverts a release that fails to become ready. No action needed.
2. `helm -n appdb-data-api rollback appdb-data-api <revision>` (`helm history` to list). Reverts template
   changes *and* image together — the reason the chart beats `rollout undo`, which only reverts the pod spec.
3. `workflow_dispatch` with a previous `image_tag` when only the image should move.

All three work because the Deployment pins an immutable SHA. Never roll back by re-pushing a tag.

Two things to know about the dispatch path:

- **It never builds.** Only a master push pushes tags, so a dispatch on a ref whose SHA was never built
  would deploy a non-existent image. The workflow therefore runs `docker manifest inspect` before Helm —
  fail fast instead of burning the full `--atomic --timeout 8m` on `ImagePullBackOff`.
- **Gate and image can disagree.** A dispatch validates *HEAD's* config but deploys the *old image's*
  baked config. A green gate is not evidence about what the rolled-back image serves — read the config
  at that tag, not the one on your branch.

## 10. Verification

**Local — the same four gates the runner executes** (Gate C needs VPC access to the dev DB, so it only
passes from the VPN/bastion or on the runner itself):

```bash
cd appdb-data-api
docker run --rm --entrypoint dotnet -v "$PWD:/work:ro" -w /work \
  mcr.microsoft.com/azure-databases/data-api-builder:2.0.9 --version
dab configure --help | grep -q show-effective-permissions \
  && dab configure --show-effective-permissions -c config/dab-config.dev.json \
  || jq -e '[.entities[].permissions[].role]|unique==["appdb-data-api-msg-reader"]' config/dab-config.dev.json  # Gate A
for f in dab-config.json config/dab-config.dev.json; do jq '.runtime.mcp["dml-tools"]' "$f"; done   # Gate B (both files)
ci/gate-no-write-tools.sh                                    # Gate NO-WRITE-TOOLS (self-discovering)
# Gate C — needs AWS creds + reachability to BOTH dev SQL nodes. Same shape as the CI step.
SECRET_JSON="$(aws secretsmanager get-secret-value \
  --secret-id appdb-data-api/dev/connstrings --query SecretString --output text | jq -c .)"
for k in $(ci/gate-conn-keys.sh); do
  v="$(jq -er --arg k "$k" '.[$k]' <<<"$SECRET_JSON")" || { echo "missing key $k"; break; }
  export "$k=$v"
done
dab validate -c dab-config.dev-all.json
docker build -t appdb-data-api:test .                                      # Gate D
DAB_ENVIRONMENT=Local dab start          # offline smoke, header X-MS-API-ROLE, no token
```

**Prove the gates actually gate.** On a scratch branch, three deliberate breakages, each must fail the PR:

| Breakage | Should fail at |
|---|---|
| `read-records: true` in `dml-tools` | Gate B |
| `read_records: true` (underscore typo — DAB silently *enables* unknown keys) | Gate B only; `dab validate` will pass it |
| Rename a `source.object` to a non-existent proc | Gate C, stage 5 (entity metadata) |
| `command: ["--config-file", …]` in any compose file or manifest | Gate CONFIG-FLAG |
| Delete the `data-api-builder:<tag>` mention from this file | Gate VERSION (an empty tag list is a skew, not a pass) |
| Remove `USER $APP_UID` from the Dockerfile, or change `podSecurityContext.runAsUser` | Gate IMAGE-UID (both halves compared against the built image, not against each other) |
| Drop `timeoutSeconds` from either HTTP probe | chart tests (asserted per probe — a whole-render grep would pass on the other one) |
| Blank `podSecurityContext.runAsUser` | chart tests, closed-defaults case (`required` fails the render) |

An unproven gate is not a gate — the second row is the whole reason Gate B exists separately from `dab validate`.
All of these are asserted mechanically by `ci/tests/run-gate-tests.sh`, which runs in the `lint` workflow.

**Post-merge:**

```bash
helm -n appdb-data-api history appdb-data-api                                # new revision, status deployed
kubectl -n appdb-data-api get deploy appdb-data-api -o jsonpath='{..image}'  # == merged git SHA
kubectl -n appdb-data-api get externalsecret appdb-data-api-conn             # SecretSynced
kubectl -n appdb-data-api get virtualservice appdb-data-api
istioctl analyze -n appdb-data-api                                           # catches gateway/host mismatches
```

**Through Istio, not just in-cluster** — the failure this catches is a `VirtualService` bound to the wrong
Gateway, which an in-cluster `curl` will happily mask:

```bash
curl -fsS https://appdb-data-api-msg.appdb.dev/health
```

**End-to-end** (needs a DEV-environment OIDC bearer token):

```bash
curl -H "Authorization: Bearer $TOKEN" -H "X-MS-API-ROLE: appdb-data-api-msg-reader" \
  "https://appdb-data-api-msg.appdb.dev/api/get_account_balance?AccountUid=<test-uid>"
```

**Verify `/mcp` streams** before handing the URL over — a working `/health` does not prove the streaming
route survives Istio's timeout. Do an MCP `tools/list` and confirm the 6 named tools come back and the
connection isn't severed mid-stream. Then give AgentCore / the OIDC provider
`https://appdb-data-api-msg.appdb.dev/mcp` to register.

## 11. Resolved questions

All five questions this section originally raised are answered. Kept as a record of what was
verified and how, so a future change knows what to re-check.

| # | Question | Answer (verified 2026-08-10) |
|---|---|---|
| 1 | Does `private-gateway` terminate `appdb.dev`, and is there a cert? (§6b) | **Yes.** It selects `istio: ingressgateway-internal`, whose Service is `aws-load-balancer-scheme: internal` — so the "internal zone only" requirement holds. Its 443 server is `hosts: ["*"]` with cert `cert-manager-le-appdb-dev` (`CN=*.appdb.dev`, cert-manager-managed so it auto-renews). `appdb-data-api-msg.appdb.dev` already resolves via a wildcard record on that LB. **No Gateway edit, no cert to issue, no DNS record to create.** |
| 2 | Chart location — this repo or the org chart repo? | **`deploy/chart/` in this repo.** CI installs from a path; the chart is versioned with the app it deploys. |
| 3 | Does `dab configure --show-effective-permissions` exist on 2.0.9? | **Yes**, and it needs **no database** (exit 0 against an unroutable connection string), so Gate A's cross-check runs in the credential-free workflow. Output is `info: Entity: <name>` followed by `info:   Role: <role> \| Actions: <actions>`. It resolves the **merged** config, which the per-file `jq` walk cannot. |
| 4 | PR approval policy for outside contributors (§6) | Repo setting — require approval for all outside collaborators. This is the one runner control that ephemerality does not cover: a fork PR would otherwise run arbitrary code in the same job that holds all 11 connection strings. |
| 5 | Is the CI OIDC role least-privilege? (§7) | **Permissions yes, trust policy broader than intended.** Inline policy grants only `secretsmanager:GetSecretValue` on `appdb-data-api/dev/*` and `eks:DescribeCluster`; the EKS access entry is `AmazonEKSEditPolicy` scoped to ns `appdb-data-api`. But the trust policy allows `ref:refs/heads/*`, `ref:refs/tags/*`, `environment:*` and `pull_request` — i.e. any branch, not a branch-protected environment. `pull_request` is **required** for Gate C to run on PRs. **Addressed by splitting the identity** (§7): a `appdb-data-api-ci-gate` role whose trust policy carries `pull_request` and whose only permission is the dev secret read, and `appdb-data-api-ci` for deploys, assumable only from `environment:dev-msg`. The server-side dry-run moved to the deploy job so the gate needs **no** cluster permissions. Residuals, accepted for dev: the gate still reads the connection strings (inherent to a pre-merge live validate) — and since the dev-all migration that is 11 of them across two hosts, not one — and the shared Docker Hub reader role trusts `appdb-*:pull_request` independently of this pipeline. |
| 6 | Does `/health` return a non-2xx when the DB check fails on 2.0.9? (§6) | **No — it is always 200.** `HealthController` hands off to a writer that sets only 403 / 404 / 500; an unhealthy report is a 200 carrying `"status": "Unhealthy"`. The `MapHealthChecks` middleware is bound to `/`, whose `BasicHealthCheck` is hardcoded `Healthy`. Consequences: an `httpGet` probe can never fail on the database, so the CI smoke asserts the **body** (§6); and a startup-time DB outage never reaches a probe at all, because metadata init opens a connection per stored procedure and the engine `StopApplication()`s before Kestrel binds — verified, exit **255** against an unroutable server. Entity-level checks, which would query a real entity, exclude `EntitySourceType.StoredProcedure` and so cover none of our six. |

### Still open

1. **Docker Hub repository** — `appdbsg/appdb-data-api` returns 404, so it is empty or not yet
   created. If it does not exist, the first push auto-creates it and may default to **public**,
   while §3 requires Private. The image carries no credentials (configs use `@env()`), but it would
   expose procedure names, database names, and the JWT audience string. Confirm in the Hub console before
   the first push.
2. **Staging may share a defect found in dev.** `dab start --help` states the config *"Defaults to
   `dab-config.json` unless `dab-config.<DAB_ENVIRONMENT>.json` exists"* — replace, not merge.
   `dab-config.Staging.json` is an auth-only fragment, which under replace semantics is not a usable
   config. Out of scope for DEV; verify before the staging pipeline lands.
3. **Confirm the post-startup `Unhealthy` flip on a live DB.** The startup case is verified (engine exits
   255, §6); the mid-life case — DB dies *after* a healthy start — could only be read from the 2.0.9
   source, because the DAB and SQL Server images are `amd64`-only and both segfault under QEMU on an
   `arm64` workstation. On a live dev pod, break connectivity and confirm `/health` returns
   `"status": "Unhealthy"` with `response-ms: -1` **at HTTP 200**. If it does not flip, the smoke's `jq`
   assertion is worthless and the only real check is a token'd data-path call (item 4).
4. **A token'd data-path smoke.** The only check that exercises a curated procedure end to end is
   `GET /api/id_lookup_sms_region_by_umid` with a DEV-environment OIDC bearer token. Every way to give the `deploy`
   job one adds a static credential this pipeline deliberately avoids (§7), and the deploy role no
   longer reads Secrets Manager at all. Decide the credential question before building it.

## Appendix — HashiCorp Vault alternative (only if it's the platform standard)

This spec uses **AWS Secrets Manager** (§4/§7) because the rest of the pipeline is already GitHub-OIDC→AWS,
so it adds **no static credential**. Switch to Vault-via-ESO only if `shared-eks`'s blessed secrets pattern is
Vault — then match the platform rather than run a bespoke SM path on a shared cluster. The deltas are small
and local:

| Concern | AWS Secrets Manager (this spec) | HashiCorp Vault |
|---|---|---|
| Pod → secret | ESO `provider.aws` + IRSA on the ESO controller | ESO `provider.vault`, k8s-auth role bound to SA `appdb-data-api` |
| CI (Gate C) → secret | Existing AWS OIDC role + `secretsmanager:GetSecretValue` — **no new secret** | `hashicorp/vault-action` **AppRole** → `VAULT_ROLE_ID`/`VAULT_SECRET_ID` as **static GitHub secrets** |
| Store scope | shared `aws-secretsmanager` `ClusterSecretStore`; IAM policy is the boundary | namespaced `SecretStore` (mount `team_appdb-db`, path `appdb-data-api/dev`, key `CONN_DEV`) |
| Rotation burden | none (no static CI credential) | `secret_id` TTL + a rotation owner |

The registry (Docker Hub `appdbsg`, §3) is independent of this choice and unchanged either way. If the
team later moves to **ECR**, the pull secret `regcred` and the Docker Hub org action drop out — the node role
pulls from ECR under the same AWS OIDC identity; gates, tagging, rollback, and chart are unaffected.

## References

- `deploy/README.md` — per-environment deploy steps and the §0 gates this spec automates
- `deploy/chart/` — the Helm chart CI applies (replaced the hand-written `deploy/dev/` manifests)
- `docs/microsoft-sql-mcp-conformance.md` — why the RBAC gate is blocking
- [dab validate](https://learn.microsoft.com/en-us/azure/data-api-builder/command-line/dab-validate) —
  validation stages, exit codes, the `--config`-only flag surface
- [DAB CLI reference](https://learn.microsoft.com/en-us/azure/data-api-builder/command-line) ·
  [What's new in DAB 2.0](https://learn.microsoft.com/en-us/azure/data-api-builder/whats-new/version-2-0)
  (role inheritance → `--show-effective-permissions`)
