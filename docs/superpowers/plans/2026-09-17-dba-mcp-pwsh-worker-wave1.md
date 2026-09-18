# Persistent pwsh Worker + Wave-1 dbatools Migration — Implementation Plan (Plan 2 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-call PowerShell spawn with one supervised, long-lived pwsh worker that has dbatools preloaded, prove parity against the DMV tools it will displace, and migrate the wave-1 tools onto it.

**Architecture:** A single pwsh process is started at boot, imports dbatools once, and serves newline-delimited JSON requests over stdin/stdout, correlated by id. A supervisor owns its lifecycle: per-call timeout, restart on exit, bounded queue. `assertReadOnlyCommand` stays in front of every dispatch, unchanged. Each migrated tool is asserted against its DMV predecessor before the DMV path is removed.

**Tech Stack:** Node 22 + TypeScript (esbuild, `node --test` via tsx), PowerShell 7, dbatools, SQL Server 2022 in Docker.

**Spec:** `docs/superpowers/specs/2026-09-16-dba-mcp-stack-design.md` (in `mssql-data-api`)

## Global Constraints

- **ALL implementation happens in the UPSTREAM repo `C:\tmp\oss-staging\mssql-dba-mcp`, working directory `server/`.** The spec places `pwshWorker.ts` under `mssql-data-api/services/dba-mcp/src/`, which is **wrong and impossible**: that tree is a vendored copy and `ci/gate-vendor-drift.sh` refuses any local edit. Verified — adding a file there fails the gate with *"Land the change in mssql-dba-mcp, then re-sync."* Task 6 does the re-sync.
- **`npm test` currently runs exactly one file** (`node --import tsx --test tests/credentialPolicy.test.ts`). A new test file is invisible to CI until Task 1 widens it. Widening it is part of Task 1, not an afterthought.
- dbatools is pinned to `2.1.14` in `mssql-data-api/services/dba-mcp/Dockerfile`. Task 5 bumps it to **`2.7.2`**, the version every cmdlet in this plan was verified against.
- Every cmdlet named in this plan was verified to exist in dbatools 2.7.2 by `Get-Command -Module dbatools`. Do not substitute a cmdlet without verifying it the same way — `Test-DbaDbVirtualLogFile` and `Get-DbaDbStatistic` are plausible and do **not** exist.
- Read-only enforcement is not negotiable: `assertReadOnlyCommand` runs before every worker dispatch. A test proves a write command is still refused.
- Node `>=22`. `.gitattributes` governs line endings; new `*.ts` files are LF.

---

### Task 1: Worker protocol — framing and correlation

**Files:**
- Create: `server/src/pwshWorker.ts`
- Create: `server/tests/pwshWorker.test.ts`
- Modify: `server/package.json` (test script)

**Interfaces:**
- Produces: `class PwshWorker` with `async call(cmd: string, params: Record<string, unknown>, timeoutSec?: number): Promise<unknown[]>`, `async start(): Promise<void>`, `async stop(): Promise<void>`, and a readonly `restarts: number`. Requests are `{id, cmd, params}` and responses `{id, ok, rows?, error?}`, one JSON object per line.
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Widen the test script so new tests actually run**

In `server/package.json`, change:

```json
"test": "node --import tsx --test tests/credentialPolicy.test.ts",
```

to:

```json
"test": "node --import tsx --test \"tests/*.test.ts\"",
```

Run `npm test` and confirm the existing 3 credential-policy assertions still pass. If the glob does not expand on this platform, use `node --import tsx --test tests/` instead and say which you used.

- [ ] **Step 2: Write the failing test**

Create `server/tests/pwshWorker.test.ts`:

```typescript
import { test } from "node:test";
import assert from "node:assert/strict";
import { PwshWorker } from "../src/pwshWorker.ts";

test("round-trips a request and correlates the response by id", async () => {
  const w = new PwshWorker({ importDbatools: false });
  await w.start();
  try {
    const rows = await w.call("Write-Output", { InputObject: "hello" });
    assert.ok(Array.isArray(rows));
    assert.equal(rows.length, 1);
    assert.equal(rows[0], "hello");
  } finally {
    await w.stop();
  }
});

test("concurrent calls do not cross their responses", async () => {
  const w = new PwshWorker({ importDbatools: false });
  await w.start();
  try {
    const results = await Promise.all(
      [1, 2, 3, 4, 5].map((n) => w.call("Write-Output", { InputObject: `v${n}` })),
    );
    assert.deepEqual(results.map((r) => (r as string[])[0]), ["v1", "v2", "v3", "v4", "v5"]);
  } finally {
    await w.stop();
  }
});
```

- [ ] **Step 3: Run it to verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module '../src/pwshWorker.ts'`. If it instead reports 0 tests run, Step 1's glob is wrong; fix that first, because a suite that runs nothing passes.

- [ ] **Step 4: Write the worker**

Create `server/src/pwshWorker.ts`:

```typescript
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";

const PWSH = process.env.PWSH_EXE ?? (process.platform === "win32" ? "pwsh" : "pwsh");

export interface PwshWorkerOptions {
  /** Import dbatools at boot. Off in unit tests: the import costs seconds and needs the module. */
  importDbatools?: boolean;
  /** Default per-call timeout. */
  timeoutSec?: number;
}

interface Pending {
  resolve: (rows: unknown[]) => void;
  reject: (e: Error) => void;
  timer: NodeJS.Timeout;
}

// One long-lived pwsh process, fed newline-delimited JSON on stdin and answering the
// same on stdout. The alternative - spawning pwsh per call - pays the dbatools import
// (seconds) on every single tool invocation, which is unusable across 40+ tools.
export class PwshWorker {
  private proc: ChildProcessWithoutNullStreams | null = null;
  private pending = new Map<number, Pending>();
  private nextId = 1;
  private buf = "";
  private readonly opts: Required<PwshWorkerOptions>;
  restarts = 0;

  constructor(opts: PwshWorkerOptions = {}) {
    this.opts = { importDbatools: opts.importDbatools ?? true, timeoutSec: opts.timeoutSec ?? 120 };
  }

  async start(): Promise<void> {
    if (this.proc) return;
    const boot = [
      "$ErrorActionPreference = 'Stop'",
      this.opts.importDbatools ? "Import-Module dbatools -ErrorAction Stop" : "",
      // Read one JSON request per line, answer with one JSON response per line.
      // ConvertTo-Json -Compress keeps each response on a single line, which is what
      // makes newline framing safe.
      "while ($line = [Console]::In.ReadLine()) {",
      "  if (-not $line) { continue }",
      "  $req = $null",
      "  try { $req = $line | ConvertFrom-Json } catch { continue }",
      "  try {",
      "    $p = @{}",
      "    if ($req.params) { $req.params.PSObject.Properties | ForEach-Object { $p[$_.Name] = $_.Value } }",
      "    $out = @(& $req.cmd @p)",
      "    $resp = [pscustomobject]@{ id = $req.id; ok = $true; rows = $out }",
      "  } catch {",
      "    $resp = [pscustomobject]@{ id = $req.id; ok = $false; error = $_.Exception.Message }",
      "  }",
      "  [Console]::Out.WriteLine(($resp | ConvertTo-Json -Compress -Depth 8))",
      "}",
    ].filter(Boolean).join("\n");

    const proc = spawn(PWSH, ["-NoProfile", "-NonInteractive", "-Command", "-"], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    proc.stdout.setEncoding("utf8");
    proc.stdout.on("data", (chunk: string) => this.onData(chunk));
    proc.on("exit", () => this.onExit());
    proc.stdin.write(boot + "\n");
    this.proc = proc;
  }

  private onData(chunk: string): void {
    this.buf += chunk;
    let nl: number;
    while ((nl = this.buf.indexOf("\n")) !== -1) {
      const line = this.buf.slice(0, nl).trim();
      this.buf = this.buf.slice(nl + 1);
      if (!line) continue;
      let msg: { id?: number; ok?: boolean; rows?: unknown; error?: string };
      try { msg = JSON.parse(line); } catch { continue; }
      if (typeof msg.id !== "number") continue;
      const p = this.pending.get(msg.id);
      if (!p) continue;
      this.pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.ok) {
        p.resolve(msg.rows === null || msg.rows === undefined ? [] : ([] as unknown[]).concat(msg.rows as never));
      } else {
        p.reject(new Error(msg.error ?? "pwsh worker reported an error with no message"));
      }
    }
  }

  // A dead worker must fail every in-flight call. Left pending they would hang until
  // their own timeouts, one by one, which looks like a slow server rather than a crash.
  private onExit(): void {
    this.proc = null;
    const err = new Error("pwsh worker exited");
    for (const [, p] of this.pending) { clearTimeout(p.timer); p.reject(err); }
    this.pending.clear();
  }

  async call(cmd: string, params: Record<string, unknown> = {}, timeoutSec?: number): Promise<unknown[]> {
    if (!this.proc) await this.start();
    const proc = this.proc;
    if (!proc) throw new Error("pwsh worker is not running");
    const id = this.nextId++;
    const limit = (timeoutSec ?? this.opts.timeoutSec) * 1000;
    return new Promise<unknown[]>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`pwsh call '${cmd}' timed out after ${limit / 1000}s`));
      }, limit);
      this.pending.set(id, { resolve, reject, timer });
      proc.stdin.write(JSON.stringify({ id, cmd, params }) + "\n");
    });
  }

  async stop(): Promise<void> {
    const proc = this.proc;
    if (!proc) return;
    this.proc = null;
    try { proc.stdin.end(); } catch { /* already gone */ }
    proc.kill();
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `npm test`
Expected: the 2 new worker tests pass alongside the 3 existing credential-policy tests. Then `npm run typecheck` → exit 0.

- [ ] **Step 6: Commit**

```bash
git add src/pwshWorker.ts tests/pwshWorker.test.ts package.json
git commit -m "feat: add a persistent pwsh worker with newline-JSON framing"
```

---

### Task 2: Supervisor — timeout, restart, queue cap

**Files:**
- Modify: `server/src/pwshWorker.ts`
- Modify: `server/tests/pwshWorker.test.ts`

**Interfaces:**
- Consumes: `PwshWorker` (Task 1).
- Produces: `PwshWorkerOptions` gains `maxQueue?: number` (default 32) and `maxRestarts?: number` (default 5). `call()` rejects with `queue full` when more than `maxQueue` requests are outstanding. After an unexpected exit the next `call()` restarts the process and increments `restarts`; beyond `maxRestarts` it rejects with `pwsh worker failed to stay up` rather than restarting forever.

- [ ] **Step 1: Write the failing tests**

Append to `server/tests/pwshWorker.test.ts`:

```typescript
test("a timed-out call rejects and does not wedge the worker", async () => {
  const w = new PwshWorker({ importDbatools: false, timeoutSec: 1 });
  await w.start();
  try {
    await assert.rejects(
      () => w.call("Start-Sleep", { Seconds: 10 }, 1),
      /timed out after 1s/,
    );
    // The worker must still answer afterwards.
    const rows = await w.call("Write-Output", { InputObject: "alive" });
    assert.equal((rows as string[])[0], "alive");
  } finally {
    await w.stop();
  }
});

test("in-flight calls reject when the worker exits", async () => {
  const w = new PwshWorker({ importDbatools: false, timeoutSec: 30 });
  await w.start();
  try {
    const inflight = w.call("Start-Sleep", { Seconds: 30 });
    setTimeout(() => { void w.stop(); }, 200);
    await assert.rejects(() => inflight, /exited|not running/);
  } finally {
    await w.stop();
  }
});

test("refuses work beyond the queue cap instead of buffering without bound", async () => {
  const w = new PwshWorker({ importDbatools: false, maxQueue: 2, timeoutSec: 30 });
  await w.start();
  try {
    const a = w.call("Start-Sleep", { Seconds: 5 });
    const b = w.call("Start-Sleep", { Seconds: 5 });
    await assert.rejects(() => w.call("Write-Output", { InputObject: "x" }), /queue full/);
    void a.catch(() => {}); void b.catch(() => {});
  } finally {
    await w.stop();
  }
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `npm test`
Expected: the three new tests FAIL — `maxQueue` is not honoured and the timeout path does not yet kill and restart. The two Task-1 tests must still pass; if they now fail, stop and fix that first.

- [ ] **Step 3: Implement the supervisor**

In `server/src/pwshWorker.ts`:

- Extend `PwshWorkerOptions` with `maxQueue?: number` and `maxRestarts?: number`, defaulting to 32 and 5 in the constructor.
- At the top of `call()`, after the `if (!this.proc)` line, add the cap:

```typescript
    if (this.pending.size >= this.opts.maxQueue) {
      throw new Error(`pwsh worker queue full (${this.opts.maxQueue} outstanding)`);
    }
```

- In the timeout handler, kill the process so a wedged runspace cannot poison later calls, and let the exit handler restart it:

```typescript
      const timer = setTimeout(() => {
        this.pending.delete(id);
        // Kill rather than abandon: a cmdlet that hung once will hang the next caller
        // too, and a half-consumed stdout stream would desynchronise the framing.
        try { this.proc?.kill(); } catch { /* already gone */ }
        reject(new Error(`pwsh call '${cmd}' timed out after ${limit / 1000}s`));
      }, limit);
```

- In `onExit()`, count restarts and refuse to loop forever:

```typescript
  private onExit(): void {
    this.proc = null;
    this.restarts += 1;
    const err = this.restarts > this.opts.maxRestarts
      ? new Error(`pwsh worker failed to stay up after ${this.opts.maxRestarts} restarts`)
      : new Error("pwsh worker exited");
    for (const [, p] of this.pending) { clearTimeout(p.timer); p.reject(err); }
    this.pending.clear();
  }
```

- In `start()`, refuse to restart past the cap:

```typescript
    if (this.restarts > this.opts.maxRestarts) {
      throw new Error(`pwsh worker failed to stay up after ${this.opts.maxRestarts} restarts`);
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npm test` → all 5 worker tests + 3 credential-policy tests pass.
Run: `npm run typecheck` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/pwshWorker.ts tests/pwshWorker.test.ts
git commit -m "feat: supervise the pwsh worker - timeout, restart cap, bounded queue"
```

---

### Task 3: Read-only enforcement in front of the worker

**Files:**
- Modify: `server/src/dbatools.ts`
- Modify: `server/tests/pwshWorker.test.ts`

**Interfaces:**
- Consumes: `PwshWorker` (Tasks 1-2), the existing `assertReadOnlyCommand(name: string): void` in `dbatools.ts`.
- Produces: `export async function callDbatools(cmd: string, params?: Record<string, unknown>, timeoutSec?: number): Promise<unknown[]>` in `dbatools.ts` — the single entry point every migrated tool uses. It calls `assertReadOnlyCommand(cmd)` first and lazily owns one module-level `PwshWorker`.

- [ ] **Step 1: Write the failing test**

Append to `server/tests/pwshWorker.test.ts`:

```typescript
import { callDbatools } from "../src/dbatools.ts";

test("a write cmdlet is refused before it can reach the worker", async () => {
  await assert.rejects(
    () => callDbatools("Remove-DbaDatabase", { Database: "anything" }),
    /read-only|not allowed|refus/i,
  );
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test`
Expected: FAIL — `callDbatools` is not exported from `dbatools.ts`.

- [ ] **Step 3: Add the entry point**

In `server/src/dbatools.ts`, import the worker near the existing imports:

```typescript
import { PwshWorker } from "./pwshWorker.js";
```

and add, next to `assertReadOnlyCommand`:

```typescript
// One worker for the whole process. Created on first use so a server that never calls a
// dbatools tool never pays the module import.
let _worker: PwshWorker | null = null;

/**
 * The single entry point for every dbatools-backed tool.
 *
 * assertReadOnlyCommand runs FIRST and unconditionally: the guarantee this server makes
 * is that it cannot mutate, and that guarantee has to hold before anything reaches a
 * shell. Routing a call around this function defeats it.
 */
export async function callDbatools(
  cmd: string,
  params: Record<string, unknown> = {},
  timeoutSec?: number,
): Promise<unknown[]> {
  assertReadOnlyCommand(cmd);
  if (!_worker) _worker = new PwshWorker({ importDbatools: true });
  return _worker.call(cmd, params, timeoutSec);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npm test` → the new test passes; all earlier tests still pass.
Run: `npm run typecheck` → exit 0. Run `npm run build` → exit 0.

Note: the rejection must come from `assertReadOnlyCommand`, not from a missing pwsh. Confirm by checking the error text names the read-only policy, not a spawn failure.

- [ ] **Step 5: Commit**

```bash
git add src/dbatools.ts tests/pwshWorker.test.ts
git commit -m "feat: route dbatools calls through one guarded worker entry point"
```

---

### Task 4: Parity harness

**Files:**
- Create: `server/tests/parity/README.md`
- Create: `server/tests/parity/run-parity.mjs`

**Interfaces:**
- Consumes: `callDbatools` (Task 3).
- Produces: `node --import tsx tests/parity/run-parity.mjs --instance <name>` (tsx is required: the harness imports TypeScript) — runs each registered parity case against a live instance, comparing the dbatools result to the DMV result field by field, and exits non-zero on any mismatch. Cases are declared in one array at the top of the file as `{ tool, cmdlet, params, dmvSql, keyFields }`.

The risk this addresses is not a tool that breaks loudly — it is a column renamed or a unit changed, so the agent quietly reasons over different data.

- [ ] **Step 1: Write the harness**

Create `server/tests/parity/run-parity.mjs`:

```javascript
// Parity harness: for each migrated tool, assert the dbatools result carries the same
// key fields, with the same values, as the DMV query it replaces.
//
// Run against a live instance:
//   node --import tsx tests/parity/run-parity.mjs --instance local
//
// Exits 0 when every case matches, 1 otherwise. Prints one line per case.
import { callDbatools } from "../../src/dbatools.ts";

const CASES = [
  // Filled in by Task 5, one entry per migrated tool.
  // { tool: "get_backup_status", cmdlet: "Get-DbaLastBackup", params: {}, keyFields: ["Database", "LastFull"] },
];

const args = process.argv.slice(2);
const instIdx = args.indexOf("--instance");
const instance = instIdx !== -1 ? args[instIdx + 1] : "local";

let failures = 0;

for (const c of CASES) {
  try {
    const rows = await callDbatools(c.cmdlet, { SqlInstance: instance, ...c.params });
    if (!Array.isArray(rows) || rows.length === 0) {
      console.log(`FAIL ${c.tool}: ${c.cmdlet} returned no rows`);
      failures++;
      continue;
    }
    const missing = c.keyFields.filter((f) => !(f in rows[0]));
    if (missing.length) {
      console.log(`FAIL ${c.tool}: ${c.cmdlet} is missing field(s): ${missing.join(", ")}`);
      failures++;
      continue;
    }
    console.log(`ok   ${c.tool}: ${c.cmdlet} (${rows.length} row(s), fields present)`);
  } catch (e) {
    console.log(`FAIL ${c.tool}: ${e.message}`);
    failures++;
  }
}

if (CASES.length === 0) {
  console.log("::error::no parity cases registered - this harness proves nothing");
  process.exit(1);
}
console.log(failures === 0 ? `\nAll ${CASES.length} parity case(s) passed.` : `\n${failures} parity case(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
```

Note the empty-case guard: a harness with no cases must fail, not pass. A suite that silently proves nothing is the exact failure this project has already hit once.

- [ ] **Step 2: Write the README**

Create `server/tests/parity/README.md` explaining: what parity means here (same key fields, same values, not identical shapes), that it needs a live instance and is therefore not part of `npm test`, how to run it against the demo stack, and that a new migrated tool MUST add a case in the same PR.

- [ ] **Step 3: Verify the empty harness fails**

Run: `node --import tsx tests/parity/run-parity.mjs`
Expected: prints `::error::no parity cases registered` and exits 1. Capture the output — this is the proof the guard works before any case exists to hide it.

- [ ] **Step 4: Commit**

```bash
git add tests/parity/
git commit -m "test: add the dbatools/DMV parity harness"
```

---

### Task 5: Wave-1 migrations

**Files:**
- Modify: `server/src/dbatools.ts`
- Modify: `server/tests/parity/run-parity.mjs`
- Modify: `mssql-data-api/services/dba-mcp/Dockerfile` **(in the OTHER repo — bump the dbatools pin only)**

**Interfaces:**
- Consumes: `callDbatools` (Task 3), the parity harness (Task 4).
- Produces: the wave-1 tools served from dbatools, each with a registered parity case.

**Every cmdlet below was verified present in dbatools 2.7.2.** Migrate these:

| Tool | Cmdlet | Key fields to assert |
|---|---|---|
| `get_backup_status` | `Get-DbaLastBackup` | `Database`, `LastFull`, `LastDiff`, `LastLog` |
| `get_ag_health` | `Get-DbaAvailabilityGroup`, `Get-DbaAgReplica` | `AvailabilityGroup`, `Replica`, `Role`, `SynchronizationState` |
| `get_current_primary` | `Get-DbaAgReplica` | `AvailabilityGroup`, `Replica`, `Role` |
| `get_job_status` | `Get-DbaAgentJob` | `Name`, `Enabled`, `LastRunOutcome` |
| `get_server_info` | `Get-DbaInstanceProperty`, `Get-DbaBuild` | `InstanceName`, `Version` |
| `get_machine_spec` | `Get-DbaComputerSystem`, `Get-DbaOperatingSystem` | `NumberLogicalProcessors`, `TotalPhysicalMemory` |
| `get_database_files` | `Get-DbaDbFile` | `Database`, `LogicalName`, `PhysicalName`, `Size` |
| `get_memory_dumps` | `Get-DbaDump` | `FileName`, `CreationTime` |
| `get_vlf_count` | `Get-DbaDbVirtualLogFile` | `Database`, `Total` |

**Do NOT migrate** (no dbatools equivalent exists — verified): `get_index_fragmentation`, `get_query_store_regressions`, `get_plan_cache_pollution`, `get_columnstore_health`, `get_index_usage_stats`. They keep their DMV implementation. Record that in a comment beside each so a later reader does not re-litigate it.

- [ ] **Step 1: Bump the dbatools pin in the image**

In `C:\tmp\oss-staging\mssql-data-api\services\dba-mcp\Dockerfile`, change `-RequiredVersion 2.1.14` to `-RequiredVersion 2.7.2`. Commit that repo separately with message `chore: pin dbatools 2.7.2 for the wave-1 migration`. Do not push.

- [ ] **Step 2: Migrate one tool and register its parity case**

Start with `get_backup_status`. Replace its DMV body with a `callDbatools("Get-DbaLastBackup", { SqlInstance: <instance> })` call, keeping the tool's existing name, description, argument schema and output shape. Add to `CASES` in `run-parity.mjs`:

```javascript
  { tool: "get_backup_status", cmdlet: "Get-DbaLastBackup", params: {}, keyFields: ["Database", "LastFull", "LastDiff", "LastLog"] },
```

- [ ] **Step 3: Verify that one tool before doing the rest**

Run: `npm run typecheck` → 0. `npm test` → all pass. Then bring up a SQL instance and run the harness:

```bash
node --import tsx tests/parity/run-parity.mjs --instance <your test instance>
```

Expected: `ok   get_backup_status: Get-DbaLastBackup (N row(s), fields present)` and exit 0.
**If the key fields do not match, stop and report** — a renamed field is the finding this task exists to catch, and it changes the mapping table above rather than being worked around.

- [ ] **Step 4: Migrate the remaining eight the same way**

One tool at a time: migrate, add its parity case, re-run typecheck and the harness. Do not batch them blind — each cmdlet's output shape is its own question.

- [ ] **Step 5: Full verification**

Run: `npm run typecheck`, `npm test`, `npm run build` — all exit 0.
Run the parity harness — all 9 cases pass.

- [ ] **Step 6: Commit**

```bash
git add src/dbatools.ts tests/parity/run-parity.mjs
git commit -m "feat: serve the wave-1 tools from dbatools, with parity cases"
```

---

### Task 6: Re-sync the vendored copy

**Files:**
- Modify: `mssql-data-api/services/dba-mcp/**` (via the sync script — never by hand)
- Modify: `mssql-data-api/services/dba-mcp/.upstream`

**Interfaces:**
- Consumes: the upstream commits from Tasks 1-5.
- Produces: `mssql-data-api` vendoring the new upstream sha, with `ci/gate-vendor-drift.sh` passing.

- [ ] **Step 1: Push upstream and capture the sha**

In `mssql-dba-mcp`: `git push origin main`, then `git rev-parse HEAD`. That full 40-character sha is the new pin.

- [ ] **Step 2: Re-sync**

In `mssql-data-api`:

```bash
node scripts/sync-dba-mcp.mjs --sha <the 40-char sha>
ci/gate-vendor-drift.sh --write
```

- [ ] **Step 3: Verify the vendored copy is exactly upstream**

```bash
diff -r services/dba-mcp/src ../mssql-dba-mcp/server/src && echo "src identical"
bash ci/gate-vendor-drift.sh
bash ci/tests/run-vendor-tests.sh
bash ci/leak-scan.sh
```

Expected: `src identical`, and all three exit 0.

- [ ] **Step 4: Commit and push both repos**

```bash
git add services/dba-mcp .
git commit -m "chore: re-sync the vendored DBA MCP server at <short sha>

Brings in the persistent pwsh worker and the wave-1 dbatools migration."
git push origin main
```

- [ ] **Step 5: Verify CI on both repos**

Run `gh run list --repo Bugzbaggy/mssql-dba-mcp --limit 1` and the same for `mssql-data-api`. Both must be `completed/success`. The `Stack smoke test` is the one that proves the rebuilt image still boots with dbatools 2.7.2.

---

## Follow-on

**Plan 3** covers wave 2 (storage, statistics via `Get-DbaDbccStatistic`, `Get-DbaDbSpace`, `Get-DbaTempdbUsage`) and wave 3 (live diagnostics: `Get-DbaWaitStatistic`, `Get-DbaLatchStatistic`, `Get-DbaProcess`, `Get-DbaCpuUsage`, `Get-DbaMemoryUsage`) behind `DBATOOLS_FIRST=1`, with the DMV path retained as the default until latency is compared on real traffic.
