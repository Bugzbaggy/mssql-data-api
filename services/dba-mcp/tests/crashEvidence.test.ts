/**
 * crashEvidence.ts — the SQLDump reader the HTTP transport depends on, and the regex guard it
 * shares with the ERRORLOG reader (tests/errorLogReader.test.ts).
 *
 * Under the least-privilege svc_sqldiag dump text is read with EXECUTE on one signed procedure and
 * no bulk rights. What is pinned here is what a regression would break silently: the SQL sent,
 * which path a login without bulk rights takes, and what is refused before any SQL is built.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  safeRegex, assertDumpTextFile, readDump, listDumps, matchingLines, simplifyForTest, type QueryFn,
} from "../src/crashEvidence.js";

type Call = { sql: string; maxRows: number };
function fakeQuery(respond: (sql: string) => Record<string, unknown>[] | Error): { q: QueryFn; calls: Call[] } {
  const calls: Call[] = [];
  const q: QueryFn = async (_instance, sql, maxRows) => {
    calls.push({ sql, maxRows });
    const r = respond(sql);
    if (r instanceof Error) throw r;
    return { rows: r };
  };
  return { q, calls };
}
const sqlError = (number: number, message: string) => Object.assign(new Error(message), { number });
const isCapsProbe = (sql: string) => sql.includes("OBJECT_ID(N'master.dbo.sp_ReadSqlDumpFile', N'P')");

// ── safeRegex ────────────────────────────────────────────────────────────────

test("safeRegex accepts the patterns the runbooks actually use, case-insensitively", () => {
  for (const p of ["Stack Dump|access violation|c0000005", "Exception (Address|Code)|pdb=|Module load completed", "2026/06/08-18:4[0-9]"]) {
    assert.ok(safeRegex(p) instanceof RegExp, p);
  }
  assert.ok(safeRegex("stack dump").test("Stack Dump being sent to C:\\x\\SQLDump0001.txt"));
});

test("safeRegex refuses nested quantifiers, overlong and invalid patterns", () => {
  for (const p of ["(a+)+$", "(.*)*", "(\\w+\\s?)*", "(a{2,})+", "(?:x+)+y"]) {
    assert.throws(() => safeRegex(p), /quantified group/, p);
  }
  assert.throws(() => safeRegex("a".repeat(257)), /256 characters/);
  assert.throws(() => safeRegex("("), /not a valid regular expression/);
});

test("matchingLines returns the lines a pattern matches, case-insensitively", () => {
  assert.deepEqual(matchingLines("stack dump|c0000005", ["Stack Dump being sent", "nothing", "exception c0000005"]), [0, 2]);
});

test("a pattern the static check misses is stopped by the time budget instead of stalling the server", () => {
  // Each passes safeRegex and backtracks without end on its line: overlapping alternation, a group
  // nested inside the quantified one, and stacked quantifiers with no group at all.
  for (const [p, line] of [["(0|0)*x", "0".repeat(40)], ["((\\w+)\\s?)+$", "a".repeat(40) + "!"], ["a*".repeat(11) + "b", "a".repeat(200)]]) {
    assert.ok(safeRegex(p) instanceof RegExp, `${p} passes the static check`);
    const t0 = Date.now();
    assert.throws(() => matchingLines(p, [line], 200), /did not finish within 0\.2 s/, p);
    assert.ok(Date.now() - t0 < 2_000, `${p} was stopped only after ${Date.now() - t0} ms`);
  }
});

test("simplifyForTest drops only edge .* that decide nothing on one line", () => {
  assert.equal(simplifyForTest(".*deadlock.*"), "deadlock");
  assert.equal(simplifyForTest("^.*long.*I/O"), "long.*I/O", "inner .* is kept");
  assert.equal(simplifyForTest("victim.*$"), "victim");
  assert.equal(simplifyForTest("a\\.*"), "a\\.*", "an escaped dot is a literal, kept");
  assert.equal(simplifyForTest(".*?x"), ".*?x", "a lazy .*? is kept");
  assert.equal(simplifyForTest(".*"), ".*", "nothing left to match on: unchanged");
});

test("a leading .* over a full ERRORLOG window no longer spends the budget", () => {
  // 50,000 lines is the scan window; without simplifyForTest, `.*deadlock.*` took about a second here.
  const lines = Array.from({ length: 50_000 }, (_, i) =>
    `2026-01-01 10:00:00.00 spid${i % 900}s ` + (i % 997 === 0 ? "deadlock victim chosen " : "") + "x".repeat(130));
  // The reference answer is not what is under test, so it gets a generous budget, and its own time
  // sets the bar: a loaded machine slows both alike, while an unsimplified leading .* costs tens of
  // times the plain literal (V8 retries it from every position of every line).
  const t0 = Date.now();
  const plain = matchingLines("deadlock", lines, 20_000);
  const budget = Math.max(200, 4 * (Date.now() - t0));
  assert.ok(plain.length > 0);
  assert.deepEqual(matchingLines(".*DEADLOCK.*", lines, budget), plain);
});

// ── SQLDump<NNNN>.txt ────────────────────────────────────────────────────────

test("assertDumpTextFile accepts a bare SQLDump<NNNN>.txt and nothing that could be a path", () => {
  assert.equal(assertDumpTextFile("SQLDump0004.txt"), "SQLDump0004.txt");
  assert.equal(assertDumpTextFile("sqldump12345.TXT"), "sqldump12345.TXT");
  assert.throws(() => assertDumpTextFile(undefined), /requires `file`/);
  // Anything path-shaped is refused AS a path, by the separator check — not merely because it also
  // fails the name pattern. Two independent layers; each must hold on its own.
  for (const f of ["..\\..\\Windows\\win.ini", "a/SQLDump0001.txt", "SQLDump0001\\x.txt", "C:SQLDump0001.txt"]) {
    assert.throws(() => assertDumpTextFile(f), /Invalid file name/, f);
  }
  for (const f of ["SQLDump0001.mdmp", "SQLDump0001.log", "SQLDump0001.txt'; SELECT 1 --", "ERRORLOG"]) {
    assert.throws(() => assertDumpTextFile(f), /only reads SQLDump<NNNN>\.txt/, f);
  }
});

test("readDump uses the signed reader when it exists, with ROWCOUNT reset, and never OPENROWSET", async () => {
  const { q, calls } = fakeQuery((sql) =>
    isCapsProbe(sql) ? [{ reader_id: 123, can_bulk: 0 }]
      : sql.includes("sp_ReadSqlDumpFile @FileName") ? [{ body: "line one\r\nException Address = 0x1\r\npdb=SqlDK.pdb" }]
      : new Error(`unexpected SQL: ${sql}`));
  const r = await readDump(q, "region3-node1", { file: "SQLDump0004.txt", contains: "Exception|pdb=" });
  assert.equal(calls.length, 2);
  assert.equal(calls[1].sql, "SET ROWCOUNT 0;\nEXEC master.dbo.sp_ReadSqlDumpFile @FileName = N'SQLDump0004.txt';");
  assert.match(r.channel, /signed-reader/);
  assert.deepEqual(r.lines, ["Exception Address = 0x1", "pdb=SqlDK.pdb"]);
  assert.ok(!calls.some((c) => /OPENROWSET/i.test(c.sql)));
});

test("readDump falls back to OPENROWSET only for a login that holds bulk rights", async () => {
  const { q, calls } = fakeQuery((sql) =>
    isCapsProbe(sql) ? [{ reader_id: null, can_bulk: 1 }]
      : /SELECT TOP 1 d\.dir AS log_directory/.test(sql) ? [{ log_directory: "C:\\Program Files\\Microsoft SQL Server\\MSSQL15.MSSQLSERVER\\MSSQL\\Log" }]
      : /OPENROWSET\(BULK N'/.test(sql) ? [{ body: "a\nb" }]
      : new Error(`unexpected SQL: ${sql}`));
  const r = await readDump(q, "region1-node1", { file: "SQLDump0004.txt" });
  assert.equal(r.channel, "sql:openrowset");
  assert.equal(r.file, "C:\\Program Files\\Microsoft SQL Server\\MSSQL15.MSSQLSERVER\\MSSQL\\Log\\SQLDump0004.txt");
  assert.deepEqual(r.lines, ["a", "b"]);
  assert.equal(calls.length, 3);
});

test("readDump joins a Linux dump directory with '/', not '\\\\'", async () => {
  const { q } = fakeQuery((sql) =>
    isCapsProbe(sql) ? [{ reader_id: null, can_bulk: 1 }]
      : /SELECT TOP 1 d\.dir AS log_directory/.test(sql) ? [{ log_directory: "/var/opt/mssql/log" }]
      : /OPENROWSET\(BULK N'/.test(sql) ? [{ body: "x" }]
      : new Error(`unexpected SQL: ${sql}`));
  assert.equal((await readDump(q, "region1-node1", { file: "SQLDump0004.txt" })).file, "/var/opt/mssql/log/SQLDump0004.txt");
});

test("readDump tells a login without bulk rights that the signed reader is missing — and runs nothing else", async () => {
  const { q, calls } = fakeQuery((sql) => (isCapsProbe(sql) ? [{ reader_id: null, can_bulk: 0 }] : new Error("must not run")));
  await assert.rejects(readDump(q, "region4-node1", { file: "SQLDump0004.txt" }), /05-signed-dump-reader\.sql.*not installed/s);
  assert.equal(calls.length, 1);
});

test("readDump reports the reader's not-found to a login without bulk rights, and retries with them", async () => {
  const notFound = sqlError(51002, "No such dump file in any of this instance's dump directories.");
  const without = fakeQuery((sql) => (isCapsProbe(sql) ? [{ reader_id: 7, can_bulk: 0 }] : notFound));
  await assert.rejects(readDump(without.q, "region1-node2", { file: "SQLDump0004.txt" }), /No such dump file/);
  assert.equal(without.calls.length, 2);

  const withBulk = fakeQuery((sql) =>
    isCapsProbe(sql) ? [{ reader_id: 7, can_bulk: 1 }]
      : sql.includes("sp_ReadSqlDumpFile @FileName") ? notFound
      : /SELECT TOP 1 d\.dir/.test(sql) ? [{ log_directory: "D:\\SQLLogs" }]
      : /OPENROWSET/.test(sql) ? [{ body: "x" }]
      : new Error(`unexpected SQL: ${sql}`));
  const r = await readDump(withBulk.q, "region1-node2", { file: "SQLDump0004.txt" });
  assert.equal(r.channel, "sql:openrowset");
});

test("readDump names the unsigned-procedure case instead of passing on a bulk-permission error", async () => {
  const { q } = fakeQuery((sql) => (isCapsProbe(sql) ? [{ reader_id: 7, can_bulk: 0 }]
    : sqlError(4834, "You do not have permission to use the bulk load statement.")));
  await assert.rejects(readDump(q, "region2-node1", { file: "SQLDump0004.txt" }), /NOT SIGNED.*step 3/s);
});

test("readDump tells a signed-but-refused file open (4860) apart from a missing signature (4834)", async () => {
  const { q } = fakeQuery((sql) => (isCapsProbe(sql) ? [{ reader_id: 7, can_bulk: 0 }]
    : sqlError(4860, "Cannot bulk load. The file \"/var/opt/mssql/log/SQLDump0004.txt\" does not exist or you don't have file access rights.")));
  await assert.rejects(readDump(q, "region2-node1", { file: "SQLDump0004.txt" }), (e: Error) => {
    assert.match(e.message, /passed the permission check/);
    assert.match(e.message, /4860/);
    assert.doesNotMatch(e.message, /NOT SIGNED/);
    return true;
  });
});

test("readDump refuses a bad file name before any SQL runs", async () => {
  const { q, calls } = fakeQuery(() => []);
  await assert.rejects(readDump(q, "region1-node1", { file: "..\\..\\Windows\\win.ini" }), /Invalid file name/);
  await assert.rejects(readDump(q, "region1-node1", { file: "SQLDump0001.txt", contains: "(.*)*" }), /quantified group/);
  assert.equal(calls.length, 0);
});

test("listDumps searches every candidate dump directory, not just the ERRORLOG's", async () => {
  const { q, calls } = fakeQuery(() => [
    { log_directory: "C:\\Program Files\\Microsoft SQL Server\\MSSQL15.MSSQLSERVER\\MSSQL\\Log", Name: "SQLDump0002.txt", Length: 10, LastWriteTimeUtc: "2026-01-01T09:25:40" },
  ]);
  const r = await listDumps(q, "region1-node1");
  assert.match(calls[0].sql, /sys\.dm_os_enumerate_filesystem\(d\.dir,'SQLDump\*'\)/);
  assert.match(calls[0].sql, /MSSQL\*/, "sibling MSSQL<nn> trees are where an upgraded instance keeps its dumps");
  assert.equal(r.dump_count, 1);
  assert.match(String(r.log_directory), /MSSQL15/);
});
