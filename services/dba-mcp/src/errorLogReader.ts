// ─────────────────────────────────────────────────────────────────────────────
// read_error_log over the SQL connection (master.sys.xp_readerrorlog), on every transport.
//
// Get-DbaErrorLog turns the WHOLE file into PowerShell objects before any filter applies, so its
// cost is the log's size: a 25 MB active log timed out at the 120 s budget, and a multi-GB archive
// would never finish. xp_readerrorlog filters inside the engine, and the caller's own SQL login
// carries it — so it keeps per-user identity on stdio, runs under the least-privilege svc_sqldiag
// on HTTP, and involves no Windows authentication to the host. What that login needs:
//   EXECUTE on master.sys.xp_readerrorlog (deploy/01-*, PART C). Never sp_readerrorlog: that
//          wrapper demands securityadmin.
//   VIEW SERVER STATE, which covers the sys.dm_os_enumerate_filesystem size probe below.
// Every name is three-part on purpose: a connection's default database is an application
// database, and the grants live in master.
//
// How `contains` is matched:
//   literal (no regex metacharacters)  -> xp_readerrorlog's own search, whole file, in the engine
//   alternation of literals (a|b|c)    -> one engine search per term, merged here; still the whole file
//   any other regex                    -> matched here over the newest ERRORLOG_SCAN_ROWS lines,
//                                         under crashEvidence.ts's time budget
// The engine matches by the server's collation, so a literal is case-insensitive on a CI server.
// A log file over ERRORLOG_MAX_MB is refused before it is read: a multi-GB archive is usually
// inert, and reading it would hold the connection for minutes.
// ─────────────────────────────────────────────────────────────────────────────
import { safeRegex, matchingLines, type QueryFn } from "./crashEvidence.js";

export type { QueryFn };

/** Newest ERRORLOG lines examined when `contains` is a regex the engine cannot match itself. */
export const ERRORLOG_SCAN_ROWS = 50_000;
/** The largest log file this tool reads at all. */
export const ERRORLOG_MAX_MB = 2048;
/** The most literal terms an alternation is split into; past this it is treated as a regex. */
export const ERRORLOG_MAX_TERMS = 8;

const REGEX_META = /[\\^$.|?*+()[\]{}]/;

/** A plain, non-empty substring: something xp_readerrorlog can match itself, across the whole log. */
export function isLiteral(s: string): boolean {
  return s.length > 0 && !REGEX_META.test(s);
}

export type FilterPlan =
  | { mode: "none" }
  | { mode: "literal"; terms: string[] }
  | { mode: "regex"; pattern: string };

/** Decide who matches `contains`: SQL Server (literal terms, whole file) or this process (regex). */
export function planFilter(contains: string | undefined): FilterPlan {
  if (!contains) return { mode: "none" };
  safeRegex(contains); // refuse a bad pattern before any SQL runs
  const terms = contains.split("|");
  if (terms.length <= ERRORLOG_MAX_TERMS && terms.every(isLiteral)) return { mode: "literal", terms: [...new Set(terms)] };
  return { mode: "regex", pattern: contains };
}

/** How many newest rows the batch returns for a plan, so the shaped result can say "more_rows". */
export function rowsToFetch(plan: FilterPlan, maxRows: number, scanRows: number): number {
  if (plan.mode === "regex") return scanRows + 1;
  // A line that matches two terms comes back once per term, so leave room for the duplicates.
  return (maxRows + 1) * (plan.mode === "literal" ? plan.terms.length : 1);
}

/** The batch that reads one ERRORLOG file, newest first. Exported so the tests can pin its shape. */
export function errorLogBatch(logNumber: number, plan: FilterPlan, opts: { hours?: number; top: number; maxMb: number }): string {
  if (!Number.isInteger(logNumber) || logNumber < 0 || logNumber > 99) {
    throw new Error("log_number must be an integer from 0 to 99.");
  }
  if (opts.hours !== undefined && (!Number.isInteger(opts.hours) || opts.hours < 1 || opts.hours > 8760)) {
    throw new Error("hours must be an integer from 1 to 8760.");
  }
  const lit = (s: string) => `N'${s.replace(/'/g, "''")}'`;
  // Log type 1 is the SQL Server log (2 would be SQL Agent's); DESC returns newest first.
  const read = (search: string) =>
    `INSERT @t EXEC master.sys.xp_readerrorlog ${logNumber}, 1, ${search}, NULL, @start, NULL, N'DESC';`;
  const reads = plan.mode === "literal" ? plan.terms.map((t) => read(lit(t))) : [read("NULL")];
  return [
    "SET NOCOUNT ON;",
    "DECLARE @log nvarchar(512) = CONVERT(nvarchar(512), SERVERPROPERTY('ErrorLogFileName'));",
    // Either separator: on SQL Server on Linux the path is /var/opt/mssql/log/errorlog. A '\'-only
    // split would leave @dir as the FILE path, and the probe would find nothing. NB '\\' in this TS
    // string emits N'\'; a single backslash would emit N'' and find nothing either.
    "DECLARE @cut int = CHARINDEX(CASE WHEN CHARINDEX(N'\\', @log) > 0 THEN N'\\' ELSE N'/' END, REVERSE(@log));",
    "DECLARE @dir nvarchar(512) = CASE WHEN @cut > 1 THEN LEFT(@log, LEN(@log) - @cut) END;",
    // The current log's own name (ERRORLOG on Windows, errorlog on Linux), so the probe's pattern
    // and name filter follow the platform's spelling rather than assuming one.
    "DECLARE @base nvarchar(260) = CASE WHEN @cut > 1 THEN RIGHT(@log, @cut - 1) END;",
    `DECLARE @file nvarchar(260) = @base${logNumber === 0 ? "" : ` + N'.${logNumber}'`};`,
    // The wildcard plus a name filter, not the bare name as the pattern. If the size cannot be read
    // (no such file, or a path this probe cannot derive), @mb stays NULL, the guard passes and
    // log_file_mb comes back null.
    "DECLARE @mb decimal(12,1);",
    "IF @dir IS NOT NULL",
    "  SET @mb = (SELECT TOP (1) CONVERT(decimal(12,1), CONVERT(bigint, size_in_bytes) / 1048576.0)",
    "    FROM sys.dm_os_enumerate_filesystem(@dir, @base + N'*') WHERE is_directory = 0 AND file_or_directory_name = @file);",
    // Refuse before xp_readerrorlog reads a byte of it.
    `IF @mb > ${opts.maxMb}`,
    "BEGIN",
    `  DECLARE @msg nvarchar(400) = CONCAT(@file, N' is ', @mb, N' MB, over the ${opts.maxMb} MB this tool reads. ',`,
    "    N'Read it on the host, or delete it if it is an inert archive (identify it by size, not by its .N name).');",
    "  THROW 50001, @msg, 1;",
    "END;",
    `DECLARE @start datetime = ${opts.hours ? `DATEADD(HOUR, -${opts.hours}, GETDATE())` : "NULL"};`,
    "DECLARE @t TABLE (LogDate datetime, ProcessInfo nvarchar(256), [Text] nvarchar(max));",
    ...reads,
    // The TOP also keeps queryInstance from wrapping this batch in SET ROWCOUNT, which would cap
    // the INSERTs above before the ORDER BY ever saw the newest lines (applyRowLimit).
    `SELECT TOP (${opts.top}) CONVERT(varchar(23), LogDate, 126) AS LogDate, ProcessInfo, [Text], @mb AS FileMb`,
    "FROM @t ORDER BY LogDate DESC;",
  ].join("\n");
}

/** Filter, de-duplicate and cap the newest-first rows, and say how much was examined. */
export function shapeErrorLog(rows: Record<string, unknown>[], plan: FilterPlan, maxRows: number, scanRows: number) {
  const isRegex = plan.mode === "regex";
  const scanTruncated = isRegex && rows.length > scanRows;
  let examined = scanTruncated ? rows.slice(0, scanRows) : rows;
  if (plan.mode === "literal" && plan.terms.length > 1) {
    const seen = new Set<string>();
    examined = examined.filter((r) => {
      const k = `${String(r.LogDate)}\u0000${String(r.ProcessInfo ?? "")}\u0000${String(r.Text ?? "")}`;
      if (seen.has(k)) return false;
      seen.add(k);
      return true;
    });
  }
  const hits = plan.mode === "regex"
    ? matchingLines(plan.pattern, examined.map((r) => String(r.Text ?? ""))).map((i) => examined[i])
    : examined;
  const out = hits.slice(0, maxRows).map((r) => ({
    LogDate: String(r.LogDate),
    ProcessInfo: String(r.ProcessInfo ?? ""),
    Text: String(r.Text ?? ""),
  }));
  return {
    // Only a regex is matched over a window; a literal is matched by SQL Server across the whole file.
    ...(isRegex
      ? {
          scanned_rows: examined.length,
          scan_truncated: scanTruncated,
          oldest_line_examined: examined.length ? String(examined[examined.length - 1].LogDate) : null,
          matched_rows: hits.length,
        }
      : {}),
    returned_rows: out.length,
    more_rows: hits.length > maxRows,
    rows: out,
  };
}

export interface ErrorLogArgs { contains?: string; log_number?: number; max_rows?: number; hours?: number }

export async function readErrorLog(query: QueryFn, instanceName: string, a: ErrorLogArgs) {
  const plan = planFilter(a.contains || undefined);
  const logNumber = a.log_number ?? 0;
  const maxRows = a.max_rows ?? 500;
  const top = rowsToFetch(plan, maxRows, ERRORLOG_SCAN_ROWS);
  const sqlText = errorLogBatch(logNumber, plan, { hours: a.hours, top, maxMb: ERRORLOG_MAX_MB });
  const { rows } = await query(instanceName, sqlText, top, { noteTruncation: false });
  const fileMb = rows.length && rows[0].FileMb !== null && rows[0].FileMb !== undefined ? Number(rows[0].FileMb) : null;
  return {
    instance: instanceName,
    channel: "sql:xp_readerrorlog",
    log_number: logNumber,
    log_file_mb: fileMb,
    filter: a.contains ?? "",
    filter_mode:
      plan.mode === "none" ? "none"
      : plan.mode === "literal"
        ? `${plan.terms.length > 1 ? `${plan.terms.length} literal terms` : "literal"}, whole log, matched by SQL Server`
        : `regex, newest ${ERRORLOG_SCAN_ROWS} lines`,
    hours: a.hours ?? null,
    ...shapeErrorLog(rows, plan, maxRows, ERRORLOG_SCAN_ROWS),
  };
}
