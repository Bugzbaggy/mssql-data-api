# mssql-data-api

A governed, read-only HTTP + GraphQL + MCP API over SQL Server, built on
[Microsoft Data API Builder](https://github.com/Azure/data-api-builder) —
plus a second, [dbatools](https://dbatools.io/)-backed MCP endpoint for
SQL Server diagnostics. Two endpoints, two security postures, one compose
stack.

Exposes a **curated set of stored procedures** — not tables — so application
teams, dashboards, and AI agents can read operational data without anyone
handing out a database login.

[![DAB](https://img.shields.io/badge/Data%20API%20Builder-2.0.9-0078D4)](https://github.com/Azure/data-api-builder)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Why this exists

The usual ways of answering "can I get read access to that database?" are all
bad: a shared read-only login that never gets rotated, a bespoke API per
consumer, or direct table access that breaks the moment the schema changes.

This is the fourth option. One deployment, declarative config, and:

- **Stored procedures only.** Entities map to SPs, so the schema stays free to
  change behind a stable contract.
- **Read-only, enforced in CI.** A gate fails the build if a write-capable
  MCP tool is enabled in any config — it isn't a convention, it's a test.
- **Per-team roles.** A caller's JWT claim maps to a DAB role; roles map to
  entity permissions.
- **Runs against a read-only replica**, so reporting never touches a primary.
- **Speaks MCP**, so an agent can use the same governed surface as a dashboard.

## Architecture

Two MCP endpoints, kept separate on purpose: `dab-mcp` serves curated
**application data** (stored procedures only, zero table entities); `dba-mcp`
serves **SQL Server diagnostics** (dbatools + DMVs, read-only by
construction). Each can be handed to a different audience without the other's
data or blast radius coming along.

```
  caller (app / dashboard / AI agent)
        │  JWT
        ▼
  ┌────────────────────────┐      ┌────────────────────────┐
  │  dab-mcp       :5000   │      │  dba-mcp       :3000   │
  │  Data API Builder      │      │  MCP diagnostics       │
  │  REST /api  GraphQL    │      │  dbatools + DMVs       │
  │  /graphql   MCP /mcp   │      │  MCP /mcp    /health   │
  │  role ← JWT claim      │      │  read-only, allow-list │
  └─────────┬──────────────┘      └─────────┬──────────────┘
            │ EXECUTE on curated SPs only    │ VIEW SERVER STATE only
            ▼                                ▼
        SQL Server read-only replica / fleet instance
```

`dab-mcp` is this repo's own code. `dba-mcp` is a **vendored copy** of a
separate upstream server — see [DBA diagnostics endpoint](#dba-diagnostics-endpoint-dba-mcp)
below before editing anything under `services/dba-mcp/`.

## CI gates

The `ci/` directory is the interesting part, and it's reusable on its own.
Each gate is a standalone shell script (bash + `jq`; ARTIFACT and IMAGE-UID
also need Docker) that fails the build on a specific class of mistake:

| Gate | Script | Fails the build when |
|---|---|---|
| NO-WRITE-TOOLS | `gate-no-write-tools.sh` | any self-contained config, curated or broad-read, leaves `create-record`, `update-record` or `delete-record` missing or not `false` |
| DML-TOOLS | `gate-dml-tools.sh` | a curated config's `runtime.mcp.dml-tools` is not exactly the 7 kebab-case keys with only `describe-entities` and `execute-entity` true |
| RBAC | `gate-rbac.sh` | an entity's roles are not exactly the one role pinned for its config file, or an entity has no `permissions`; with Docker, DAB's effective permissions are cross-checked too |
| KEY-FIELDS | `gate-key-fields.sh` | a table or view entity declares no `source.key-fields` |
| HEALTH-PROBE | `gate-health-probe.sh` | a config that answers `/health` anonymously has an entity whose `health.enabled` is not `false` |
| CONN-KEYS | `gate-conn-keys.sh` | a connection string is not an `@env()` reference (it also prints the `CONN_*` keys the dev-all tree needs) |
| DEV-ALL-TREE | `gate-dev-all-tree.sh` | the dev-all base and its child configs disagree with each other or with disk ([docs/dev-all-status.md](docs/dev-all-status.md)) |
| DEV-ALL-PROTECTED | `gate-dev-all-protected.sh` | the dev-all tree serves an object or column that `config/dev-all/protected-excluded.txt` protects |
| CONFIG-FLAG | `gate-config-flag.sh` | a compose file or k8s manifest passes `--config-file`, which the image entrypoint silently ignores |
| VERSION | `gate-version.sh` | a DAB tag anywhere (compose, manifest, chart `appVersion`, the RBAC gate's default image, the badge above, the deploy docs) differs from the `Dockerfile` `FROM` tag |
| VENDOR-DRIFT | `gate-vendor-drift.sh` | `services/dba-mcp/` no longer matches the hash recorded in its pin |
| PROTECTION | `gate-protection.sh` | any of DEV-ALL-TREE, NO-WRITE-TOOLS, KEY-FIELDS, HEALTH-PROBE, DEV-ALL-PROTECTED, CONN-KEYS, DML-TOOLS or RBAC (`jq` assertion only) fails — one command, no Docker, no database |
| ARTIFACT | `gate-image-configs.sh <image>` | the configs baked into a built image fail Gate PROTECTION |
| IMAGE-UID | `gate-image-uid.sh <image>` | the built image's uid differs from the chart's `podSecurityContext.runAsUser` (an image with no `USER` runs as root) |

CI (`.github/workflows/ci.yml`, on pushes and pull requests to `main`) runs six
jobs: **Config gates** (every gate above except PROTECTION, ARTIFACT and
IMAGE-UID, each as its own step), **Gate self-tests**
(`ci/tests/run-gate-tests.sh`), **Chart tests** (`ci/tests/run-chart-tests.sh`),
**No internal identifiers** (`ci/leak-scan.sh` and its self-test), **Vendor
tests** (`ci/tests/run-vendor-tests.sh`) and **Stack smoke test** (brings up
`docker-compose.stack.yml`, probes both `/health` endpoints, then runs Gate
ARTIFACT on the image it built). IMAGE-UID needs the image a deploy pipeline
builds, so it is not run here.

Run the config gates locally, from the repo root:

```bash
./ci/gate-protection.sh
./ci/gate-config-flag.sh && ./ci/gate-version.sh && ./ci/gate-vendor-drift.sh
./ci/tests/run-gate-tests.sh     # proves each gate fails on the breakage it exists for
```

## Quick start

Point `dab-mcp` alone at a database you already have (a dev box, a real
listener):

```bash
git clone https://github.com/Bugzbaggy/mssql-data-api.git
cd mssql-data-api
cp .env.example .env        # fill in CONN_* connection strings
docker compose up
```

- REST — `http://localhost:5000/api/<entity>`
- GraphQL — `http://localhost:5000/graphql`
- MCP — `http://localhost:5000/mcp`
- Health — `http://localhost:5000/health`, answered without a token; it reports the data-source
  check only, since every entity's own health check is off (Gate HEALTH-PROBE keeps it that way)

Validate a config before deploying:

```bash
dab validate -c dab-config.json
```

### Running the full stack (dab-mcp + dba-mcp)

`docker-compose.stack.yml` is a self-contained demo: it also brings up a
seeded SQL Server container, so there's nothing else to point at.

```bash
cp .env.stack.example .env.stack
docker compose --env-file .env.stack -f docker-compose.stack.yml up
```

- `dab-mcp` — `http://localhost:5000/mcp` (application data)
- `dba-mcp` — `http://localhost:3000/mcp`, health at `http://localhost:3000/health` (diagnostics)

To run the same two endpoints against a real fleet instead of the demo
container, add the `docker-compose.fleet.yml` overlay and name the services
explicitly (a bare `up` would still start the demo `sqlserver`/`seed`
services, which the overlay can't remove):

```bash
docker compose --env-file .env.stack \
  -f docker-compose.stack.yml -f docker-compose.fleet.yml up dab-mcp dba-mcp
```

The overlay does **not** inherit the demo's connection settings — it requires
`CONN_GLOBAL_CONFIG` and `CONN_REGION2_MSGDATA` (fails fast if either is unset) for
`dab-mcp`, and mounts a `fleet.json` (host/port/database topology; credentials
still come from `SQL_USER`/`SQL_PASSWORD`, never written to the file) for
`dba-mcp`.

## Adding an entity

1. Write the stored procedure. `proposed-procs/` has worked examples of the
   shape: explicit parameters, a stable column contract, no `SELECT *`.
2. Grant `EXECUTE` to the API role — see `deploy/01-create-login-and-grants.sql`.
3. Add the entity to the config with `"source": { "type": "stored-procedure" }`,
   `"health": { "enabled": false }` (Gate HEALTH-PROBE — `dab-config.json`
   answers `/health` anonymously) and `permissions` granting `execute` to the
   config's one pinned role, `appdb-data-api-msg-reader` (Gate RBAC).
4. Run `./ci/gate-protection.sh` and `dab validate`.

## Deploying

- **Kubernetes** — Helm chart in `deploy/chart/`, secrets via External Secrets
- **EC2 / VM** — Docker Compose unit in `deploy/ec2/`
- **Database setup** — `deploy/0*-create-login-and-grants.sql`

See [deploy/README.md](deploy/README.md) and [docs/](docs/).

> All database names, logins, roles, and hostnames here are **placeholders**
> (`AppDb`, `svc_dataapi`, `role_svc_dataapi`). Substitute your own.

## DBA diagnostics endpoint (dba-mcp)

`services/dba-mcp/` is a **vendored copy** of a separate upstream repo, pinned
by commit sha in `services/dba-mcp/.upstream`. It is not this repo's source —
`ci/gate-vendor-drift.sh` hashes the vendored tree and fails the build if it
no longer matches the pin, so a hand edit here is caught, not silently
forked. To change the server:

1. Land the change in the upstream `mssql-dba-mcp` repo.
2. `node scripts/sync-dba-mcp.mjs --sha <new-sha>` — refreshes the vendored
   files and moves the pin.
3. `ci/gate-vendor-drift.sh --write` — records the new hash.

It is **dbatools-backed**: a single long-lived PowerShell worker preloads the
[dbatools](https://dbatools.io/) module once at startup (`dbatools 2.7.2`,
baked into the image at build time — see `services/dba-mcp/Dockerfile`) so a
fresh process per call never pays the module-import cost. It is **read-only
by construction**: every dbatools call passes through an allow-list before it
reaches a shell — only `Get-`/`Test-`/`Measure-`/`Find-Dba*` cmdlets (plus
`Invoke-DbaDiagnosticQuery`) are permitted, an explicit denylist blocks the
few read-verb cmdlets that actually write (`Test-DbaLastBackup` restores a
backup to verify it), and login/principal-changing cmdlets are rejected
outright regardless of verb. An unrecognized cmdlet is refused by default.

**Migration status.** Not every tool is dbatools-backed, and that's by
design, not by omission:

- **Already migrated** — instance properties, build/version, database file
  layout, AG health, backup history, agent job status, machine/OS specs,
  tempdb usage, VLF counts, and a narrowed database-info projection run
  through dbatools today (waves 1 and 2 — see
  `docs/superpowers/plans/2026-09-17-dba-mcp-waves-2-3.md`).
- **Opt-in, DMV by default** — the live-diagnostics tools (`get_wait_stats`,
  `get_latch_stats`, `get_active_sessions`) and `get_statistics_health` run
  their original hand-written DMV queries by default; setting
  `DBATOOLS_FIRST=1` (exactly `"1"`) routes those four through dbatools
  instead. A dbatools failure falls back to the DMV path and logs why, rather
  than erroring, so the flag can never be the reason one of these tools is
  unavailable mid-incident. This is wave 3: the two paths are meant to be
  compared against real fleet traffic, and the loser deleted.
- **Staying on DMV permanently** — no dbatools cmdlet exists for index
  fragmentation, Query Store regression analysis, plan cache pollution, top
  queries, columnstore health, index usage stats, or deadlock history.
  Memory usage and CPU history also stay on DMVs: their closest cmdlets
  (`Get-DbaMemoryUsage`, `Get-DbaCpuUsage`) are host-level — they take
  `-ComputerName`, not `-SqlInstance` — and would need host access the
  server doesn't have to every fleet node.

## Documentation

- [docs/index.md](docs/index.md) — overview
- [docs/identity-and-audit.md](docs/identity-and-audit.md) — JWT → role → audit trail
- [docs/ci-cd-dev.md](docs/ci-cd-dev.md) — pipeline
- [docs/dev-all-status.md](docs/dev-all-status.md) — the broad-read dev-all config tree and its gates
- [docs/microsoft-sql-mcp-conformance.md](docs/microsoft-sql-mcp-conformance.md) — MCP conformance notes
- [docs/superpowers/specs/2026-09-16-dba-mcp-stack-design.md](docs/superpowers/specs/2026-09-16-dba-mcp-stack-design.md) — why `dba-mcp` is vendored, and the two-endpoint design

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
