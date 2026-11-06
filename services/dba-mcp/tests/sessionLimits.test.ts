/**
 * Sessions are bounded on the server, because no client is obliged to close one.
 *
 * A gateway that opens a session per tool call and never closes it would leave one McpServer per
 * call in memory, and nothing ever freed them. Now a session idle for MCP_SESSION_IDLE_SECONDS is
 * closed, and at MCP_MAX_SESSIONS a new session closes the least recently used IDLE one. A
 * session with a request in flight (a long tools/call, an open GET stream) is never closed under
 * it; when every session is busy, a new one is refused with 503. A closed session answers 404 —
 * the status that tells a client to open a new one.
 */
import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import { spawn, type ChildProcess } from "node:child_process";
import { fileURLToPath } from "node:url";

const freePort = () => new Promise<number>((resolve, reject) => {
  const s = net.createServer().listen(0, "127.0.0.1", () => {
    const { port } = s.address() as net.AddressInfo;
    s.close(() => resolve(port));
  }).on("error", reject);
});
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

type Server = { base: string; stop: () => void; log: () => string };

async function startServer(extra: Record<string, string>): Promise<Server> {
  const port = await freePort();
  const base = `http://127.0.0.1:${port}`;
  // Only what a process needs: never the developer's own SQL_* or FREEFORM_* variables.
  const env: Record<string, string> = Object.fromEntries(
    ["PATH", "Path", "SystemRoot", "TEMP", "TMP", "HOME", "USERPROFILE"]
      .filter((k) => process.env[k] !== undefined).map((k) => [k, process.env[k] as string]));
  Object.assign(env, {
    MCP_TRANSPORT: "http", PORT: String(port), MCP_AUTH_MODE: "off", TOOLSET: "dba",
    INSTANCES_FILE: fileURLToPath(new URL("../../fleet.example.json", import.meta.url)), DEFAULT_INSTANCE: "dev-node1",
    DBATOOLS_ENABLED: "false", SCHEMA_DOCS_ENABLED: "false", MCP_RATE_LIMIT_PER_MIN: "0",
  }, extra);
  const child: ChildProcess = spawn(process.execPath, ["--import", "tsx", fileURLToPath(new URL("../src/index.ts", import.meta.url))],
    { env, stdio: ["ignore", "pipe", "pipe"] });
  let log = "";
  child.stdout?.on("data", (d) => (log += d));
  child.stderr?.on("data", (d) => (log += d));
  for (let i = 0; i < 120; i++) {
    try { if ((await fetch(`${base}/health`)).ok) return { base, stop: () => child.kill(), log: () => log }; } catch { /* not yet */ }
    await sleep(500);
  }
  child.kill();
  throw new Error(`server never answered /health:\n${log.slice(-1500)}`);
}

const initialize = { jsonrpc: "2.0", id: 1, method: "initialize",
  params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "sessionLimits.test", version: "1" } } };
const call = { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "list_instances", arguments: {} } };
const H = (session?: string): Record<string, string> => ({
  "Content-Type": "application/json", Accept: "application/json, text/event-stream", ...(session ? { "mcp-session-id": session } : {}),
});

function client(srv: Server) {
  const base = srv.base;
  const post = async (body: unknown, session?: string) => {
    const r = await fetch(`${base}/mcp`, { method: "POST", headers: H(session), body: JSON.stringify(body) });
    return { status: r.status, session: r.headers.get("mcp-session-id"), retryAfter: r.headers.get("retry-after"), text: await r.text() };
  };
  return {
    post,
    async open(): Promise<string> {
      const init = await post(initialize);
      assert.equal(init.status, 200, init.text);
      assert.ok(init.session);
      assert.equal((await post({ jsonrpc: "2.0", method: "notifications/initialized" }, init.session)).status, 202);
      return init.session;
    },
    /** Status of one tools/call in the session: 200 while it lives, 404 once it is closed. */
    async callStatus(session: string): Promise<number> { return (await post(call, session)).status; },
    /** Holds the session's GET stream open — a request in flight — until the returned abort() is called. */
    async stream(session: string): Promise<() => void> {
      const ac = new AbortController();
      const r = await fetch(`${base}/mcp`, { headers: { Accept: "text/event-stream", "mcp-session-id": session }, signal: ac.signal });
      assert.equal(r.status, 200, "GET stream opened");
      // The body is left unread, NOT cancelled: cancelling a fetch body closes the connection, which
      // is exactly the "request ended" this helper must hold off until abort().
      return () => ac.abort();
    },
    /** The server's own line for closing `session` (index.ts expire()), if it has written one yet. */
    closedLine(session: string): string | undefined {
      return srv.log().split(/\r?\n/).find((l) => l.includes("[mcp] Session ") && l.endsWith(`: ${session}`));
    },
    /**
     * Waits for the server to log that it closed `session`, up to the deadline. Reading the log
     * touches no session, where a tools/call would refresh the very session the sweep is meant to
     * close — and /health does not count sessions. A fixed sleep here would race the sweep on a
     * loaded machine; a deadline keeps the test about what the server does, not about timing.
     */
    async waitClosed(session: string, deadlineMs: number): Promise<string | undefined> {
      const end = Date.now() + deadlineMs;
      let line = this.closedLine(session);
      while (!line && Date.now() < end) { await sleep(250); line = this.closedLine(session); }
      return line;
    },
  };
}

describe("idle sessions are closed (MCP_SESSION_IDLE_SECONDS=2)", () => {
  let srv: Awaited<ReturnType<typeof startServer>>;
  let c: ReturnType<typeof client>;
  before(async () => { srv = await startServer({ MCP_SESSION_IDLE_SECONDS: "2" }); c = client(srv); });
  after(() => srv?.stop());

  test("a session left idle is closed, and then answers 404", async () => {
    const sid = await c.open();
    assert.equal(await c.callStatus(sid), 200);
    assert.equal(c.closedLine(sid), undefined, "not closed while it was just used");
    assert.match((await c.waitClosed(sid, 15_000)) ?? "never closed", /Session expired \(idle\)/, "the idle session was closed");
    assert.equal(await c.callStatus(sid), 404);
  });

  test("a session with a request in flight is not closed under it, and is once the request ends", async () => {
    const sid = await c.open();
    const abort = await c.stream(sid);
    await sleep(5000);   // well past the 2 s idle limit: only the open stream can be keeping it
    assert.equal(await c.callStatus(sid), 200, "the open GET stream kept the session alive");
    abort();
    assert.match((await c.waitClosed(sid, 15_000)) ?? "never closed", /Session expired \(idle\)/, "idle again once the stream closed, and closed");
    assert.equal(await c.callStatus(sid), 404);
  });
});

describe("the session count is capped (MCP_MAX_SESSIONS=3)", () => {
  let srv: Awaited<ReturnType<typeof startServer>>;
  let c: ReturnType<typeof client>;
  before(async () => { srv = await startServer({ MCP_MAX_SESSIONS: "3", MCP_SESSION_IDLE_SECONDS: "600" }); c = client(srv); });
  after(() => srv?.stop());

  const live: Record<string, string> = {};

  test("at the cap, a new session closes the least recently used idle one", async () => {
    live.b = await c.open();
    live.c = await c.open();
    live.d = await c.open();
    assert.equal(await c.callStatus(live.b), 200); // b is now more recent than c
    live.e = await c.open();
    assert.equal(await c.callStatus(live.c), 404, "c was the least recently used");
    for (const k of ["b", "d", "e"]) assert.equal(await c.callStatus(live[k]), 200, k);
    assert.match(c.closedLine(live.c) ?? "not closed", /Session evicted \(MCP_MAX_SESSIONS=3 reached\)/, "closed by the cap");
    for (const k of ["b", "d", "e"]) assert.equal(c.closedLine(live[k]), undefined, `${k} still open: three at the cap`);
  });

  test("a busy session is never evicted; with every session busy a new one gets 503", async () => {
    const aborts = { b: await c.stream(live.b), d: await c.stream(live.d), e: await c.stream(live.e) };
    try {
      const refused = await c.post(initialize);
      assert.equal(refused.status, 503, refused.text);
      assert.ok(refused.retryAfter, "503 carries Retry-After");
      assert.equal(refused.session, null);

      aborts.d();
      let opened: string | null = null;
      for (let i = 0; i < 25 && !opened; i++) { // the server sees the stream close a moment later
        const r = await c.post(initialize);
        if (r.status === 200) opened = r.session; else await sleep(200);
      }
      assert.ok(opened, "a session opened once one became idle");
      assert.equal(await c.callStatus(live.d), 404, "the only idle session was the one closed");
      for (const k of ["b", "e"] as const) assert.equal(await c.callStatus(live[k]), 200, `${k} kept its session while busy`);
    } finally {
      Object.values(aborts).forEach((a) => a());
    }
  });
});
