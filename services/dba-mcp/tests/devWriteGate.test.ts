/**
 * Writes reach a dev host only.
 *
 * execute_write is bounded by the caller's SQL grants, but a grant is not a target: the login
 * that may write on the dev host is commonly sysadmin on the production nodes too. So before any
 * statement runs, the write path proves on the SAME connection that the server it reached is the
 * dev host the fleet entry says it is — `region: "dev"` in the fleet file, and
 * SERVERPROPERTY('ServerName') equal to that entry's `computer_name`. Anything else is refused
 * before the statement is sent, whatever the login could do.
 *
 * These tests drive the gate with a fake transaction runner; nothing connects to SQL.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { devWriteName, devWriteRegion, devWriteEntry, devWriteTarget, runDevGatedWrite, DevWriteRefusedError, DEV_WRITE_PROBE_SQL, type WriteRunner } from "../src/devWrite.js";

const DEV = { name: "dev-node1", region: "dev", computer_name: "DEV-NODE1" };
const PROD = { name: "region1-node2", region: "region1", computer_name: "REGION1-NODE2" };

test("devWriteTarget: a dev entry whose server name matches is allowed", () => {
  assert.deepEqual(devWriteTarget(DEV, "DEV-NODE1"), { ok: true });
});

test("devWriteTarget: the name comparison ignores case and surrounding whitespace, nothing else", () => {
  assert.equal(devWriteTarget(DEV, "dev-node1").ok, true);
  assert.equal(devWriteTarget(DEV, "  DEV-NODE1 \r\n").ok, true);
  assert.equal(devWriteTarget({ ...DEV, region: "DEV" }, "DEV-NODE1").ok, true, "the region check is case-insensitive too");
  // A named instance is a different server; an exact match is required.
  assert.equal(devWriteTarget(DEV, "DEV-NODE1\\INST1").ok, false);
  assert.equal(devWriteTarget(DEV, "DEV-NODE10").ok, false);
});

test("devWriteTarget: any region other than dev is refused, even when the names match", () => {
  for (const region of ["region1", "region2", "region3", "region4", "staging", "development", "", undefined]) {
    const r = devWriteTarget({ ...PROD, region }, "REGION1-NODE2");
    assert.equal(r.ok, false, `region ${JSON.stringify(region)} must be refused`);
    if (!r.ok) assert.match(r.reason, /region1-node2/, "the reason names the instance");
    if (!r.ok) assert.match(r.reason, /dev/i, "the reason says writes are dev-only");
  }
});

test("devWriteTarget: a dev entry without computer_name is refused and told what to add", () => {
  const r = devWriteTarget({ name: "dev-node1", region: "dev" }, "DEV-NODE1");
  assert.equal(r.ok, false);
  if (!r.ok) assert.match(r.reason, /computer_name/);
  if (!r.ok) assert.match(r.reason, /DEV-NODE1/, "it quotes the live name so the operator can copy it");
});

test("devWriteTarget: a dev entry whose live server name differs is refused, quoting both names", () => {
  const r = devWriteTarget(DEV, "REGION1-NODE2");
  assert.equal(r.ok, false);
  if (!r.ok) assert.match(r.reason, /REGION1-NODE2/);
  if (!r.ok) assert.match(r.reason, /DEV-NODE1/);
});

test("devWriteTarget: no server name from the probe is refused", () => {
  assert.equal(devWriteTarget(DEV, null).ok, false);
  assert.equal(devWriteTarget(DEV, undefined).ok, false);
  assert.equal(devWriteTarget(DEV, "").ok, false);
  assert.equal(devWriteTarget(DEV, "   ").ok, false);
});

test("the probe asks the server for its own name", () => {
  assert.match(DEV_WRITE_PROBE_SQL, /SERVERPROPERTY\s*\(\s*'ServerName'\s*\)/i);
  assert.match(DEV_WRITE_PROBE_SQL, /\bAS\s+server_name\b/i);
});

// ── runDevGatedWrite with a fake transaction runner ──────────────────────────

type Call = { kind: "query"; text: string } | { kind: "commit" } | { kind: "rollback" };

function fakeRunner(opts: {
  serverName?: string | null;
  probeRows?: Record<string, unknown>[];
  statement?: { rowsAffected: number[]; recordset?: Record<string, unknown>[] } | Error;
}): WriteRunner & { calls: Call[] } {
  const calls: Call[] = [];
  const probeRows = opts.probeRows ?? [{ server_name: opts.serverName ?? "DEV-NODE1" }];
  return {
    calls,
    async query(text: string) {
      calls.push({ kind: "query", text });
      if (text === DEV_WRITE_PROBE_SQL) return { rowsAffected: [], recordset: probeRows };
      const s = opts.statement ?? { rowsAffected: [1] };
      if (s instanceof Error) throw s;
      return s;
    },
    async commit() { calls.push({ kind: "commit" }); },
    async rollback() { calls.push({ kind: "rollback" }); },
  };
}

const STMT = "UPDATE dbo.Foo SET x = 1 WHERE id = 7";
const queries = (r: { calls: Call[] }) => r.calls.filter((c): c is Extract<Call, { kind: "query" }> => c.kind === "query").map((c) => c.text);
const ends = (r: { calls: Call[] }) => r.calls.filter((c) => c.kind !== "query").map((c) => c.kind);

test("runDevGatedWrite: probe first, then the statement, then ROLLBACK on a dry run", async () => {
  const r = fakeRunner({ statement: { rowsAffected: [1, 2], recordset: [{ id: 7 }] } });
  const out = await runDevGatedWrite(DEV, r, STMT, false);
  assert.deepEqual(queries(r), [DEV_WRITE_PROBE_SQL, `SET XACT_ABORT ON;\n${STMT}`]);
  assert.deepEqual(ends(r), ["rollback"]);
  assert.deepEqual(out, { rowsAffected: 3, committed: false, recordset: [{ id: 7 }], server_name: "DEV-NODE1" });
});

test("runDevGatedWrite: COMMIT only when asked", async () => {
  const r = fakeRunner({});
  const out = await runDevGatedWrite(DEV, r, STMT, true);
  assert.deepEqual(ends(r), ["commit"]);
  assert.equal(out.committed, true);
  assert.equal(out.rowsAffected, 1);
});

test("runDevGatedWrite: a non-dev target never sees the statement, and the transaction is rolled back", async () => {
  const r = fakeRunner({ serverName: "REGION1-NODE2" });
  await assert.rejects(runDevGatedWrite(PROD, r, STMT, true), /refused/);
  assert.deepEqual(queries(r), [DEV_WRITE_PROBE_SQL], "only the probe ran");
  assert.deepEqual(ends(r), ["rollback"]);
});

test("runDevGatedWrite: a dev entry reached through the wrong server is refused the same way", async () => {
  const r = fakeRunner({ serverName: "REGION1-NODE2" });
  await assert.rejects(runDevGatedWrite(DEV, r, STMT, true), /REGION1-NODE2/);
  assert.deepEqual(queries(r), [DEV_WRITE_PROBE_SQL]);
  assert.deepEqual(ends(r), ["rollback"]);
});

test("runDevGatedWrite: a probe that returns no name is refused, not treated as dev", async () => {
  const r = fakeRunner({ probeRows: [] });
  await assert.rejects(runDevGatedWrite(DEV, r, STMT, true), /refused/);
  assert.deepEqual(queries(r), [DEV_WRITE_PROBE_SQL]);
  assert.deepEqual(ends(r), ["rollback"]);
});

test("runDevGatedWrite: a failing statement rolls back and rethrows the server's own error", async () => {
  const boom = Object.assign(new Error("Invalid object name 'dbo.Foo'."), { number: 208 });
  const r = fakeRunner({ statement: boom });
  await assert.rejects(runDevGatedWrite(DEV, r, STMT, true), (e: unknown) => e === boom);
  assert.deepEqual(ends(r), ["rollback"]);
});

test("runDevGatedWrite: a probe that throws rolls back and rethrows, with nothing else sent", async () => {
  const boom = new Error("Login failed for user");
  const r = fakeRunner({});
  r.query = async (text: string) => { r.calls.push({ kind: "query", text }); throw boom; };
  await assert.rejects(runDevGatedWrite(DEV, r, STMT, true), (e: unknown) => e === boom);
  assert.deepEqual(queries(r), [DEV_WRITE_PROBE_SQL]);
  assert.deepEqual(ends(r), ["rollback"]);
});

// ── The connection-free half of the gate, so a non-dev target is refused before any connection ──

test("devWriteEntry: judges the fleet entry alone — region and computer_name — without a server name", () => {
  assert.deepEqual(devWriteEntry(DEV), { ok: true });
  const prod = devWriteEntry(PROD);
  assert.equal(prod.ok, false);
  if (!prod.ok) assert.match(prod.reason, /region1-node2.*region "region1"/);
  const bare = devWriteEntry({ name: "dev-node1", region: "dev" });
  assert.equal(bare.ok, false);
  if (!bare.ok) assert.match(bare.reason, /computer_name/);
});

test("devWriteRegion: judges the region alone, so a dev entry without computer_name may still be connected to", () => {
  assert.deepEqual(devWriteRegion({ name: "dev-node1", region: "dev" }), { ok: true });
  assert.deepEqual(devWriteRegion(DEV), { ok: true });
  const listener = devWriteRegion({ name: "region1-listener", region: "region1", computer_name: "X" });
  assert.equal(listener.ok, false);
  if (!listener.ok) assert.match(listener.reason, /region1-listener.*region "region1"/);
  // The same words devWriteEntry uses for the region, so an operator sees one message for one cause.
  assert.deepEqual(devWriteRegion({ name: "region3-node1", region: "region3" }), devWriteEntry({ name: "region3-node1", region: "region3" }));
});

test("devWriteName: a \"<region>-primary\" alias is refused before anything is resolved", () => {
  assert.deepEqual(devWriteName("dev-node1"), { ok: true });
  for (const alias of ["region1-primary", "dev-primary", "REGION4-PRIMARY"]) {
    const r = devWriteName(alias);
    assert.equal(r.ok, false, alias);
    if (!r.ok) assert.match(r.reason, /refused/);
    if (!r.ok) assert.match(r.reason, /dev-node1/, "it says what to name instead");
  }
});

test("devWriteEntry and devWriteTarget refuse a non-dev entry for the same reason", () => {
  const target = { name: "region3-node1", region: "region3", computer_name: "REGION3-NODE1" };
  assert.deepEqual(devWriteEntry(target), devWriteTarget(target, "REGION3-NODE1"));
});

// ── Refusals are a distinct error type, so callers can tell "refused, nothing ran" from a server error ──

test("a refusal is a DevWriteRefusedError; a server error is not", async () => {
  for (const [target, serverName] of [
    [PROD, "REGION1-NODE2"],
    [DEV, "REGION1-NODE2"],
    [{ name: "dev-node1", region: "dev" }, "DEV-NODE1"],
  ] as const) {
    await assert.rejects(runDevGatedWrite(target, fakeRunner({ serverName }), STMT, true), (e: unknown) =>
      e instanceof DevWriteRefusedError && e.name === "DevWriteRefusedError" && /refused/.test(e.message));
  }
  const boom = new Error("Invalid object name 'dbo.Foo'.");
  await assert.rejects(runDevGatedWrite(DEV, fakeRunner({ statement: boom }), STMT, true), (e: unknown) => !(e instanceof DevWriteRefusedError));
});

// ── onAccepted: the moment the gate has passed and the statement is about to run on this connection ──

test("runDevGatedWrite: onAccepted fires once, after the probe and before the statement", async () => {
  const r = fakeRunner({});
  const seen: string[] = [];
  const origQuery = r.query.bind(r);
  r.query = async (text: string) => { seen.push(text === DEV_WRITE_PROBE_SQL ? "probe" : "statement"); return origQuery(text); };
  await runDevGatedWrite(DEV, r, STMT, false, { onAccepted: () => { seen.push("accepted"); } });
  assert.deepEqual(seen, ["probe", "accepted", "statement"]);
});

test("runDevGatedWrite: onAccepted never fires on a refusal", async () => {
  let fired = 0;
  await assert.rejects(runDevGatedWrite(DEV, fakeRunner({ serverName: "REGION1-NODE2" }), STMT, true, { onAccepted: () => { fired++; } }), DevWriteRefusedError);
  assert.equal(fired, 0);
});

test("runDevGatedWrite: an onAccepted that throws rolls back and nothing is sent", async () => {
  const boom = new Error("hook failed");
  const r = fakeRunner({});
  await assert.rejects(runDevGatedWrite(DEV, r, STMT, true, { onAccepted: () => { throw boom; } }), (e: unknown) => e === boom);
  assert.deepEqual(queries(r), [DEV_WRITE_PROBE_SQL]);
  assert.deepEqual(ends(r), ["rollback"]);
});
