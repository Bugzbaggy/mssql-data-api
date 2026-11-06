// ─────────────────────────────────────────────────────────────────────────────
// Writes reach a dev host only.
//
// execute_write runs as the caller's own login, so SQL Server's grants bound WHAT it can change.
// They do not bound WHERE: the login that may write on the dev host is commonly sysadmin on the
// production nodes too. So the write path proves, on the SAME connection the statement will use
// and before the statement is sent, that the server it reached is the dev host its fleet entry
// names:
//   • the fleet entry carries `region: "dev"`, and
//   • SERVERPROPERTY('ServerName') on the live connection equals the entry's `computer_name`.
// Both must hold. A fleet entry can mislabel a node, and a listener or a stale IP can hand the
// connection to a node the entry did not mean, so neither fact is trusted alone. Anything else
// is refused with the statement unsent and the transaction rolled back.
//
// The checks are layered by what they need: `devWriteName` refuses a "<region>-primary" alias
// before anything is resolved (resolving one queries that region's nodes); `devWriteRegion` needs
// only the fleet entry, so the caller refuses a non-dev target before it opens a pool to it;
// `devWriteEntry` adds the computer_name check and `devWriteTarget` the live-name check, both run
// once the server has answered, so a missing computer_name is reported with the name to add.
// The statement text is bounded by safety.ts (no four-part names and no EXEC @variable, so it
// cannot leave the host through a linked server); what a dev PROCEDURE, synonym, view or trigger
// does through dev's linked servers is bounded only by those servers' login mappings — see
// DEPLOYMENT.md §4a, "Dev-only writes".
//
// Pure functions over an injected transaction runner, so the gate is tested without a server.
// ─────────────────────────────────────────────────────────────────────────────

/** The parts of a fleet entry the gate reads. */
export interface DevWriteTarget {
  name: string;
  region?: string;
  computer_name?: string;
}

/** One open transaction: every query runs on its single connection. */
export interface WriteRunner {
  query(text: string): Promise<{ rowsAffected: number[]; recordset?: Record<string, unknown>[] }>;
  commit(): Promise<void>;
  rollback(): Promise<void>;
}

/** The only fleet region that may be written to. */
export const DEV_WRITE_REGION = "dev";

/** Asks the server its own name. SERVERPROPERTY('ServerName') is live; @@SERVERNAME can lag a rename. */
export const DEV_WRITE_PROBE_SQL = "SELECT CAST(SERVERPROPERTY('ServerName') AS nvarchar(256)) AS server_name;";

type Verdict = { ok: true } | { ok: false; reason: string };

/** Thrown when the gate refuses: nothing was sent, and the transaction (if any) is rolled back. */
export class DevWriteRefusedError extends Error {
  constructor(reason: string) {
    super(reason);
    this.name = "DevWriteRefusedError";
  }
}

const refuse = (why: string): Verdict => ({ ok: false, reason: `execute_write refused: ${why}` });

/**
 * The instance name must be a host's own name. A "<region>-primary" alias is resolved by querying
 * that region's nodes for the AG primary, which a write to dev never needs: the dev host is
 * standalone and has no primary to resolve.
 */
export function devWriteName(instanceName: string): Verdict {
  if (instanceName.trim().toLowerCase().endsWith("-primary")) {
    return refuse(
      `"${instanceName}" is an AG-primary alias, which is resolved by querying that region's nodes. ` +
      `Name the dev instance itself (e.g. "dev-node1"); the dev host is standalone and has no primary.`,
    );
  }
  return { ok: true };
}

/** The fleet entry's region alone: nothing about it needs a connection. */
export function devWriteRegion(target: DevWriteTarget): Verdict {
  const region = (target.region ?? "").trim().toLowerCase();
  if (region !== DEV_WRITE_REGION) {
    return refuse(
      `"${target.name}" is in fleet region "${target.region ?? ""}", not "${DEV_WRITE_REGION}". ` +
      `Writes are allowed on dev hosts only; every other instance is read-only.`,
    );
  }
  return { ok: true };
}

/**
 * The fleet entry: region "dev", and a computer_name naming the server it expects.
 * `liveServerName`, when known, makes the missing-computer_name message say what to add.
 */
export function devWriteEntry(target: DevWriteTarget, liveServerName?: string | null): Verdict {
  const region = devWriteRegion(target);
  if (!region.ok) return region;
  const live = typeof liveServerName === "string" ? liveServerName.trim() : "";
  const expected = (target.computer_name ?? "").trim();
  if (!expected) {
    return refuse(
      `"${target.name}" has no computer_name in the fleet file, so the server it reaches cannot be verified. ` +
      `Add "computer_name": "${live || "<the server's SERVERPROPERTY('ServerName')>"}" to that entry` +
      (live ? ` (the server reports "${live}")` : "") + `.`,
    );
  }
  return { ok: true };
}

/**
 * The whole gate: `devWriteEntry`, then the server reached through the connection must call
 * itself what the entry says. Names are compared case-insensitively after trimming, and
 * otherwise exactly: a named instance ("HOST\INST") is a different server.
 */
export function devWriteTarget(target: DevWriteTarget, liveServerName: string | null | undefined): Verdict {
  const entry = devWriteEntry(target, liveServerName);
  if (!entry.ok) return entry;
  const live = typeof liveServerName === "string" ? liveServerName.trim() : "";
  const expected = (target.computer_name ?? "").trim();
  if (!live) {
    return refuse(`"${target.name}" did not report its server name, so it cannot be verified as the dev host "${expected}".`);
  }
  if (live.toUpperCase() !== expected.toUpperCase()) {
    return refuse(`"${target.name}" reached a server named "${live}", not the dev host "${expected}" its fleet entry names.`);
  }
  return { ok: true };
}

/**
 * Probe the connection, apply the gate, and only then run `sqlText` in the open transaction.
 *   commit=false → ROLLBACK (dry run): returns what WOULD change.
 *   commit=true  → COMMIT.
 * `hooks.onAccepted` runs once the gate has passed and before the statement is sent — the point
 * at which facts about this connection become facts about the statement. A refusal throws
 * DevWriteRefusedError; a refusal, a failed probe, a failed hook or a failed statement all leave
 * the transaction rolled back.
 */
export async function runDevGatedWrite(
  target: DevWriteTarget,
  runner: WriteRunner,
  sqlText: string,
  commit: boolean,
  hooks?: { onAccepted?: () => void },
): Promise<{ rowsAffected: number; committed: boolean; recordset: Record<string, unknown>[]; server_name: string }> {
  const rollback = async () => { try { await runner.rollback(); } catch { /* already aborted */ } };

  let live: unknown;
  try {
    const probe = await runner.query(DEV_WRITE_PROBE_SQL);
    live = probe.recordset?.[0]?.server_name;
  } catch (e) {
    await rollback();
    throw e;
  }
  const gate = devWriteTarget(target, live == null ? null : String(live));
  if (!gate.ok) {
    await rollback();
    throw new DevWriteRefusedError(gate.reason);
  }

  try {
    hooks?.onAccepted?.();
    // SET XACT_ABORT ON: any error aborts the whole transaction rather than part of it.
    const result = await runner.query(`SET XACT_ABORT ON;\n${sqlText}`);
    const rowsAffected = Array.isArray(result.rowsAffected) ? result.rowsAffected.reduce((a, b) => a + b, 0) : 0;
    const recordset = result.recordset ?? [];
    if (commit) await runner.commit();
    else await runner.rollback();
    return { rowsAffected, committed: commit, recordset, server_name: String(live).trim() };
  } catch (e) {
    await rollback();
    throw e;
  }
}
