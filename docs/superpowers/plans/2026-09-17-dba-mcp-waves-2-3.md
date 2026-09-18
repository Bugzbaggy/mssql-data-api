# Waves 2 & 3 dbatools Migration — Implementation Plan (Plan 3 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the structural tools (wave 2) onto dbatools outright, and the live-diagnostics tools (wave 3) behind a flag that keeps the DMV path as the default until latency is compared on real traffic.

**Architecture:** Wave 2 tools switch to `callDbatools` the way wave 1 did. Wave 3 tools keep BOTH implementations: the DMV query stays the default and the dbatools path is selected by `DBATOOLS_FIRST=1`, so the two can be compared on a live incident and the loser deleted.

**Tech Stack:** Node 22 + TypeScript, the `PwshWorker` and `callDbatools` from Plan 2, PowerShell 7 + dbatools 2.7.2, SQL Server 2022 in Docker.

**Spec:** `docs/superpowers/specs/2026-09-16-dba-mcp-stack-design.md`

## Global Constraints

- **ALL implementation happens in the UPSTREAM repo `C:\tmp\oss-staging\mssql-dba-mcp`, working directory `server/`.** `mssql-data-api/services/dba-mcp/` is a vendored copy and `ci/gate-vendor-drift.sh` refuses hand edits. The final task re-syncs.
- **Per-tool handlers live in `src/tools.ts`**, not `src/dbatools.ts`. (Plan 2's brief got this wrong; do not repeat it.) `callDbatools` and `assertReadOnlyCommand` live in `src/dbatools.ts`; `PwshWorker` in `src/pwshWorker.ts`.
- `assertReadOnlyCommand` is an **allow-list** (`Get-`/`Test-`/`Measure-`/`Find-Dba*` plus `Invoke-DbaDiagnosticQuery`). Every cmdlet below passes it. Do not widen the allow-list.
- `npm test` runs `tests/*.test.ts`. **Run it three times** at each verification point — this suite has had a race that appeared 2 runs in 3.
- The parity harness is `node --import tsx tests/parity/run-parity.mjs --instance <inst>` and it FAILS when `CASES` is empty, by design.
- Every field name below was captured by running the cmdlet against a live SQL 2022 CU14 instance, not read from documentation. If a field is missing at implementation time, **stop and report** — that changes the mapping, it is not something to work around by choosing a different field.

## Cmdlets deliberately NOT used, with the reason

Do not "fix" these by migrating them. Each was investigated and rejected:

| Tool | Why it stays DMV |
|---|---|
| `get_memory_usage` | `Get-DbaMemoryUsage` does **not accept `-SqlInstance`**. It is host-level (`-ComputerName`, WMI/CIM) and needs host access the server does not have to every fleet node. |
| `get_cpu_history` | `Get-DbaCpuUsage` is host/CIM-based (per-thread rows, `PSComputerName`, `CimClass`). Not equivalent to the DMV ring buffer this tool reads. |
| `get_index_fragmentation` | No dbatools cmdlet exists (`Get-Command -Module dbatools *Fragment*` → nothing). |
| `get_query_store_regressions` | Only Query Store *configuration* cmdlets exist; no regression analysis. |
| `get_plan_cache_pollution`, `get_top_queries`, `get_columnstore_health`, `get_index_usage_stats`, `get_deadlock_history` | No equivalent cmdlet. |

---

### Task 1: Wave 2 — tempdb and statistics

**Files:**
- Modify: `server/src/tools.ts`
- Modify: `server/tests/parity/run-parity.mjs`

**Interfaces:**
- Consumes: `callDbatools(cmd, params?, timeoutSec?)` from `src/dbatools.ts`.
- Produces: `get_tempdb_usage` and `get_statistics_health` served from dbatools, each with a registered parity case.

**Verified field sets** (captured live, 2026-09-17):

```
Get-DbaTempdbUsage   -> ComputerName, InstanceName, SqlInstance, Spid, StatementCommand,
                        QueryText, ProcedureName, StartTime, CurrentUserAllocatedKB,
                        TotalUserAllocatedKB, UserDeallocatedKB, TotalUserDeallocatedKB,
                        InternalAllocatedKB, TotalInternalAllocatedKB, RequestedReads,
                        RequestedWrites, RequestedLogicalReads, RequestedCPUTime,
                        IsUserProcess, Status, Database, LoginName, HostName, ProgramName

Get-DbaDbccStatistic -> ComputerName, InstanceName, SqlInstance, Database, Object, Target,
                        Cmd, Name, Updated, Rows, RowsSampled, Steps, Density,
                        AverageKeyLength, StringIndex, FilterExpression, UnfilteredRows,
                        PersistedSamplePercent
```

- [ ] **Step 1: Bring up a test instance**

```bash
docker run -d --name wave23-sql -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD='Str0ng!DemoPassw0rd' -e MSSQL_PID=Developer -p 14355:1433 mcr.microsoft.com/mssql/server:2022-CU14-ubuntu-22.04
```

Wait until it answers before continuing:

```bash
until MSYS_NO_PATHCONV=1 docker exec wave23-sql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'Str0ng!DemoPassw0rd' -C -Q 'SELECT 1' >/dev/null 2>&1; do sleep 5; done; echo ready
```

`MSYS_NO_PATHCONV=1` is required — without it Git Bash rewrites `/opt/...` into a Windows path and the exec fails.

- [ ] **Step 2: Migrate `get_tempdb_usage`**

In `src/tools.ts`, replace that tool's DMV body with a `callDbatools("Get-DbaTempdbUsage", { SqlInstance: <resolved instance> })` call. Keep the tool's name, description, argument schema and the shape it returns to the caller. Add its parity case to `CASES` in `tests/parity/run-parity.mjs`:

```javascript
  { tool: "get_tempdb_usage", cmdlet: "Get-DbaTempdbUsage", params: {},
    keyFields: ["Spid", "Database", "CurrentUserAllocatedKB", "TotalUserAllocatedKB"] },
```

- [ ] **Step 3: Verify it before touching the second tool**

```bash
npm run typecheck
node --import tsx tests/parity/run-parity.mjs --instance 'localhost,14355'
```

Expected: typecheck exits 0; the harness prints `ok   get_tempdb_usage: ...` and exits 0.

**`Get-DbaTempdbUsage` reports ACTIVE allocations, so an idle instance may legitimately return zero rows.** If it does, generate some: open a session that creates a temp table and leaves a transaction open, then re-run. Do NOT weaken the assertion to accept an empty result — an empty result is exactly what a broken migration also looks like.

- [ ] **Step 4: Migrate `get_statistics_health` and add its case**

```javascript
  { tool: "get_statistics_health", cmdlet: "Get-DbaDbccStatistic", params: {},
    keyFields: ["Database", "Object", "Name", "Updated", "Rows", "RowsSampled"] },
```

`Get-DbaDbccStatistic` needs statistics to exist. On a bare instance, create a table with an index in a user database first so the cmdlet has something to report.

- [ ] **Step 5: Full verification**

```bash
npm run typecheck && npm run build
npm test; npm test; npm test
node --import tsx tests/parity/run-parity.mjs --instance 'localhost,14355'
bash ../ci/leak-scan.sh
```

Expected: typecheck/build 0; three `npm test` runs all exit 0; all parity cases (wave 1's nine plus these two) pass; leak scan clean.

- [ ] **Step 6: Commit**

```bash
git add src/tools.ts tests/parity/run-parity.mjs
git commit -m "feat: serve tempdb and statistics tools from dbatools"
```

---

### Task 2: Wave 2 — database info, with narrowing

**Files:**
- Modify: `server/src/tools.ts`
- Modify: `server/tests/parity/run-parity.mjs`

**Interfaces:**
- Consumes: `callDbatools`.
- Produces: `get_database_info` served from dbatools, returning a **narrowed** projection.

**This tool gets its own task because of a real hazard.** `Get-DbaDatabase` returns a full SMO object — **roughly 200 properties**, including nested collections (`Tables`, `Views`, `StoredProcedures`, `Triggers`, …). Returning that verbatim would produce an enormous payload, and the worker's `ConvertTo-PlainRows` flattening would be walking object graphs it should never touch.

- [ ] **Step 1: Narrow at the source, in PowerShell**

Do NOT fetch everything and filter in TypeScript — the cost is paid in the worker before it reaches Node. Select the columns in the pipeline. The tool should request only:

```
Name, Status, RecoveryModel, CompatibilityLevel, Collation, Owner, CreateDate,
Size, SpaceAvailable, IsAccessible, IsUpdateable, ReadOnly, LastBackupDate,
LastDifferentialBackupDate, LastLogBackupDate, LastGoodCheckDbTime,
AvailabilityGroupName, AvailabilityDatabaseSynchronizationState, LogReuseWaitStatus
```

All of those were confirmed present on the live probe. Implement the narrowing however fits the worker's protocol best — a `Select-Object` in the request, or a dedicated parameter — and say in your report which you chose and why.

- [ ] **Step 2: Verify the payload actually shrank**

Measure it. Call the cmdlet both ways and compare the serialized size:

```bash
node --import tsx -e "import {callDbatools} from './src/dbatools.ts'; const r = await callDbatools('Get-DbaDatabase', {SqlInstance:'localhost,14355'}); console.log('wide bytes', JSON.stringify(r).length);"
```

then the same through your narrowed tool path. Report both numbers. If the narrowed form is not dramatically smaller, the narrowing is not working and the task is not done.

- [ ] **Step 3: Add the parity case**

```javascript
  { tool: "get_database_info", cmdlet: "Get-DbaDatabase", params: {},
    keyFields: ["Name", "Status", "RecoveryModel", "CompatibilityLevel", "Owner"] },
```

- [ ] **Step 4: Verify**

```bash
npm run typecheck && npm run build
npm test; npm test; npm test
node --import tsx tests/parity/run-parity.mjs --instance 'localhost,14355'
```

All must pass.

- [ ] **Step 5: Commit**

```bash
git add src/tools.ts tests/parity/run-parity.mjs
git commit -m "feat: serve database info from dbatools, narrowed at the source"
```

---

### Task 3: The DBATOOLS_FIRST switch

**Files:**
- Create: `server/src/dbatoolsFirst.ts`
- Create: `server/tests/dbatoolsFirst.test.ts`

**Interfaces:**
- Produces: `export function dbatoolsFirst(): boolean` — true only when `process.env.DBATOOLS_FIRST === "1"`. Also `export async function withFallback<T>(dbatoolsPath: () => Promise<T>, dmvPath: () => Promise<T>): Promise<T>` — runs the dbatools path when the flag is on and the DMV path otherwise, and **falls back to the DMV path if the dbatools path throws**, logging why.

- [ ] **Step 1: Write the failing test**

Create `server/tests/dbatoolsFirst.test.ts`:

```typescript
import { test } from "node:test";
import assert from "node:assert/strict";
import { dbatoolsFirst, withFallback } from "../src/dbatoolsFirst.ts";

test("defaults to the DMV path when the flag is unset", async () => {
  delete process.env.DBATOOLS_FIRST;
  assert.equal(dbatoolsFirst(), false);
  const r = await withFallback(async () => "dbatools", async () => "dmv");
  assert.equal(r, "dmv");
});

test("uses the dbatools path only when the flag is exactly '1'", async () => {
  process.env.DBATOOLS_FIRST = "true";
  assert.equal(dbatoolsFirst(), false);
  process.env.DBATOOLS_FIRST = "1";
  assert.equal(dbatoolsFirst(), true);
  const r = await withFallback(async () => "dbatools", async () => "dmv");
  assert.equal(r, "dbatools");
  delete process.env.DBATOOLS_FIRST;
});

test("falls back to DMV when the dbatools path throws", async () => {
  process.env.DBATOOLS_FIRST = "1";
  const r = await withFallback(
    async () => { throw new Error("worker exploded"); },
    async () => "dmv",
  );
  assert.equal(r, "dmv");
  delete process.env.DBATOOLS_FIRST;
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module '../src/dbatoolsFirst.ts'`.

- [ ] **Step 3: Implement**

Create `server/src/dbatoolsFirst.ts`:

```typescript
// Wave 3 is the live-diagnostics set - the tools reached for during an incident. Both
// implementations are kept so the cost can be compared on real traffic instead of
// argued about: the DMV path stays the DEFAULT, and DBATOOLS_FIRST=1 opts in.
//
// Exactly "1", not any truthy string: an operator who sets DBATOOLS_FIRST=false meant
// to turn it OFF, and a loose check would do the opposite of what they asked.
export function dbatoolsFirst(): boolean {
  return process.env.DBATOOLS_FIRST === "1";
}

/**
 * Run whichever path is selected, falling back to DMV if the dbatools path fails.
 *
 * The fallback is deliberate: an opt-in performance experiment must never be the reason
 * a diagnostic tool is unavailable mid-incident. A worker crash degrades to the proven
 * path rather than to an error.
 */
export async function withFallback<T>(
  dbatoolsPath: () => Promise<T>,
  dmvPath: () => Promise<T>,
): Promise<T> {
  if (!dbatoolsFirst()) return dmvPath();
  try {
    return await dbatoolsPath();
  } catch (e) {
    console.error(`[dbatools-first] falling back to the DMV path: ${(e as Error).message}`);
    return dmvPath();
  }
}
```

- [ ] **Step 4: Verify**

Run: `npm test` three times — all exit 0, with the 3 new tests passing. `npm run typecheck` → 0.

- [ ] **Step 5: Commit**

```bash
git add src/dbatoolsFirst.ts tests/dbatoolsFirst.test.ts
git commit -m "feat: add the DBATOOLS_FIRST switch with a DMV fallback"
```

---

### Task 4: Wave 3 — live diagnostics behind the flag

**Files:**
- Modify: `server/src/tools.ts`
- Modify: `server/tests/parity/run-parity.mjs`

**Interfaces:**
- Consumes: `withFallback` (Task 3), `callDbatools`.
- Produces: `get_wait_stats`, `get_latch_stats` and `get_active_sessions` with BOTH paths, DMV by default.

**Verified field sets and measured latency** (live, 2026-09-17, warm):

```
Get-DbaWaitStatistic   336ms (vs 401ms DMV, 0.8x)
  -> WaitType, Category, WaitSeconds, ResourceSeconds, SignalSeconds, WaitCount,
     Percentage, AverageWaitSeconds, Ignorable, URL, Notes

Get-DbaLatchStatistic  239ms (vs 148ms DMV, 1.6x)
  -> WaitType, WaitSeconds, WaitCount, Percentage, AverageWaitSeconds, URL

Get-DbaProcess        1428ms (vs 473ms DMV, 3.0x)  <- the expensive one
  -> Spid, Login, Host, Database, Status, Command, Cpu, MemUsage, BlockingSpid,
     IsSystem, Program, LastQuery, LoginTime, LastRequestStartTime, ClientNetAddress
```

**Do not read those ratios as settled.** The DMV baseline was measured through `Invoke-DbaQuery`, which is itself PowerShell; the real server reads DMVs through the Node `mssql` driver, which is much faster. The true gap is therefore **larger** than shown. That uncertainty is the reason for the flag.

- [ ] **Step 1: Keep the DMV implementation intact**

Before changing anything, extract each tool's existing DMV body into a named local function (e.g. `waitStatsViaDmv(...)`) that returns exactly what it returns today. Do not alter its SQL. This is the default path and must remain byte-identical in behaviour.

- [ ] **Step 2: Add the dbatools path and wire the switch**

For each of the three tools, add a `...ViaDbatools(...)` function calling `callDbatools`, then have the handler return:

```typescript
  return withFallback(() => waitStatsViaDbatools(inst), () => waitStatsViaDmv(inst));
```

- [ ] **Step 3: Prove BOTH paths work**

This is the step that matters. For each tool, exercise it with the flag off and on:

```bash
DBATOOLS_FIRST=0 node --import tsx tests/parity/run-parity.mjs --instance 'localhost,14355'
DBATOOLS_FIRST=1 node --import tsx tests/parity/run-parity.mjs --instance 'localhost,14355'
```

Both must pass. Register the parity cases:

```javascript
  { tool: "get_wait_stats", cmdlet: "Get-DbaWaitStatistic", params: {},
    keyFields: ["WaitType", "WaitSeconds", "WaitCount", "Percentage"] },
  { tool: "get_latch_stats", cmdlet: "Get-DbaLatchStatistic", params: {},
    keyFields: ["WaitType", "WaitSeconds", "WaitCount", "Percentage"] },
  { tool: "get_active_sessions", cmdlet: "Get-DbaProcess", params: {},
    keyFields: ["Spid", "Login", "Database", "Status", "BlockingSpid"] },
```

- [ ] **Step 4: Prove the fallback actually fires**

Set `DBATOOLS_FIRST=1` and make the dbatools path fail (e.g. temporarily point `PWSH_EXE` at a nonexistent binary), then call one of the three tools and confirm it still returns DMV results and logs the fallback. Capture that output — a fallback nobody has seen fire is a fallback nobody should trust.

- [ ] **Step 5: Full verification**

`npm run typecheck && npm run build`; `npm test` ×3; both parity runs; `bash ../ci/leak-scan.sh`. All green.

- [ ] **Step 6: Tear down and commit**

```bash
docker rm -f wave23-sql
git add src/tools.ts tests/parity/run-parity.mjs
git commit -m "feat: wave-3 live diagnostics behind DBATOOLS_FIRST, DMV by default"
```

---

### Task 5: Document, re-sync, and land

**Files:**
- Modify: `server/README.md` (or `USER-GUIDE.md` — whichever documents env vars; check both)
- Modify: `mssql-data-api/services/dba-mcp/**` (via the sync script only)

- [ ] **Step 1: Document the switch**

Add a short section covering: what `DBATOOLS_FIRST=1` does, that the DMV path is the default and the dbatools path is opt-in, that a dbatools failure falls back rather than erroring, which three tools it affects, and the measured latency with the caveat that the baseline understates the gap. State plainly that the intent is to compare on real traffic and delete the loser.

- [ ] **Step 2: Push upstream and capture the sha**

```bash
git push origin main
git rev-parse HEAD
```

- [ ] **Step 3: Re-sync the vendored copy**

In `mssql-data-api`:

```bash
export PATH="$HOME/bin:$PATH"
node scripts/sync-dba-mcp.mjs --sha <the 40-char sha>
ci/gate-vendor-drift.sh --write
```

Sync FIRST, then `--write`. The reverse records a hash for the old content.

- [ ] **Step 4: Verify the vendored copy**

```bash
diff -r services/dba-mcp/src ../mssql-dba-mcp/server/src && echo "src identical"
test -f services/dba-mcp/src/dbatoolsFirst.ts && echo "switch vendored"
bash ci/gate-vendor-drift.sh && bash ci/tests/run-vendor-tests.sh && bash ci/leak-scan.sh
```

- [ ] **Step 5: Commit and push**

```bash
git add services/dba-mcp
git commit -m "chore: re-sync the vendored DBA MCP server at <short sha>

Brings in waves 2 and 3: tempdb, statistics and database-info tools served from
dbatools, and the live-diagnostics tools behind DBATOOLS_FIRST with the DMV path
as the default."
git push origin main
```

- [ ] **Step 6: Verify CI on both repos**

Both `mssql-dba-mcp` and `mssql-data-api` must report `completed/success`. The Stack smoke test proves the rebuilt image still boots.
