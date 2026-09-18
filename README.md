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
  tool or DML entity appears in config — it isn't a convention, it's a test.
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
Each gate is a standalone shell script that fails the build on a specific
class of mistake:

| Gate | Fails the build when |
|---|---|
| `gate-no-write-tools.sh` | a write-capable MCP tool is enabled |
| `gate-dml-tools.sh` | a DML tool appears in the MCP block |
| `gate-rbac.sh` | an entity grants permissions to an unexpected role |
| `gate-conn-keys.sh` | a connection string is inlined instead of `@env()` |
| `gate-config-flag.sh` | a runtime flag drifts from the expected baseline |
| `gate-image-uid.sh` | the container would run as root |
| `gate-version.sh` | the DAB version pin doesn't match the image |
| `gate-vendor-drift.sh` | `services/dba-mcp/` no longer matches its pinned upstream sha |

```bash
./ci/validate-base.sh dab-config.json
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
`CONN_GLOBAL_CONFIG` and `CONN_ID_MSGDATA` (fails fast if either is unset) for
`dab-mcp`, and mounts a `fleet.json` (host/port/database topology; credentials
still come from `SQL_USER`/`SQL_PASSWORD`, never written to the file) for
`dba-mcp`.

## Adding an entity

1. Write the stored procedure. `proposed-procs/` has worked examples of the
   shape: explicit parameters, a stable column contract, no `SELECT *`.
2. Grant `EXECUTE` to the API role — see `deploy/01-create-login-and-grants.sql`.
3. Add the entity to the config with `"source": { "type": "stored-procedure" }`.
4. Run `./ci/validate-base.sh` and `dab validate`.

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
  layout, AG health, backup history, agent job status, memory dump listing,
  machine/OS specs, tempdb usage, statistics health, and a narrowed
  database-info projection run through dbatools today (waves 1 and 2 — see
  `docs/superpowers/plans/2026-09-17-dba-mcp-waves-2-3.md`).
- **Opt-in, DMV by default** — the live-diagnostics tools (`get_wait_stats`,
  `get_latch_stats`, `get_active_sessions`) run their original hand-written
  DMV queries by default; setting `DBATOOLS_FIRST=1` (exactly `"1"`) routes
  those three through dbatools instead. A dbatools failure falls back to the
  DMV path and logs why, rather than erroring, so the flag can never be the
  reason one of these tools is unavailable mid-incident. This is wave 3: the
  two paths are meant to be compared against real fleet traffic, and the
  loser deleted.
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
- [docs/microsoft-sql-mcp-conformance.md](docs/microsoft-sql-mcp-conformance.md) — MCP conformance notes
- [docs/superpowers/specs/2026-09-16-dba-mcp-stack-design.md](docs/superpowers/specs/2026-09-16-dba-mcp-stack-design.md) — why `dba-mcp` is vendored, and the two-endpoint design

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
