/**
 * read_error_log over the SQL connection (errorLogReader.ts). No SQL here: the batch is pinned by
 * its text, and readErrorLog runs against an injected QueryFn.
 *
 * Why the tool is not Get-DbaErrorLog: that cmdlet materializes the whole log in PowerShell before
 * filtering, so its cost is the file's size, and a log of a few tens of MB ran past the 120 s
 * budget. What a regression here would break silently: which matcher a pattern gets (SQL Server
 * over the whole file, or this process over a window), the size guard running before the read, the
 * TOP that keeps applyRowLimit off the INSERT … EXEC, and the path split on either separator.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  isLiteral, planFilter, rowsToFetch, errorLogBatch, shapeErrorLog, readErrorLog,
  ERRORLOG_SCAN_ROWS, ERRORLOG_MAX_MB, ERRORLOG_MAX_TERMS,
  type QueryFn,
} from "../src/errorLogReader.js";
import { applyRowLimit } from "../src/connectionManager.js";

const row = (LogDate: string, Text: string, ProcessInfo = "Server") => ({ LogDate, ProcessInfo, Text, FileMb: 12.5 });

test("isLiteral is true only for non-empty text with no regex metacharacter", () => {
  assert.equal(isLiteral("Stack Dump"), true);
  assert.equal(isLiteral("c0000005"), true);
  assert.equal(isLiteral(""), false, "an empty term is not something to hand to SQL Server");
  assert.equal(isLiteral("Stack|Dump"), false);
  assert.equal(isLiteral("a.b"), false);
});

test("a plain text is one literal, matched by SQL Server across the whole file", () => {
  assert.deepEqual(planFilter("Stack Dump"), { mode: "literal", terms: ["Stack Dump"] });
  assert.deepEqual(planFilter(undefined), { mode: "none" });
  assert.deepEqual(planFilter(""), { mode: "none" });
});

test("an alternation of plain texts becomes one engine search per term, duplicates dropped", () => {
  const plan = planFilter("Login timeout|Long Sync IO|Login timeout");
  assert.deepEqual(plan, { mode: "literal", terms: ["Login timeout", "Long Sync IO"] });
  const sql = errorLogBatch(0, plan, { top: 10, maxMb: ERRORLOG_MAX_MB });
  assert.equal((sql.match(/INSERT @t EXEC master\.sys\.xp_readerrorlog 0, 1, N'/g) ?? []).length, 2);
  assert.match(sql, /N'Login timeout', NULL, @start/);
  assert.match(sql, /N'Long Sync IO', NULL, @start/);
});

test("anything else is a regex, matched here over the newest lines", () => {
  assert.deepEqual(planFilter("Stack Dump.*0x"), { mode: "regex", pattern: "Stack Dump.*0x" });
  assert.equal(planFilter("a|").mode, "regex", "an empty alternative is not a literal");
  const many = Array.from({ length: ERRORLOG_MAX_TERMS + 1 }, (_, i) => `term${i}`).join("|");
  assert.equal(planFilter(many).mode, "regex", "past the term limit it is not split");
  assert.equal(errorLogBatch(0, planFilter("Stack Dump.*0x"), { top: 5, maxMb: 1 }).match(/xp_readerrorlog 0, 1, NULL, NULL/g)?.length, 1);
});

test("a dangerous or oversized pattern is refused before any SQL is built", () => {
  assert.throws(() => planFilter("(a+)+$"), /backtrack exponentially/);
  assert.throws(() => planFilter("x".repeat(257)), /256 characters/);
  assert.throws(() => planFilter("Stack Dump|(unclosed"), /not a valid regular expression/);
});

test("quotes are escaped, hours are bounded inside SQL Server, archives are addressed by number", () => {
  const sql = errorLogBatch(2, planFilter("it's"), { hours: 24, top: 11, maxMb: ERRORLOG_MAX_MB });
  assert.match(sql, /N'it''s'/);
  assert.match(sql, /DECLARE @start datetime = DATEADD\(HOUR, -24, GETDATE\(\)\);/);
  assert.match(sql, /xp_readerrorlog 2, 1,/);
  assert.match(sql, /DECLARE @file nvarchar\(260\) = @base \+ N'\.2';/);
  assert.match(sql, /sys\.dm_os_enumerate_filesystem\(@dir, @base \+ N'\*'\) WHERE is_directory = 0 AND file_or_directory_name = @file\)/);
  const current = errorLogBatch(0, planFilter(undefined), { top: 1, maxMb: 1 });
  assert.match(current, /DECLARE @file nvarchar\(260\) = @base;/);
  assert.match(current, /DECLARE @start datetime = NULL;/);
});

test("the log path is split on either separator, and an unsplittable path skips the probe", () => {
  const sql = errorLogBatch(0, planFilter(undefined), { top: 1, maxMb: 1 });
  // NB the TS source writes '\\' to emit N'\'. A single backslash would emit N'' and find nothing.
  assert.match(sql, /CHARINDEX\(CASE WHEN CHARINDEX\(N'\\', @log\) > 0 THEN N'\\' ELSE N'\/' END, REVERSE\(@log\)\)/);
  assert.match(sql, /DECLARE @dir nvarchar\(512\) = CASE WHEN @cut > 1 THEN LEFT\(@log, LEN\(@log\) - @cut\) END;/);
  assert.match(sql, /DECLARE @base nvarchar\(260\) = CASE WHEN @cut > 1 THEN RIGHT\(@log, @cut - 1\) END;/);
  assert.match(sql, /IF @dir IS NOT NULL\n {2}SET @mb = /, "no directory, no probe: @mb stays NULL and the guard passes");
});

test("the size guard runs before the read, and TOP keeps SET ROWCOUNT away", () => {
  const sql = errorLogBatch(0, planFilter(undefined), { top: 501, maxMb: 2048 });
  assert.ok(sql.indexOf("THROW 50001") > 0 && sql.indexOf("THROW 50001") < sql.indexOf("xp_readerrorlog"));
  assert.match(sql, /IF @mb > 2048\nBEGIN/);
  assert.match(sql, /SELECT TOP \(501\) /);
  // If this ever fails, queryInstance caps the INSERT … EXEC itself and the reader loses lines silently.
  assert.equal(applyRowLimit(sql, 501), sql);
  const multi = errorLogBatch(0, planFilter("a|b|c"), { top: 33, maxMb: 2048 });
  assert.equal(applyRowLimit(multi, 33), multi);
});

test("log_number and hours are range-checked", () => {
  const p = planFilter(undefined);
  for (const n of [-1, 100, 1.5]) assert.throws(() => errorLogBatch(n, p, { top: 1, maxMb: 1 }), /log_number/, String(n));
  for (const h of [0, 1.5, 8761]) assert.throws(() => errorLogBatch(0, p, { hours: h, top: 1, maxMb: 1 }), /hours/, String(h));
});

test("rows fetched: max_rows + 1 for a literal (per term), the scan window for a regex", () => {
  assert.equal(rowsToFetch(planFilter(undefined), 500, ERRORLOG_SCAN_ROWS), 501);
  assert.equal(rowsToFetch(planFilter("a|b|c"), 10, ERRORLOG_SCAN_ROWS), 33);
  assert.equal(rowsToFetch(planFilter("a.*b"), 10, ERRORLOG_SCAN_ROWS), ERRORLOG_SCAN_ROWS + 1);
});

test("shaping: a line found by two terms is returned once; more_rows says the cap was hit", () => {
  const plan = planFilter("Login timeout|Long Sync IO");
  const both = row("2026-01-01T10:00:02.000", "Login timeout ... Long Sync IO");
  const shaped = shapeErrorLog([both, both, row("2026-01-01T10:00:01.000", "Long Sync IO")], plan, 1, 100);
  assert.equal(shaped.returned_rows, 1);
  assert.equal(shaped.more_rows, true);
  assert.equal(shaped.rows[0].Text, both.Text);
  assert.ok(!("scan_truncated" in shaped), "a literal has no scan window to report");
});

test("shaping: a regex filters case-insensitively and reports how far back it looked", () => {
  const plan = planFilter("long sync io.*Scheduler [0-9]+");
  const rows = [row("t3", "Long Sync IO: Scheduler 4 had 1 Sync IOs"), row("t2", "noise"), row("t1", "Long Sync IO: Scheduler 1 had 1 Sync IOs")];
  const shaped = shapeErrorLog(rows, plan, 500, 2);
  assert.equal(shaped.scanned_rows, 2);
  assert.equal(shaped.scan_truncated, true, "one row past the window means the file was not read to its start");
  assert.equal(shaped.oldest_line_examined, "t2");
  assert.equal(shaped.matched_rows, 1, "t1 matches but is past the window");
  assert.equal(shaped.more_rows, false);
});

test("readErrorLog sends one batch, fetches the planned row count, and reports the plan", async () => {
  const calls: { sql: string; maxRows: number; noteTruncation?: boolean }[] = [];
  const query: QueryFn = async (_i, sql, maxRows, opts) => {
    calls.push({ sql, maxRows, noteTruncation: opts?.noteTruncation });
    return { rows: [row("2026-01-01T10:00:00.000", "Network error code 0x2746 ... login timeout")] };
  };
  const out = await readErrorLog(query, "region1-node1", { contains: "login timeout", hours: 2, max_rows: 50 });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].maxRows, 51);
  assert.equal(calls[0].noteTruncation, false, "the result reports its own cap (more_rows)");
  assert.match(calls[0].sql, /DATEADD\(HOUR, -2, GETDATE\(\)\)/);
  assert.equal(out.channel, "sql:xp_readerrorlog");
  assert.equal(out.filter_mode, "literal, whole log, matched by SQL Server");
  assert.equal(out.log_file_mb, 12.5);
  assert.equal(out.returned_rows, 1);
  assert.equal(out.more_rows, false);
});

test("readErrorLog keeps a regex for itself and names the window", async () => {
  const calls: string[] = [];
  const query: QueryFn = async (_i, sql) => { calls.push(sql); return { rows: [row("2026-01-01T10:00:00", "Stack Dump being sent")] }; };
  const rx = await readErrorLog(query, "region2-node1", { contains: "Stack Dump|c0000005.", log_number: 2 });
  assert.match(calls[0], /xp_readerrorlog 2, 1, NULL, NULL, @start/);
  assert.equal(rx.filter_mode, `regex, newest ${ERRORLOG_SCAN_ROWS} lines`);
  assert.equal(rx.matched_rows, 1);
});

test("readErrorLog refuses a catastrophic pattern before any SQL runs", async () => {
  let calls = 0;
  await assert.rejects(readErrorLog(async () => { calls++; return { rows: [] }; }, "region1-node1", { contains: "(a+)+$" }), /quantified group/);
  assert.equal(calls, 0);
});

test("readErrorLog refuses, with the reason, a pattern that exhausts the time budget", async () => {
  const query: QueryFn = async () => ({ rows: [row("2026-01-01T10:00:00", "0".repeat(40))] });
  await assert.rejects(readErrorLog(query, "region1-node1", { contains: "(0|0)*x" }), /did not finish within 2 s over 1 line\(s\): the pattern backtracks/);
});

test("the size guard's refusal comes back as the error, not as an empty log", async () => {
  const refused = Object.assign(new Error("ERRORLOG.3 is 3072.0 MB, over the 2048 MB this tool reads."), { number: 50001 });
  await assert.rejects(readErrorLog(async () => { throw refused; }, "region1-node2", { log_number: 3 }), /over the 2048 MB this tool reads/);
});

test("an empty result still answers, with no file size", async () => {
  const out = await readErrorLog(async () => ({ rows: [] }), "dev-node1", {});
  assert.equal(out.log_file_mb, null);
  assert.equal(out.returned_rows, 0);
  assert.equal(out.more_rows, false);
  assert.equal(out.filter_mode, "none");
});
