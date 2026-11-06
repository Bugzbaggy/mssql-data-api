/**
 * A Streamable-HTTP session belongs to the verified caller who opened it.
 *
 * Sessions are keyed by an unguessable id, but nothing tied the id to its caller: a second verified
 * principal who learned it (a log line, a proxy, a shared notebook) could POST into the session, open
 * its server-to-client stream — receiving tool results that carry literal statement text — or DELETE
 * it mid-investigation. With auth required, the opener's identity is bound to the session, and any
 * other caller presenting the id gets exactly what an unknown id gets: 404, so the binding leaks no
 * signal that the session exists. The opener with a refreshed token (same subject) keeps working.
 */
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import net from "node:net";
import { spawn, type ChildProcess } from "node:child_process";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import { generateKeyPair, exportJWK, SignJWT } from "jose";

const ISSUER = "https://session-binding.test";
const AUDIENCE = "appdb-sql-mcp";
const ROLE = "appdb-sql-mcp-reader";
let jwks: http.Server;
let key: Awaited<ReturnType<typeof generateKeyPair>>;
let server: ChildProcess;
let base = "";

const freePort = () => new Promise<number>((resolve, reject) => {
  const s = net.createServer().listen(0, "127.0.0.1", () => {
    const { port } = s.address() as net.AddressInfo;
    s.close(() => resolve(port));
  }).on("error", reject);
});

let issued = 0;
const token = (sub: string) => new SignJWT({ roles: [ROLE], n: ++issued })
  .setProtectedHeader({ alg: "RS256", kid: "test-key-1" }).setIssuer(ISSUER).setAudience(AUDIENCE)
  .setSubject(sub).setIssuedAt().setExpirationTime("5m").sign(key.privateKey);

const headers = (bearer: string, session?: string): Record<string, string> => ({
  "Content-Type": "application/json", Accept: "application/json, text/event-stream",
  Authorization: `Bearer ${bearer}`, ...(session ? { "mcp-session-id": session } : {}),
});
const post = async (bearer: string, body: unknown, session?: string) => {
  const r = await fetch(`${base}/mcp`, { method: "POST", headers: headers(bearer, session), body: JSON.stringify(body) });
  return { status: r.status, session: r.headers.get("mcp-session-id"), text: await r.text() };
};
const initialize = { jsonrpc: "2.0", id: 1, method: "initialize",
  params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "sessionBinding.test", version: "1" } } };
const call = { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "list_instances", arguments: {} } };

async function openSession(bearer: string): Promise<string> {
  const init = await post(bearer, initialize);
  assert.equal(init.status, 200, init.text);
  assert.ok(init.session);
  assert.equal((await post(bearer, { jsonrpc: "2.0", method: "notifications/initialized" }, init.session)).status, 202);
  return init.session;
}

before(async () => {
  key = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(key.publicKey)), kid: "test-key-1", alg: "RS256", use: "sig" };
  jwks = http.createServer((_q, r) => { r.writeHead(200, { "Content-Type": "application/json" }); r.end(JSON.stringify({ keys: [jwk] })); });
  await new Promise<void>((ok) => jwks.listen(0, "127.0.0.1", ok));
  const port = await freePort();
  base = `http://127.0.0.1:${port}`;
  const env: Record<string, string> = Object.fromEntries(
    ["PATH", "Path", "SystemRoot", "TEMP", "TMP", "HOME", "USERPROFILE"]
      .filter((k) => process.env[k] !== undefined).map((k) => [k, process.env[k] as string]));
  Object.assign(env, {
    MCP_TRANSPORT: "http", PORT: String(port), TOOLSET: "dba", DEFAULT_INSTANCE: "dev-node1",
    INSTANCES_FILE: fileURLToPath(new URL("../../fleet.example.json", import.meta.url)),
    DBATOOLS_ENABLED: "false", SCHEMA_DOCS_ENABLED: "false", MCP_RATE_LIMIT_PER_MIN: "0",
    MCP_AUTH_MODE: "required", ENTRA_ISSUER: ISSUER, ENTRA_API_AUDIENCE: AUDIENCE,
    MCP_JWKS_URI: `http://127.0.0.1:${(jwks.address() as net.AddressInfo).port}/.well-known/jwks.json`,
    ENTRA_REQUIRED_SCOPES: ROLE, MCP_PUBLIC_URL: "http://127.0.0.1",
  });
  server = spawn(process.execPath, ["--import", "tsx", fileURLToPath(new URL("../src/index.ts", import.meta.url))],
    { env, stdio: ["ignore", "pipe", "pipe"] });
  let log = "";
  server.stdout?.on("data", (d) => (log += d));
  server.stderr?.on("data", (d) => (log += d));
  for (let i = 0; i < 120; i++) {
    try { if ((await fetch(`${base}/health`)).ok) return; } catch { /* not yet */ }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`server never answered /health:\n${log.slice(-1500)}`);
});
after(() => { server?.kill(); jwks?.close(); });

test("another verified caller cannot use, stream from, or close someone else's session", async () => {
  const alice = await token("alice@example.com");
  const sid = await openSession(alice);
  const mallory = await token("mallory@example.com");

  const hijackPost = await post(mallory, call, sid);
  assert.equal(hijackPost.status, 404, "POST into another caller's session");
  assert.match(hijackPost.text, /-32001/);

  const hijackGet = await fetch(`${base}/mcp`, { headers: { Accept: "text/event-stream", Authorization: `Bearer ${mallory}`, "mcp-session-id": sid } });
  assert.equal(hijackGet.status, 404, "GET (the server-to-client stream) of another caller's session");
  await hijackGet.text();

  const hijackDelete = await fetch(`${base}/mcp`, { method: "DELETE", headers: headers(mallory, sid) });
  assert.equal(hijackDelete.status, 404, "DELETE of another caller's session");
  await hijackDelete.text();

  // Alice's session survived all three, and answers her.
  const mine = await post(alice, call, sid);
  assert.equal(mine.status, 200, mine.text);
  assert.match(mine.text, /dev-node1/);
});

test("the opener keeps the session across a token refresh (same subject, new token)", async () => {
  const sid = await openSession(await token("bob@example.com"));
  const refreshed = await token("bob@example.com");
  const r = await post(refreshed, call, sid);
  assert.equal(r.status, 200, r.text);
});

test("the opener can close their own session, after which it is gone", async () => {
  const carol = await token("carol@example.com");
  const sid = await openSession(carol);
  const del = await fetch(`${base}/mcp`, { method: "DELETE", headers: headers(carol, sid) });
  assert.equal(del.status, 200);
  await del.text();
  assert.equal((await post(carol, call, sid)).status, 404);
});

test("a foreign session id is answered exactly like an id that does not exist", async () => {
  const sid = await openSession(await token("dave@example.com"));
  const eve = await token("eve@example.com");
  const unknown = randomUUID();
  for (const method of ["POST", "GET", "DELETE"]) {
    const ask = async (id: string) => {
      const r = await fetch(`${base}/mcp`, { method, headers: headers(eve, id), ...(method === "POST" ? { body: JSON.stringify(call) } : {}) });
      return `${r.status} ${(await r.text()).replaceAll(id, "<id>")}`;
    };
    assert.equal(await ask(sid), await ask(unknown), method);
  }
});

test("a verified token that names no caller opens no session", async () => {
  const nobody = await new SignJWT({ roles: [ROLE] })
    .setProtectedHeader({ alg: "RS256", kid: "test-key-1" }).setIssuer(ISSUER).setAudience(AUDIENCE)
    .setIssuedAt().setExpirationTime("5m").sign(key.privateKey);
  const r = await post(nobody, initialize);
  assert.equal(r.status, 403, r.text);
  assert.equal(r.session, null);
});
