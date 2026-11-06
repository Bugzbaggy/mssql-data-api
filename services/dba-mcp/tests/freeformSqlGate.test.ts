import { test } from "node:test";
import assert from "node:assert/strict";

/*
 * execute_query and fan_out_query accept ARBITRARY T-SQL. On stdio that is the point of
 * TOOLSET=dba — a DBA authenticated as themselves. Over the shared HTTP transport the caller
 * may be an agent behind a gateway, and arbitrary SQL is exactly what such a path must not
 * offer: no arbitrary target selection, and a minimal surface rather than the backend's full
 * query API.
 *
 * A gateway may allowlist the tools it forwards, but that allowlist is not reviewable from
 * here: if it is ever misconfigured, the server itself must still refuse. This pins the
 * server-side half.
 *
 * TOOLSET stays "dba" throughout — the toolset is not what changes, the transport is.
 */

type Registered = { name: string };

async function registerWith(env: Record<string, string | undefined>, seq: number): Promise<string[]> {
  for (const [k, v] of Object.entries(env)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  // Fresh module instance: the flags are read at import time.
  const mod = await import(`../src/tools.js?freeform=${seq}`);
  const names: string[] = [];
  // Minimal McpServer stand-in — registerTools only ever calls .tool(name, ...).
  const fake = {
    tool: (name: string, ..._rest: unknown[]) => { names.push(name); return undefined; },
  } as unknown as Parameters<typeof mod.registerTools>[0];
  mod.registerTools(fake);
  return names;
}

const BASE = {
  TOOLSET: "dba",
  INSTANCES: JSON.stringify([{ name: "t1", host: "h1.invalid", port: 1433, database: "AppCatalog" }]),
  INSTANCES_FILE: undefined,
  SQL_CRED_TARGET: undefined,
  SQL_USER: "u",
  SQL_PASSWORD: "p",
  SCHEMA_DOCS_ENABLED: "false",
  DBATOOLS_ENABLED: "false",
  FREEFORM_SQL_ENABLED: undefined,
  DEV_WRITE_ENABLED: undefined,
  ENG_WRITE_ENABLED: undefined,
  SQL_SERVICE_IDENTITY: undefined,
};

const FREEFORM: Registered[] = [{ name: "execute_query" }, { name: "fan_out_query" }];

test("stdio + TOOLSET=dba: free-form SQL IS registered (the human DBA path is unchanged)", async () => {
  const names = await registerWith({ ...BASE, MCP_TRANSPORT: "stdio" }, 1);
  for (const { name } of FREEFORM) {
    assert.ok(names.includes(name), `${name} must stay available on stdio — TOOLSET=dba means full capability for a human`);
  }
});

test("http + TOOLSET=dba: free-form SQL is NOT registered", async () => {
  const names = await registerWith({ ...BASE, MCP_TRANSPORT: "http" }, 2);
  for (const { name } of FREEFORM) {
    assert.ok(!names.includes(name), `${name} must NOT be exposed over HTTP — arbitrary T-SQL cannot be bounded by a gateway`);
  }
});

test("http: the DIAGNOSTIC surface survives — this must not be a blunt kill switch", async () => {
  const names = await registerWith({ ...BASE, MCP_TRANSPORT: "http" }, 3);
  // A representative spread across the fixed-SQL tools an agent actually needs.
  for (const n of ["get_ag_health", "get_hiq", "get_memory_dumps", "get_backup_status",
                   "get_query_store_regressions", "list_instances", "list_databases"]) {
    assert.ok(names.includes(n), `${n} must remain registered over HTTP — removing free-form SQL must not remove diagnostics`);
  }
  assert.ok(names.length > 25, `expected the full DMV surface, got ${names.length} tools`);
});

test("http + explicit override: FREEFORM_SQL_ENABLED=true re-enables it", async () => {
  const names = await registerWith({ ...BASE, MCP_TRANSPORT: "http", FREEFORM_SQL_ENABLED: "true" }, 4);
  for (const { name } of FREEFORM) {
    assert.ok(names.includes(name), `${name} must come back when the override is set deliberately`);
  }
});

test("stdio + explicit opt-out: FREEFORM_SQL_ENABLED=false removes it", async () => {
  const names = await registerWith({ ...BASE, MCP_TRANSPORT: "stdio", FREEFORM_SQL_ENABLED: "false" }, 5);
  for (const { name } of FREEFORM) {
    assert.ok(!names.includes(name), `${name} must be removable on stdio too`);
  }
});

test("the override is strict: any value other than 'true' does not enable it over HTTP", async () => {
  for (const [i, v] of ["1", "yes", "TRUE", ""].entries()) {
    const names = await registerWith({ ...BASE, MCP_TRANSPORT: "http", FREEFORM_SQL_ENABLED: v }, 10 + i);
    assert.ok(!names.includes("execute_query"),
      `FREEFORM_SQL_ENABLED=${JSON.stringify(v)} must not enable arbitrary SQL — only the exact string "true" does`);
  }
});

test("execute_write is never registered on any of these paths", async () => {
  for (const [i, t] of ["stdio", "http"].entries()) {
    const names = await registerWith({ ...BASE, MCP_TRANSPORT: t }, 20 + i);
    assert.ok(!names.includes("execute_write"), `execute_write must not appear under TOOLSET=dba (${t})`);
  }
});
