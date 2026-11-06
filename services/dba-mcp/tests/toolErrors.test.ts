/**
 * What a client — or a gateway relaying tool calls — reads from a tool's result. A gateway that
 * fails a call only on `isError` would pass a tool's own error without it to the agent as a
 * successful, citable answer. And an agent is usually told which dump to read, not which `action`
 * to pass, so read_sql_dump must read the file it is given.
 *
 * Registers the server as an HTTP deployment would (TOOLSET=dba, MCP_TRANSPORT=http) in a child
 * process, and calls the handlers directly: nothing here dials SQL.
 */
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { writeFileSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

type Result = { isError?: boolean; text: string };
const PROBE = new URL("./.tool-errors-probe.tmp.mts", import.meta.url);
let results: Record<string, Result> = {};

before(async () => {
  writeFileSync(PROBE, `
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerTools } from "../src/tools.js";
import { initInstances } from "../src/connectionManager.js";
initInstances();   // as index.ts does at startup
const s = new McpServer({ name: "probe", version: "0" });
const handlers: Record<string, (args: Record<string, unknown>) => Promise<{ isError?: boolean; content?: { text?: string }[] }>> = {};
const t = s as unknown as { tool: (...a: unknown[]) => unknown };
const orig = t.tool.bind(s);
t.tool = (name: unknown, ...rest: unknown[]) => { handlers[String(name)] = rest[rest.length - 1] as never; return orig(name, ...rest); };
registerTools(s);
const call = async (name: string, args: Record<string, unknown>) => {
  const r = await handlers[name](args);
  return { isError: r.isError, text: r.content?.[0]?.text ?? "" };
};
process.stdout.write(JSON.stringify({
  unknownInstance: await call("get_ag_health", { instance_name: "no-such-instance" }),
  dumpByFile: await call("read_sql_dump", { instance_name: "dev-node1", file: "not-a-dump.txt" }),
}));
`, "utf8");
  const env: Record<string, string | undefined> = { ...process.env };
  for (const k of ["SQL_CRED_TARGET", "SQL_USER", "SQL_PASSWORD", "ENG_WRITE_ENABLED", "DEV_WRITE_ENABLED", "SCHEMA_DOCS_ENABLED", "DBATOOLS_ENABLED", "FREEFORM_SQL_ENABLED", "SQL_SERVICE_IDENTITY"]) delete env[k];
  Object.assign(env, { TOOLSET: "dba", MCP_TRANSPORT: "http", INSTANCES_FILE: fileURLToPath(new URL("../../fleet.example.json", import.meta.url)) });
  results = await new Promise((resolve, reject) => {
    execFile(process.execPath, ["--import", "tsx", fileURLToPath(PROBE)], { encoding: "utf8", env, maxBuffer: 16 * 1024 * 1024 },
      (e, stdout) => (e ? reject(e) : resolve(JSON.parse(stdout))));
  });
});
after(() => rmSync(PROBE, { force: true }));

/** The text inside a result's fence (untrusted.ts) — failing the test if the fence is missing. */
function inside(fenced: string): string {
  const m = /^<<<UNTRUSTED DATA ([0-9a-f]{16}) [^\n]*>>>\n([\s\S]*)\n<<<END UNTRUSTED DATA \1>>>$/.exec(fenced);
  assert.ok(m, `not fenced: ${fenced.slice(0, 120)}`);
  return m[2];
}

test("a tool's own failure is flagged isError, so a gateway fails the call instead of citing it", () => {
  // Fenced like any result: an error message quotes what it was given, and that is data too.
  assert.match(inside(results.unknownInstance.text), /^Error: Unknown instance "no-such-instance"/);
  assert.equal(results.unknownInstance.isError, true);
});

test("read_sql_dump given a file and no action reads that file rather than listing again", () => {
  // The read path refuses this name before any SQL; the list path would have hit the HTTP
  // credential guard instead (no caller in this probe).
  assert.match(results.dumpByFile.text, /only reads SQLDump<NNNN>\.txt files\. 'not-a-dump\.txt'/);
  assert.equal(results.dumpByFile.isError, true);
});
