/**
 * selftest.ts — the deployment acceptance test (`node dist/index.js selftest`).
 *
 * What is pinned is the verdict for each thing a deployment can get wrong: a privileged login,
 * a missing grant, a login that can read customer data, an unreadable ERRORLOG. A test that cannot
 * be exercised on a node (no dump there to read, a database not readable here) must say
 * UNMEASURED — never PASS.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { selftestInstance, selftestTargets, customerProbe, type SelftestCheck } from "../src/selftest.js";
import type { QueryFn } from "../src/crashEvidence.js";

const PROBE = { table: "msg.MessageLog", preferDb: "AppDb_Data" };
type Over = {
  login?: string; sysadmin?: number; grants?: string[]; sessions?: number;
  errorlog?: Error; dumps?: string[]; custData?: "denied" | "readable" | "not-accessible"; custDb?: string | null; connect?: Error;
  extraPerms?: string[]; extraRoles?: string[]; extraDbRoles?: string[]; allowlist?: Error; jobTables?: Error;
};
/** Every customer-data probe the fake was sent, so a test can see which table was read. */
let probed: string[] = [];
function fake(o: Over = {}): QueryFn {
  probed = [];
  return async (_i, sql) => {
    if (sql.includes("SUSER_SNAME()")) {
      if (o.connect) throw o.connect;
      return { rows: [{ server_name: "DEV-NODE1", login: o.login ?? "svc_sqldiag", is_sysadmin: o.sysadmin ?? 0, is_securityadmin: 0 }] };
    }
    // Before fn_my_permissions: the allowlist query reads that too.
    if (sql.includes("fn_builtin_permissions")) {
      if (o.allowlist) throw o.allowlist;
      return { rows: (o.extraPerms ?? []).map((p) => ({ permission_name: p })) };
    }
    if (sql.includes("server_role_members")) return { rows: (o.extraRoles ?? []).map((n) => ({ name: n })) };
    if (sql.includes("database_role_members")) return { rows: (o.extraDbRoles ?? []).map((n) => ({ role: n })) };
    if (sql.includes("fn_my_permissions")) {
      return { rows: (o.grants ?? ["CONNECT SQL", "VIEW SERVER STATE", "VIEW ANY DEFINITION", "VIEW ANY DATABASE", "CONNECT ANY DATABASE"]).map((p) => ({ permission_name: p })) };
    }
    if (sql.includes("sys.dm_exec_sessions")) return { rows: [{ n: o.sessions ?? 42 }] };
    if (sql.includes("msdb.dbo.sysjobhistory")) {
      if (o.jobTables) throw o.jobTables;
      return { rows: [{ j: 1, h: 1, a: 1 }] };
    }
    if (sql.includes("xp_readerrorlog")) {
      if (o.errorlog) throw o.errorlog;
      return { rows: [{ LogDate: "2026-01-01T10:00:00", ProcessInfo: "Server", Text: "SQL Server is starting" }] };
    }
    if (sql.includes("sys.dm_os_enumerate_filesystem(d.dir,'SQLDump*')")) {
      return { rows: (o.dumps ?? []).map((n) => ({ log_directory: "C:\\x\\MSSQL\\Log", Name: n, Length: 10, LastWriteTimeUtc: "2026-01-01T17:52:19" })) };
    }
    if (sql.includes("SELECT @errDir AS log_directory")) return { rows: [{ log_directory: "D:\\MSSQL\\Data\\System" }] };
    if (sql.includes("OBJECT_ID(N'master.dbo.sp_ReadSqlDumpFile', N'P')")) return { rows: [{ reader_id: 7, can_bulk: 0 }] };
    if (sql.includes("sp_ReadSqlDumpFile @FileName")) return { rows: [{ body: "Exception Address = 0x1\nModule load completed" }] };
    if (sql.includes("OBJECT_ID(QUOTENAME(name) + N'.msg.MessageLog', N'U')")) return { rows: o.custDb === null ? [] : [{ name: o.custDb ?? "AppDb_Data" }] };
    if (sql.includes("].msg.MessageLog")) {
      probed.push(sql);
      if ((o.custData ?? "denied") === "readable") return { rows: [{ x: 1 }] };
      throw Object.assign(new Error("denied or not accessible"), { number: (o.custData ?? "denied") === "denied" ? 229 : 978 });
    }
    throw new Error(`unexpected SQL: ${sql.slice(0, 80)}`);
  };
}
const verdict = (rs: SelftestCheck[], check: string) => rs.find((r) => r.check.startsWith(check))?.result;
const run = (o: Over, instance = "dev-node1") => selftestInstance(fake(o), instance, "svc_sqldiag", PROBE);

test("a correctly provisioned node passes every check it can exercise", async () => {
  const rs = await run({ dumps: ["SQLDump0009.txt", "SQLDump0009.mdmp"] });
  assert.deepEqual(rs.filter((r) => r.result !== "PASS"), []);
  assert.equal(rs.length, 14);
});

test("job tables the login cannot read fail the check get_job_status depends on", async () => {
  // SQLAgentReaderRole alone leaves a direct SELECT on these at Msg 229.
  const denied = Object.assign(new Error("The SELECT permission was denied on the object 'sysjobs'"), { number: 229 });
  assert.equal(verdict(await run({ jobTables: denied }), "Agent job tables readable"), "FAIL");
});

test("no dump on the node is UNMEASURED, not a pass", async () => {
  const rs = await run({ dumps: [] });
  assert.equal(verdict(rs, "dump text"), "UNMEASURED");
  assert.equal(rs.filter((r) => r.result === "FAIL").length, 0);
});

test("a privileged or wrong login fails", async () => {
  assert.equal(verdict(await run({ sysadmin: 1 }), "not sysadmin"), "FAIL");
  assert.equal(verdict(await run({ login: "dba_alice" }), "login is the deployed"), "FAIL");
});

test("a missing grant, or an escalation grant, fails", async () => {
  assert.equal(verdict(await run({ grants: ["VIEW SERVER STATE"] }), "holds the four"), "FAIL");
  const bulk = ["VIEW SERVER STATE", "VIEW ANY DEFINITION", "VIEW ANY DATABASE", "CONNECT ANY DATABASE", "ADMINISTER BULK OPERATIONS"];
  assert.equal(verdict(await run({ grants: bulk }), "holds no CONTROL"), "FAIL");
});

test("anything beyond the design fails and is named: a permission, a server role, a database role", async () => {
  const rs = await run({ extraPerms: ["IMPERSONATE ANY LOGIN"], extraRoles: ["processadmin"], extraDbRoles: ["msdb: db_owner"] });
  const detail = (check: string) => rs.find((r) => r.check.startsWith(check))?.detail;
  assert.equal(verdict(rs, "holds no server permission beyond"), "FAIL");
  assert.equal(detail("holds no server permission beyond"), "IMPERSONATE ANY LOGIN");
  assert.equal(verdict(rs, "is in no server role"), "FAIL");
  assert.equal(detail("is in no server role"), "processadmin");
  assert.equal(verdict(rs, "holds no master/msdb role"), "FAIL");
  assert.equal(detail("holds no master/msdb role"), "msdb: db_owner");
});

test("an allowlist that cannot be evaluated fails rather than passing", async () => {
  const rs = await run({ allowlist: new Error("Invalid object name 'sys.fn_builtin_permissions'") });
  assert.equal(verdict(rs, "holds no server permission beyond"), "FAIL");
});

test("a DMV that sees only its own session means VIEW SERVER STATE is not in effect", async () => {
  assert.equal(verdict(await run({ sessions: 1 }), "DMVs see"), "FAIL");
});

test("readable customer data fails; an inaccessible database is UNMEASURED; denial passes", async () => {
  assert.equal(verdict(await run({ custData: "readable" }, "region1-node1"), "cannot read"), "FAIL");
  assert.equal(verdict(await run({ custData: "not-accessible" }, "region1-node1"), "cannot read"), "UNMEASURED");
  assert.equal(verdict(await run({ custDb: null }, "region1-node1"), "cannot read"), "UNMEASURED");
  assert.equal(verdict(await run({}, "region1-node1"), "cannot read"), "PASS");
  assert.match(probed[0] ?? "", /FROM \[AppDb_Data\]\.msg\.MessageLog;/);
});

test("the probe reads the table in whichever database holds it, not a fixed name", async () => {
  // A dev host often keeps the same table in a differently named database; naming one that does
  // not resolve is err 208, and the boundary would never be tested there.
  const rs = await run({ custDb: "AppDb_dev" });
  const row = rs.find((r) => r.check.startsWith("cannot read"));
  assert.equal(row?.result, "PASS");
  assert.equal(row?.detail, "AppDb_dev.msg.MessageLog: denied (err 229)");
  assert.match(probed[0] ?? "", /FROM \[AppDb_dev\]\.msg\.MessageLog;/);
});

test("the search runs OBJECT_ID only for a database already known to be ONLINE", async () => {
  // With state_desc = 'ONLINE' AND OBJECT_ID(...), SQL Server may evaluate OBJECT_ID for a SUSPECT
  // database sys.databases goes on to hide, and the search fails with 945. A fake cannot reproduce
  // SQL Server's evaluation order, so this pins the shape that avoids it: OBJECT_ID inside a CASE.
  const seen: string[] = [];
  const base = fake({ custDb: "AppDb_dev" });
  await selftestInstance(async (i, sql, ...rest) => { seen.push(sql); return base(i, sql, ...rest); }, "dev-node1", "svc_sqldiag", PROBE);
  const search = seen.find((s) => s.includes("N'.msg.MessageLog', N'U')")) ?? "";
  assert.match(search, /WHERE CASE WHEN state_desc = N'ONLINE' AND database_id > 4 THEN OBJECT_ID\(QUOTENAME\(name\) \+ N'\.msg\.MessageLog', N'U'\) END IS NOT NULL/);
  assert.match(search, /ORDER BY CASE name WHEN N'AppDb_Data' THEN 0 ELSE 1 END, name;/);
  assert.doesNotMatch(search, /state_desc = N?'ONLINE' AND OBJECT_ID/);
});

test("the probed table and database are configurable, and validated before they reach SQL", () => {
  assert.deepEqual(customerProbe({}), PROBE);
  assert.deepEqual(customerProbe({ SELFTEST_CUSTOMER_TABLE: "sales.Orders", SELFTEST_CUSTOMER_DB: "Shop" }), { table: "sales.Orders", preferDb: "Shop" });
  for (const bad of ["Orders", "a.b.c", "sales.[Orders]", "x'; DROP TABLE t; --.y"]) {
    assert.throws(() => customerProbe({ SELFTEST_CUSTOMER_TABLE: bad }), /schema\.table/, bad);
  }
  assert.throws(() => customerProbe({ SELFTEST_CUSTOMER_DB: "a]b" }), /plain database name/);
});

test("an unreadable ERRORLOG fails", async () => {
  const rs = await run({ errorlog: Object.assign(new Error("EXECUTE permission denied"), { number: 229 }) }, "region2-node1");
  assert.equal(verdict(rs, "ERRORLOG readable"), "FAIL");
});

test("a node that cannot be reached fails once and stops", async () => {
  const rs = await run({ connect: new Error("Failed to connect to 192.0.2.25:1433") }, "region2-node1");
  assert.deepEqual(rs.map((r) => [r.check, r.result]), [["connect", "FAIL"]]);
});

test("--all tests every SQL instance and never a witness", () => {
  const fleet = [{ name: "region1-listener" }, { name: "region1-node1" }, { name: "region1-witness", kind: "witness" }, { name: "region2-node1", kind: "sql" }];
  assert.deepEqual(selftestTargets(["--all"], fleet, "region1-listener"), ["region1-listener", "region1-node1", "region2-node1"]);
  assert.deepEqual(selftestTargets([], fleet, "dev-node1"), ["dev-node1"]);
});
