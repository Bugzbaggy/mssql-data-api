/**
 * The Streamable-HTTP session contract, against a real server process.
 *
 * A session lives in one process's memory. When that process goes (a restart, a redeploy, a
 * request routed to another replica) the client's next request carries a session id nobody here
 * holds, and the MCP spec's answer is 404: the one status that tells a client to open a new
 * session. This server answered 400, so a client — or a gateway that re-opens a session on 404 —
 * reported an error instead of recovering.
 */
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import { spawn, type ChildProcess } from "node:child_process";
import { fileURLToPath } from "node:url";

let child: ChildProcess;
let base = "";
let log = "";

const freePort = () => new Promise<number>((resolve, reject) => {
  const s = net.createServer().listen(0, "127.0.0.1", () => {
    const { port } = s.address() as net.AddressInfo;
    s.close(() => resolve(port));
  }).on("error", reject);
});

before(async () => {
  const port = await freePort();
  base = `http://127.0.0.1:${port}`;
  // Only what a process needs: never the developer's own SQL_* or FREEFORM_* variables.
  const env: Record<string, string> = Object.fromEntries(
    ["PATH", "Path", "SystemRoot", "TEMP", "TMP", "HOME", "USERPROFILE"]
      .filter((k) => process.env[k] !== undefined).map((k) => [k, process.env[k] as string]));
  Object.assign(env, {
    MCP_TRANSPORT: "http", PORT: String(port), MCP_AUTH_MODE: "off", TOOLSET: "dba",
    INSTANCES_FILE: fileURLToPath(new URL("../../fleet.example.json", import.meta.url)), DEFAULT_INSTANCE: "dev-node1",
    DBATOOLS_ENABLED: "false", SCHEMA_DOCS_ENABLED: "false", MCP_RATE_LIMIT_PER_MIN: "0",
  });
  child = spawn(process.execPath, ["--import", "tsx", fileURLToPath(new URL("../src/index.ts", import.meta.url))],
    { env, stdio: ["ignore", "pipe", "pipe"] });
  child.stdout?.on("data", (d) => (log += d));
  child.stderr?.on("data", (d) => (log += d));
  for (let i = 0; i < 120; i++) {
    try { if ((await fetch(`${base}/health`)).ok) return; } catch { /* not listening yet */ }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`server never answered /health:\n${log.slice(-1500)}`);
});
after(() => { child?.kill(); });

const post = (body: unknown, session?: string) => fetch(`${base}/mcp`, {
  method: "POST",
  headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream", ...(session ? { "mcp-session-id": session } : {}) },
  body: JSON.stringify(body),
});
const initialize = { jsonrpc: "2.0", id: 1, method: "initialize",
  params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "httpSessions.test", version: "1" } } };
const call = { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "list_instances", arguments: {} } };

test("control: initialize opens a session, and the session serves a call", async () => {
  const init = await post(initialize);
  assert.equal(init.status, 200);
  const sid = init.headers.get("mcp-session-id");
  assert.ok(sid, "initialize returned no mcp-session-id");
  await init.text();
  assert.equal((await post({ jsonrpc: "2.0", method: "notifications/initialized" }, sid)).status, 202);
  const r = await post(call, sid);
  assert.equal(r.status, 200);
  assert.match(await r.text(), /dev-node1/);
});

test("a session id this process does not hold is a 404 with JSON-RPC -32001 (POST)", async () => {
  const r = await post(call, "00000000-0000-4000-8000-000000000000");
  assert.equal(r.status, 404, "a client re-opens a session on 404 only");
  const body = await r.json() as { jsonrpc?: string; error?: { code?: number } };
  assert.equal(body.jsonrpc, "2.0");
  assert.equal(body.error?.code, -32001);
});

test("a session id this process does not hold is a 404 (GET, the server-to-client stream)", async () => {
  const r = await fetch(`${base}/mcp`, { headers: { Accept: "text/event-stream", "mcp-session-id": "00000000-0000-4000-8000-000000000000" } });
  assert.equal(r.status, 404);
  await r.text();
});

test("no session id on a request that is not initialize stays a 400", async () => {
  const r = await post(call);
  assert.equal(r.status, 400);
  await r.text();
  const g = await fetch(`${base}/mcp`, { headers: { Accept: "text/event-stream" } });
  assert.equal(g.status, 400);
  await g.text();
});

test("/health says only that the process is up — no instance, session count or tool list", async () => {
  const r = await fetch(`${base}/health`);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { status: "ok" });
});

test("the startup log states the surface the process serves, before anyone connects", () => {
  const line = log.split(/\r?\n/).find((l) => l.includes("[mcp] serving "));
  assert.ok(line, `no "[mcp] serving" line in:\n${log.slice(-1500)}`);
  assert.match(line, /toolset=dba/);
  assert.match(line, /\blist_instances\b/);
  assert.doesNotMatch(line, /\bexecute_query\b/, "free-form SQL is off on HTTP by default");
});
