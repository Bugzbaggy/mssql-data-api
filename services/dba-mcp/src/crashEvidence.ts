// ─────────────────────────────────────────────────────────────────────────────
// Crash evidence over the SQL connection: the SQLDump<NNNN>.txt stack dumps, and the regex guard
// that both crash readers apply to a caller's `contains` (the ERRORLOG reader is errorLogReader.ts).
//
// Neither needs PowerShell or a filesystem share, so both run on every transport — including
// the shared HTTP one, where dbatools.ts refuses its PowerShell-backed tools and the caller may be
// the least-privilege svc_sqldiag login (deploy/01-*). What that login holds for the dumps:
//   dump list  VIEW SERVER STATE, which covers sys.dm_os_enumerate_filesystem.
//   dump text  EXECUTE on master.dbo.sp_ReadSqlDumpFile, a certificate-signed procedure
//              (deploy/05-*). The login holds no ADMINISTER BULK OPERATIONS of its own.
// Every name is three-part on purpose: a connection's default database is an application
// database, and the grants live in master.
// ─────────────────────────────────────────────────────────────────────────────
import vm from "node:vm";
import { DUMP_DIR_DECLARE, DUMP_DIR_CTE } from "./dumpPaths.js";

/** The slice of queryInstance these readers need — injected, so the tests run without SQL. */
export type QueryFn = (
  instanceName: string,
  sqlText: string,
  maxRows: number,
  opts?: { noteTruncation?: boolean },
) => Promise<{ rows: Record<string, unknown>[] }>;

// A caller's pattern runs on the server's single event-loop thread. Over HTTP that thread serves
// every session, so one catastrophic pattern — (a+)+$ against a long line — would stall them all.
// Length is capped, and a quantified group that itself contains a quantifier is refused before
// compiling, with a message saying why: the commonest shape behind exponential backtracking in V8.
// matchingLines, below, is what bounds every other shape.
// A group: "(", then anything with a quantifier (+, * or {n,m}) inside it, then ")" and a quantifier.
const NESTED_QUANTIFIER = /\((?:[^()\\]|\\.)*(?:[+*]|\{\d*,?\d*\})(?:[^()\\]|\\.)*\)(?:[+*]|\{\d*,?\d*\})/;

export function safeRegex(pattern: string): RegExp {
  if (pattern.length > 256) throw new Error("`contains` is limited to 256 characters.");
  if (NESTED_QUANTIFIER.test(pattern)) {
    throw new Error(
      "`contains` has a quantified group that contains a quantifier (e.g. (a+)+), which can " +
        "backtrack exponentially and stall the server. Rewrite it without the nesting."
    );
  }
  try {
    return new RegExp(pattern, "i");
  } catch (e) {
    throw new Error(`\`contains\` is not a valid regular expression: ${e instanceof Error ? e.message : String(e)}`);
  }
}

// The check above cannot be complete: (a|a)*x has no nested quantifier and a*a*a*a*b has no group,
// and both backtrack without end. So the filter itself runs under a time budget — vm's timeout
// stops V8 inside a backtracking match — and a pattern that exhausts it is refused, which frees
// the event loop for every other session after at most the budget, not after the match.
export const REGEX_BUDGET_MS = 2_000;
const FILTER = new vm.Script(
  "const re = new RegExp(pattern, 'i'); for (let i = 0; i < lines.length; i++) if (re.test(lines[i])) hits.push(i);"
);

/**
 * The pattern with a leading `.*` or `^.*` and a trailing `.*` or `.*$` dropped. On one line, under
 * test(), they decide nothing — but V8 retries a leading one from every position, which made
 * `.*deadlock.*` cost about a second over a full 50,000-line window, enough to spend the budget on
 * a pattern that does not backtrack. Top level only; a lazy `.*?` and an escaped `\.*` are kept.
 */
export function simplifyForTest(pattern: string): string {
  let p = pattern.replace(/^\^?\.\*(?![*+?{])/, "");
  const tail = /(\\*)\.\*\$?$/.exec(p);
  if (tail && tail[1].length % 2 === 0) p = p.slice(0, tail.index + tail[1].length);
  return p.length ? p : pattern;
}

/** Indexes of the lines `pattern` matches, case-insensitively — within the budget, or an error. */
export function matchingLines(pattern: string, lines: string[], budgetMs = REGEX_BUDGET_MS): number[] {
  safeRegex(pattern);
  const hits: number[] = [];
  try {
    FILTER.runInNewContext({ pattern: simplifyForTest(pattern), lines, hits }, { timeout: budgetMs });
  } catch (e) {
    if ((e as { code?: unknown }).code !== "ERR_SCRIPT_EXECUTION_TIMEOUT") throw e;
    throw new Error(
      `\`contains\` did not finish within ${budgetMs / 1000} s over ${lines.length} line(s): the pattern ` +
        "backtracks, or the window is too large. Use a literal, a pattern without a repeated group or " +
        "stacked quantifiers, or a shorter window (hours)."
    );
  }
  return hits;
}

// ── SQLDump<NNNN>.txt ─────────────────────────────────────────────────────────

const DUMP_TEXT_RE = /^SQLDump\d+\.txt$/i;

/** Checked before any SQL is built: a bare SQLDump<NNNN>.txt name, nothing that could be a path. */
export function assertDumpTextFile(file: string | undefined): string {
  if (!file) throw new Error("action='read' requires `file` (e.g. 'SQLDump0004.txt').");
  if (/[\\/:]|\.\./.test(file)) {
    throw new Error(`Invalid file name: ${file}. Plain filename only — no path separators, drive letters or '..'.`);
  }
  if (!DUMP_TEXT_RE.test(file)) {
    throw new Error(
      `read_sql_dump only reads SQLDump<NNNN>.txt files. '${file}' is not a text stack-dump. ` +
        "For the binary .mdmp use windbg or sqldumper on the host."
    );
  }
  return file;
}

// Dump-dir resolution lives in dumpPaths.ts: the ERRORLOG directory is not necessarily the dump
// directory, and neither is the running binary's own directory.
const LOG_DIR_QUERY = DUMP_DIR_DECLARE + `SELECT @errDir AS log_directory;`;

export async function listDumps(query: QueryFn, instanceName: string) {
  const listQ =
    DUMP_DIR_DECLARE + DUMP_DIR_CTE +
    `SELECT d.dir AS log_directory,f.file_or_directory_name AS [Name],` +
    `CAST(f.size_in_bytes AS bigint) AS [Length],` +
    `CONVERT(varchar(33),f.last_write_time,126) AS [LastWriteTimeUtc] ` +
    `FROM d CROSS APPLY sys.dm_os_enumerate_filesystem(d.dir,'SQLDump*') f ` +
    `WHERE f.is_directory=0 ORDER BY f.last_write_time DESC;`;
  const { rows } = await query(instanceName, listQ, 5000);
  const dumps = rows.map((rw) => ({
    Name: String(rw.Name),
    Length: Number(rw.Length),
    LastWriteTimeUtc: String(rw.LastWriteTimeUtc),
  }));
  let log_directory: string | null = rows.length ? String(rows[0].log_directory) : null;
  if (!log_directory) {
    const dr = await query(instanceName, LOG_DIR_QUERY, 1);
    log_directory = (dr.rows[0]?.log_directory as string) ?? null;
  }
  return { instance: instanceName, channel: "sql:dm_os_enumerate_filesystem", log_directory, dump_count: dumps.length, dumps };
}

const sqlErrorNumber = (e: unknown): number | undefined =>
  typeof e === "object" && e !== null && typeof (e as { number?: unknown }).number === "number"
    ? (e as { number: number }).number
    : undefined;

// OPENROWSET needs a string-literal path, so the validated directory + file name is embedded.
// Only a login holding ADMINISTER BULK OPERATIONS gets here — a DBA on stdio, never svc_sqldiag.
async function readViaOpenrowset(query: QueryFn, instanceName: string, file: string): Promise<{ body: string; path: string }> {
  const fileDirQ = DUMP_DIR_DECLARE + DUMP_DIR_CTE +
    `SELECT TOP 1 d.dir AS log_directory ` +
    `FROM d CROSS APPLY sys.dm_os_enumerate_filesystem(d.dir,N'${file.replace(/'/g, "''")}') f ` +
    `WHERE f.is_directory=0 ORDER BY d.pref;`;
  let dir = ((await query(instanceName, fileDirQ, 1)).rows[0]?.log_directory as string) || "";
  if (!dir) dir = ((await query(instanceName, LOG_DIR_QUERY, 1)).rows[0]?.log_directory as string) || "";
  if (!dir) throw new Error("Could not resolve the SQL dump directory (searched the ERRORLOG dir and the install \\MSSQL\\Log dirs).");
  const sep = dir.includes("\\") ? "\\" : "/";
  const path = dir.replace(/[\\/]+$/, "") + sep + file;
  const pesc = path.replace(/'/g, "''");
  // SQLDump*.txt are usually UTF-16 (SINGLE_NCLOB); some builds emit DBCS/ASCII (SINGLE_CLOB).
  try {
    const rr = await query(instanceName, `SELECT CAST(BulkColumn AS nvarchar(max)) AS body FROM OPENROWSET(BULK N'${pesc}', SINGLE_NCLOB) AS x`, 1);
    return { body: (rr.rows[0]?.body as string) ?? "", path };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (!/Unicode|double-byte|DBCS|SINGLE_NCLOB|SINGLE_CLOB|code page/i.test(msg)) throw e;
    const rr = await query(instanceName, `SELECT CAST(BulkColumn AS varchar(max)) AS body FROM OPENROWSET(BULK '${pesc}', SINGLE_CLOB) AS x`, 1);
    return { body: (rr.rows[0]?.body as string) ?? "", path };
  }
}

export interface DumpReadArgs { file?: string; contains?: string; tail?: number; max_lines?: number }

export async function readDump(query: QueryFn, instanceName: string, a: DumpReadArgs) {
  const file = assertDumpTextFile(a.file);
  if (a.contains) safeRegex(a.contains); // refuse a bad pattern before any SQL runs

  // Which path can this login take? The signed reader is how a login WITHOUT bulk rights reads
  // dump text; OPENROWSET directly needs ADMINISTER BULK OPERATIONS.
  const caps = (await query(instanceName,
    "SELECT TOP (1) OBJECT_ID(N'master.dbo.sp_ReadSqlDumpFile', N'P') AS reader_id, " +
      "HAS_PERMS_BY_NAME(NULL, NULL, N'ADMINISTER BULK OPERATIONS') AS can_bulk;", 1)).rows[0] ?? {};
  const hasReader = caps.reader_id !== null && caps.reader_id !== undefined;
  const canBulk = Number(caps.can_bulk) === 1;

  let body = "";
  let channel = "";
  let path: string | null = null;
  if (hasReader) {
    try {
      // SET ROWCOUNT 0: otherwise queryInstance wraps this EXEC in SET ROWCOUNT 2, and ROWCOUNT
      // carries into the procedure, capping every multi-row statement it runs.
      const rr = await query(instanceName, `SET ROWCOUNT 0;\nEXEC master.dbo.sp_ReadSqlDumpFile @FileName = N'${file}';`, 1);
      body = String(rr.rows[0]?.body ?? "");
      channel = "sql:signed-reader (master.dbo.sp_ReadSqlDumpFile)";
    } catch (e) {
      // A login with bulk rights still has OPENROWSET to try. Everyone else gets the reason.
      if (!canBulk) {
        if (sqlErrorNumber(e) === 4834) {
          throw new Error(
            "master.dbo.sp_ReadSqlDumpFile exists on this node but is NOT SIGNED, so it has no bulk " +
              "rights to lend — an ALTER PROCEDURE drops the signature. Re-run the whole of " +
              "deploy/05-signed-dump-reader.sql with a new throwaway password (its step 1b " +
              "replaces the certificate, so step 3 can sign again)."
          );
        }
        // 4860 comes after the permission check: the signature lent the permission, and SQL Server
        // then would not open the file for a non-sysadmin caller. Measured on SQL Server 2022 on
        // Linux, which refuses every non-sysadmin bulk read that way, even with a direct grant.
        if (sqlErrorNumber(e) === 4860) {
          throw new Error(
            `The signed reader passed the permission check, but SQL Server refused to open ${file} for a ` +
              "non-sysadmin caller (error 4860). SQL Server on Linux does this for every non-sysadmin bulk " +
              "read; on Windows, check that the service account can read the dump directory. " +
              "action='list' still works. Server message: " + (e instanceof Error ? e.message : String(e))
          );
        }
        throw e;
      }
    }
  }
  if (!body) {
    if (!canBulk) {
      if (!hasReader) {
        throw new Error(
          "Reading dump TEXT needs the certificate-signed reader master.dbo.sp_ReadSqlDumpFile " +
            "(deploy/05-signed-dump-reader.sql), which is not installed on this node, and this " +
            "login holds no ADMINISTER BULK OPERATIONS — by design. action='list' still works."
        );
      }
      throw new Error(`${file} was read but is empty.`);
    }
    const r = await readViaOpenrowset(query, instanceName, file);
    if (!r.body) throw new Error(`File not found or empty over the SQL channel: ${r.path} (confirm it exists via action='list').`);
    body = r.body;
    path = r.path;
    channel = "sql:openrowset";
  }

  let lines = body.split(/\r?\n/);
  if (a.contains) {
    const all = lines;
    lines = matchingLines(a.contains, all).map((i) => all[i]);
  }
  if (a.tail) lines = lines.slice(-a.tail);
  const cap = a.max_lines ?? 2000;
  if (lines.length > cap) lines = lines.slice(0, cap);
  return { file: path ?? file, channel, filter: a.contains ?? "", tail: a.tail ?? null, line_count: lines.length, lines };
}
