# Design: compose DAB and a dbatools-first DBA MCP server into one stack

**Date:** 2026-09-16
**Status:** approved, pending implementation plan

## Problem

Two halves of the same idea live in two repos. `mssql-data-api` serves curated
**application data** through Data API Builder. `mssql-dba-mcp` serves **DBA
diagnostics** through a custom MCP server. An agent that can do both has to be
pointed at two unrelated projects, each set up by hand.

`nocentino/sql-mcp-server` demonstrates the shape worth adopting: one
`docker-compose` running a DAB MCP endpoint and a custom DBA MCP endpoint side by
side, so an agent registers two servers and gets both surfaces. Its DBA server is
DMV/T-SQL throughout. Ours uses **dbatools**, which is the substantive difference
and the bulk of the work.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Where the stack lives | `mssql-data-api`, with the DBA server **vendored** | one clone, one compose, one CI |
| Upstream | `mssql-dba-mcp` stays the source of truth | it remains independently usable; the vendored copy is a consumer |
| Drift control | pinned sha + sync script + CI gate | vendoring without this is a slow fork |
| Tool implementation | **dbatools-first**: replace DMV tools wherever a cmdlet exists | one consistent implementation path, less bespoke T-SQL to maintain |
| Execution | one **persistent pwsh worker**, dbatools preloaded | a multi-second module import per call, across ~43 tools, is unusable |
| SQL target | containers by default, fleet via a compose override | the repo stays runnable by anyone who clones it, and useful against the fleet |
| Service name | `dba-mcp` | matches the upstream repo name |

## Architecture

```
                       ┌──────────────────────────────┐
   agent / Copilot ───►│  dab-mcp     :5000 /mcp      │  application data
                       │  DAB 2.0.9                   │  curated stored procs
                       │  zero table entities         │  JWT → DAB role
                       └───────────────┬──────────────┘
                                       │
                       ┌───────────────┴──────────────┐
   agent / Copilot ───►│  dba-mcp     :3000 /mcp      │  diagnostics
                       │  MCP_TRANSPORT=http          │  dbatools-first
                       │  read-only login             │  TOOLSET gating
                       └───────────────┬──────────────┘
                                       │
                       ┌───────────────┴──────────────┐
                       │  sqlserver   :1433           │  seeded demo DB
                       │  (replaced by fleet.json in  │
                       │   docker-compose.fleet.yml)  │
                       └──────────────────────────────┘
```

The separation is the security boundary and it already exists in both codebases:
`dab-mcp` never exposes a raw table (100% `stored-procedure` entities);
`dba-mcp` never reads application data. Keeping them as two endpoints keeps
those postures independently auditable — one can be exposed to a team the other
is not.

`MCP_TRANSPORT=http` and `TOOLSET` already exist upstream, so no transport or
gating work is required.

## Repository layout

```
mssql-data-api/
  dab-config.json  config/  dab-config.dev-all.json      DAB side, unchanged
  services/dba-mcp/                                      VENDORED
    .upstream                    { repo, sha }
    src/  tests/  package.json
    src/pwshWorker.ts            NEW: persistent dbatools worker
  scripts/sync-dba-mcp.mjs       refresh from upstream at the pinned sha
  ci/gate-vendor-drift.sh        fail if the copy != the pinned sha
  docker-compose.yml             sqlserver + dab-mcp + dba-mcp
  docker-compose.fleet.yml       override: drop sqlserver, mount fleet.json
  seed/                          demo schema + data for the container
```

`sync-dba-mcp.mjs` follows the existing `sync-schema-docs.mjs` pattern: additive,
idempotent, and it records what it pinned. `gate-vendor-drift.sh` re-derives a
hash of `services/dba-mcp/src` and compares it to `.upstream`, so a local edit to
the vendored copy fails CI with a message telling you to land it upstream first.

## The pwsh worker

```
boot    pwsh -NoProfile -NonInteractive -Command -
        Import-Module dbatools                    once, ~3-8s

call    stdin   {"id":N,"cmd":"Get-DbaWaitStatistic","params":{...}}\n
        stdout  {"id":N,"ok":true,"rows":[...],"truncated":false}\n

guards  per-call timeout            → kill + restart, return a tool error
        restart-on-exit supervisor  → bounded retries, then fail closed
        queue depth cap             → refuse rather than unbounded buffer
        assertReadOnlyCommand       → unchanged, in front of every dispatch
```

One line of JSON per message, newline-framed, correlated by `id`. The worker is a
single process, not a pool: at this concurrency a pool adds moving parts without
adding throughput.

**Failure modes.** A crashed worker restarts and the in-flight call returns a tool
error — never a hang, never a silent empty result. A timeout kills the worker
rather than leaving a wedged runspace. If dbatools fails to import at boot, the
server starts and every dbatools tool reports why, instead of the process dying.

`truncated` is carried through on every result set, matching the convention
nocentino's server uses and ours already follows, so an agent can tell a clipped
answer from a complete one.

## Migration waves

Each wave is a PR with parity tests.

1. **Clear wins** — backup/restore history, AG topology, agent jobs, instance
   configuration, disk and file layout, security auditing. dbatools is better
   than hand-rolled DMV queries here, and these are not latency-critical.
2. **Structural** — storage, index fragmentation, statistics health.
3. **Live diagnostics** — waits, blocking, plan cache, active sessions.

**Wave 3 ships behind `DBATOOLS_FIRST=1`, with the DMV path retained as the
default fallback.** These are the production-validated queries reached for under
incident pressure, and dbatools adds a PowerShell hop to exactly those calls. Both
implementations exist either way, so the cost is one env check; the benefit is
being able to compare latency on a real incident and keep whichever wins. If the
dbatools path proves equal or better, the flag flips to default-on and the DMV
path is deleted in a follow-up.

## Testing

| Layer | What it proves |
|---|---|
| Worker unit tests | framing, correlation, timeout, crash-restart, queue cap, and that a write command is still refused |
| Parity tests | each migrated tool against its DMV predecessor on the seeded container: same shape, same key fields |
| Stack smoke test | `docker compose up`, both `/health` green, `tools/list` on both endpoints, assert counts |
| Vendor drift gate | the vendored copy matches the pinned upstream sha |

Parity tests are the load-bearing ones. The risk in a dbatools rewrite is not that
a tool breaks loudly — it is that a column is renamed or a unit changes and the
agent quietly reasons over different data.

## Risks

- **Latency.** A PowerShell hop per call. Mitigated by the persistent worker and,
  for wave 3, by the fallback flag.
- **Coverage gaps.** Some DMV tools have no dbatools equivalent. Those keep their
  current implementation; the migration table records each one and why.
- **Output drift.** dbatools property names differ from the DMV columns the
  existing tool descriptions promise. Parity tests catch this; tool descriptions
  are updated in the same PR.
- **Vendoring rot.** Addressed by the drift gate, which is the reason vendoring is
  acceptable at all.

## Out of scope

Always On AG automation in the stack (nocentino's `scripts/ag/`), replacing DAB
with anything else, and any change to the DAB entity surface.
