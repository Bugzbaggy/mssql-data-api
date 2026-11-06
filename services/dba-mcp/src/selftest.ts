// ─────────────────────────────────────────────────────────────────────────────
// `node dist/index.js selftest [--all]` — the deployment acceptance test.
//
// /health is a static handler: it answers 200 the moment Express binds and proves nothing about
// SQL. This connects as the DEPLOYED login, from the DEPLOYED network, and checks what the agent
// path depends on — the capabilities deploy/02-Test-svc_sqldiag-grants.sql proves, but through
// this server's own connection code and crash readers. Run it after every deployment (a container
// platform can run it as a post-deploy test hook) and before trusting a node.
//
// It runs on the process credential (MCP_TRANSPORT=stdio), so it tests the login, its grants and
// the network reach — not the JWT path. That is pinned by tests/serviceIdentity.test.ts and
// exercised end to end only by a real call through the gateway.
//
// Exit 0 when nothing FAILED. UNMEASURED is reported and never counted as a pass, but does not
// fail the run: a node that holds no dump to read is a fact about that node, not a defect.
//
// The customer-data boundary probes SELFTEST_CUSTOMER_TABLE (schema.table, default msg.MessageLog)
// in whichever ONLINE database holds it, SELFTEST_CUSTOMER_DB (default AppDb_Data) first — the
// same example table deploy/02-* names. Point both at a table that holds customer data on your
// nodes, or that check can only ever report UNMEASURED.
// ─────────────────────────────────────────────────────────────────────────────
import { listInstances, queryInstance, DEFAULT_INSTANCE } from "./connectionManager.js";
import { listDumps, readDump, type QueryFn } from "./crashEvidence.js";
import { readErrorLog } from "./errorLogReader.js";

export type Verdict = "PASS" | "FAIL" | "UNMEASURED";
export interface SelftestCheck { instance: string; check: string; result: Verdict; detail: string }

const REQUIRED_GRANTS = ["VIEW SERVER STATE", "VIEW ANY DEFINITION", "VIEW ANY DATABASE", "CONNECT ANY DATABASE"];
const FORBIDDEN_GRANTS = ["CONTROL SERVER", "ADMINISTER BULK OPERATIONS"];
const PERMISSION_DENIED = new Set([229, 230, 297]);

// The allowlist behind FORBIDDEN_GRANTS, so a grant nobody thought to deny still fails. Allowed:
// the four grants and CONNECT SQL, what public holds on this server, and every permission those
// imply here, read from the server's own hierarchy (fn_builtin_permissions) — so it follows the
// SQL Server version. deploy/02-Test-svc_sqldiag-grants.sql runs the same checks, and DBA's too.
// One explicit collation: the three sources disagree (Msg 468 on SQL Server 2022 without it).
const EXTRA_SERVER_PERMISSIONS = `
WITH allowed AS (
  SELECT CAST(v.p AS nvarchar(128)) COLLATE Latin1_General_CI_AS AS permission_name
  FROM (VALUES (N'CONNECT SQL'), (N'VIEW SERVER STATE'), (N'VIEW ANY DEFINITION'), (N'VIEW ANY DATABASE'), (N'CONNECT ANY DATABASE')) AS v(p)
  UNION ALL
  SELECT CAST(sp.permission_name AS nvarchar(128)) COLLATE Latin1_General_CI_AS FROM sys.server_permissions sp
  WHERE sp.class = 100 AND sp.state IN ('G', 'W')
    AND sp.grantee_principal_id = (SELECT principal_id FROM sys.server_principals WHERE name = N'public' AND type = 'R')
), implied AS (
  SELECT permission_name FROM allowed
  UNION ALL
  SELECT CAST(b.permission_name AS nvarchar(128)) COLLATE Latin1_General_CI_AS FROM sys.fn_builtin_permissions(N'SERVER') b
  JOIN implied i ON b.covering_permission_name COLLATE Latin1_General_CI_AS = i.permission_name
  WHERE b.permission_name COLLATE Latin1_General_CI_AS <> i.permission_name
)
SELECT TOP (100) m.permission_name FROM sys.fn_my_permissions(NULL, N'SERVER') m
WHERE m.permission_name COLLATE Latin1_General_CI_AS NOT IN (SELECT permission_name FROM implied) ORDER BY m.permission_name;`;
const EXTRA_SERVER_ROLES =
  "SELECT TOP (50) r.name FROM sys.server_role_members rm JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id " +
  "WHERE rm.member_principal_id = SUSER_ID() AND r.name <> N'role_sqldiag' ORDER BY r.name;";
// db_owner in msdb, which is TRUSTWORTHY and owned by sa, is a path to sysadmin.
const EXTRA_DATABASE_ROLES = `
SELECT TOP (50) q.db + N': ' + q.name AS role FROM (
  SELECT N'master' AS db, r.name FROM master.sys.database_role_members rm
  JOIN master.sys.database_principals r ON r.principal_id = rm.role_principal_id
  JOIN master.sys.database_principals u ON u.principal_id = rm.member_principal_id WHERE u.sid = SUSER_SID()
  UNION ALL
  SELECT N'msdb', r.name FROM msdb.sys.database_role_members rm
  JOIN msdb.sys.database_principals r ON r.principal_id = rm.role_principal_id
  JOIN msdb.sys.database_principals u ON u.principal_id = rm.member_principal_id
  WHERE u.sid = SUSER_SID() AND r.name <> N'SQLAgentReaderRole'
) q ORDER BY 1;`;

const sqlErrorNumber = (e: unknown): number | undefined =>
  typeof e === "object" && e !== null && typeof (e as { number?: unknown }).number === "number"
    ? (e as { number: number }).number
    : undefined;
const message = (e: unknown): string => (e instanceof Error ? e.message : String(e)).slice(0, 300);

const TWO_PART = /^[A-Za-z_][A-Za-z0-9_]{0,127}\.[A-Za-z_][A-Za-z0-9_]{0,127}$/;
const ONE_PART = /^[A-Za-z_][A-Za-z0-9_]{0,127}$/;

/** The customer-data table the boundary check probes, and the database to try first. Validated: both are spliced into SQL. */
export function customerProbe(env: Record<string, string | undefined> = process.env): { table: string; preferDb: string } {
  const table = (env.SELFTEST_CUSTOMER_TABLE ?? "msg.MessageLog").trim();
  const preferDb = (env.SELFTEST_CUSTOMER_DB ?? "AppDb_Data").trim();
  if (!TWO_PART.test(table)) throw new Error(`SELFTEST_CUSTOMER_TABLE must be schema.table (letters, digits, _): got "${table}"`);
  if (!ONE_PART.test(preferDb)) throw new Error(`SELFTEST_CUSTOMER_DB must be a plain database name: got "${preferDb}"`);
  return { table, preferDb };
}

export async function selftestInstance(
  query: QueryFn, instance: string, expectedLogin: string,
  probe: { table: string; preferDb: string } = customerProbe(),
): Promise<SelftestCheck[]> {
  const out: SelftestCheck[] = [];
  const add = (check: string, result: Verdict, detail = ""): void => { out.push({ instance, check, result, detail }); };

  // 1. Who are we, and are we privileged? Nothing else can run if this cannot.
  let who: Record<string, unknown> | undefined;
  try {
    who = (await query(instance,
      "SELECT TOP (1) @@SERVERNAME AS server_name, SUSER_SNAME() AS login, " +
        "IS_SRVROLEMEMBER('sysadmin') AS is_sysadmin, IS_SRVROLEMEMBER('securityadmin') AS is_securityadmin;", 1)).rows[0];
  } catch (e) {
    add("connect", "FAIL", message(e));
    return out;
  }
  add("connect", "PASS", `server ${String(who?.server_name)}`);
  add("login is the deployed service login",
    String(who?.login ?? "").toLowerCase() === expectedLogin.toLowerCase() ? "PASS" : "FAIL",
    `SUSER_SNAME() = ${String(who?.login)}, expected ${expectedLogin}`);
  add("not sysadmin, not securityadmin",
    Number(who?.is_sysadmin) === 0 && Number(who?.is_securityadmin) === 0 ? "PASS" : "FAIL",
    `sysadmin=${String(who?.is_sysadmin)} securityadmin=${String(who?.is_securityadmin)}`);

  // 2. The four grants it needs — and neither of the two that would make it an escalation path.
  try {
    const perms = new Set((await query(instance,
      "SELECT TOP (500) permission_name FROM sys.fn_my_permissions(NULL, 'SERVER');", 500)).rows.map((r) => String(r.permission_name)));
    const missing = REQUIRED_GRANTS.filter((p) => !perms.has(p));
    add("holds the four diagnostic grants", missing.length ? "FAIL" : "PASS", missing.length ? `missing: ${missing.join(", ")}` : "");
    const extra = FORBIDDEN_GRANTS.filter((p) => perms.has(p));
    add("holds no CONTROL SERVER / ADMINISTER BULK OPERATIONS", extra.length ? "FAIL" : "PASS", extra.join(", "));
  } catch (e) {
    add("server permissions readable", "FAIL", message(e));
  }
  // ...and nothing beyond them. A check that cannot run fails: this is the boundary.
  for (const [check, sql, column] of [
    ["holds no server permission beyond the four grants", EXTRA_SERVER_PERMISSIONS, "permission_name"],
    ["is in no server role but role_sqldiag", EXTRA_SERVER_ROLES, "name"],
    ["holds no master/msdb role but SQLAgentReaderRole", EXTRA_DATABASE_ROLES, "role"],
  ] as const) {
    try {
      const extra = (await query(instance, sql, 100)).rows.map((r) => String(r[column]));
      add(check, extra.length ? "FAIL" : "PASS", extra.join(", "));
    } catch (e) {
      add(check, "FAIL", message(e));
    }
  }

  // 3. The DMV surface answers — VIEW SERVER STATE in effect, not merely granted. A missing grant
  //    makes a DMV return only the caller's own session rather than raise.
  try {
    const n = Number((await query(instance, "SELECT TOP (1) COUNT(*) AS n FROM sys.dm_exec_sessions;", 1)).rows[0]?.n);
    add("DMVs see the whole server (sys.dm_exec_sessions)", n > 1 ? "PASS" : "FAIL", `${n} session(s) visible`);
  } catch (e) {
    add("DMVs see the whole server (sys.dm_exec_sessions)", "FAIL", message(e));
  }
  // The tables get_job_status reads. SQLAgentReaderRole alone does not cover a direct SELECT on them.
  try {
    await query(instance,
      "SELECT TOP (1) (SELECT TOP (1) 1 FROM msdb.dbo.sysjobs) AS j, (SELECT TOP (1) 1 FROM msdb.dbo.sysjobhistory) AS h, " +
        "(SELECT TOP (1) 1 FROM msdb.dbo.sysjobactivity) AS a;", 1);
    add("Agent job tables readable (get_job_status)", "PASS");
  } catch (e) {
    add("Agent job tables readable (get_job_status)", "FAIL", message(e));
  }

  // 4. Crash evidence — exactly the readers the agent calls.
  try {
    const r = await readErrorLog(query, instance, { max_rows: 1 });
    add("ERRORLOG readable (read_error_log)", r.returned_rows > 0 ? "PASS" : "FAIL",
      `${r.returned_rows} line(s) read${r.log_file_mb === null ? "" : `, file ${r.log_file_mb} MB`}`);
  } catch (e) {
    add("ERRORLOG readable (read_error_log)", "FAIL", message(e));
  }
  let newest: string | undefined;
  try {
    const d = await listDumps(query, instance);
    newest = d.dumps.find((x) => /\.txt$/i.test(x.Name))?.Name;
    add("dump inventory (read_sql_dump list)", "PASS", `${d.dump_count} file(s)`);
  } catch (e) {
    add("dump inventory (read_sql_dump list)", "FAIL", message(e));
  }
  if (!newest) {
    add("dump text (read_sql_dump read)", "UNMEASURED", "no SQLDump*.txt on this node to read");
  } else {
    try {
      const r = await readDump(query, instance, { file: newest, max_lines: 5 });
      add("dump text (read_sql_dump read)", r.line_count > 0 ? "PASS" : "FAIL", `${newest} via ${r.channel}`);
    } catch (e) {
      add("dump text (read_sql_dump read)", "FAIL", message(e));
    }
  }

  // 5. The boundary: customer data is NOT readable. Only a permission denial is a pass — a
  //    database that cannot be opened on this node proves nothing (deploy/02-* says the same).
  //    The database is found, not named: the same table can live in a differently named database
  //    on a dev host, and a name that does not resolve is err 208, UNMEASURED forever. So: the
  //    ONLINE database holding the table, the preferred one first. VIEW ANY DEFINITION is what lets
  //    OBJECT_ID see it from here. OBJECT_ID sits inside a CASE so that it runs only for a database
  //    already known to be ONLINE: in a plain AND, SQL Server may evaluate it first, even for a row
  //    sys.databases goes on to hide (a SUSPECT database, say), and the search then fails with 945.
  const check = "cannot read customer data";
  try {
    const db = (await query(instance,
      "SELECT TOP (1) name FROM sys.databases " +
        `WHERE CASE WHEN state_desc = N'ONLINE' AND database_id > 4 THEN OBJECT_ID(QUOTENAME(name) + N'.${probe.table}', N'U') END IS NOT NULL ` +
        `ORDER BY CASE name WHEN N'${probe.preferDb}' THEN 0 ELSE 1 END, name;`, 1)).rows[0]?.name as string | undefined;
    if (!db) {
      add(check, "UNMEASURED", `no ONLINE database on this node holds ${probe.table}`);
    } else {
      const target = `[${db.replace(/]/g, "]]")}].${probe.table}`;
      try {
        await query(instance, `SELECT TOP (1) 1 AS x FROM ${target};`, 1);
        add(check, "FAIL", `${db}.${probe.table} was READ`);
      } catch (e) {
        const n = sqlErrorNumber(e);
        add(check, n !== undefined && PERMISSION_DENIED.has(n) ? "PASS" : "UNMEASURED",
          n !== undefined && PERMISSION_DENIED.has(n) ? `${db}.${probe.table}: denied (err ${n})` : `${db}.${probe.table}: not a permission denial: ${message(e)}`);
      }
    }
  } catch (e) {
    add(check, "UNMEASURED", message(e));
  }
  return out;
}

/** The instances to test: the default one, or `--all` SQL instances in the fleet file. */
export function selftestTargets(args: string[], instances: { name: string; kind?: string }[], defaultInstance: string): string[] {
  return args.includes("--all")
    ? instances.filter((i) => (i.kind ?? "sql") === "sql").map((i) => i.name)
    : [defaultInstance];
}

export async function runSelftest(args: string[]): Promise<number> {
  const login = process.env.SQL_USER ?? "";
  if (!login) {
    console.error("[selftest] SQL_USER is not set — there is no deployed login to test.");
    return 2;
  }
  const probe = customerProbe();
  const targets = selftestTargets(args, listInstances(), DEFAULT_INSTANCE);
  const results = (await Promise.all(targets.map((t) => selftestInstance(queryInstance, t, login, probe)))).flat();
  for (const r of results) {
    console.log(`${r.result.padEnd(10)} ${r.instance.padEnd(16)} ${r.check}${r.detail ? ` — ${r.detail}` : ""}`);
  }
  const fail = results.filter((r) => r.result === "FAIL").length;
  const unmeasured = results.filter((r) => r.result === "UNMEASURED").length;
  console.log(`\nselftest: ${results.length} checks on ${targets.length} instance(s) as ${login} — FAIL ${fail}, UNMEASURED ${unmeasured}`);
  return fail ? 1 : 0;
}
