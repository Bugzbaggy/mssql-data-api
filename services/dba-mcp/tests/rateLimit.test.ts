/**
 * The /mcp rate limit, against a real server process.
 *
 * Behind a gateway or a service mesh every request reaches the process from the same proxy
 * address, so a limit keyed on that address is one bucket for ALL callers: one busy agent
 * exhausts it and every other session is refused at once — during exactly the kind of incident
 * the agent exists for. With a verified token the key is the caller; without one
 * (MCP_AUTH_MODE=off, the X-DB-* header deployment) it stays the source address.
 */
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import net from "node:net";
import { spawn, type ChildProcess } from "node:child_process";
import { fileURLToPath } from "node:url";
import { generateKeyPair, exportJWK, SignJWT } from "jose";

const ISSUER = "https://rate-limit.test";
const AUDIENCE = "appdb-sql-mcp";
const ROLE = "appdb-sql-mcp-reader";
const LIMIT = 4;
let jwks: http.Server;
let jwksUrl = "";
let key: Awaited<ReturnType<typeof generateKeyPair>>;
const servers: ChildProcess[] = [];

const freePort = () => new Promise<number>((resolve, reject) => {
  const s = net.createServer().listen(0, "127.0.0.1", () => {
    const { port } = s.address() as net.AddressInfo;
    s.close(() => resolve(port));
  }).on("error", reject);
});

async function startServer(extra: Record<string, string>): Promise<string> {
  const port = await freePort();
  const env: Record<string, string> = Object.fromEntries(
    ["PATH", "Path", "SystemRoot", "TEMP", "TMP", "HOME", "USERPROFILE"]
      .filter((k) => process.env[k] !== undefined).map((k) => [k, process.env[k] as string]));
  Object.assign(env, {
    MCP_TRANSPORT: "http", PORT: String(port), TOOLSET: "dba", DEFAULT_INSTANCE: "dev-node1",
    INSTANCES_FILE: fileURLToPath(new URL("../../fleet.example.json", import.meta.url)),
    DBATOOLS_ENABLED: "false", SCHEMA_DOCS_ENABLED: "false", MCP_RATE_LIMIT_PER_MIN: String(LIMIT),
  }, extra);
  const child = spawn(process.execPath, ["--import", "tsx", fileURLToPath(new URL("../src/index.ts", import.meta.url))],
    { env, stdio: ["ignore", "pipe", "pipe"] });
  servers.push(child);
  let log = "";
  child.stdout?.on("data", (d) => (log += d));
  child.stderr?.on("data", (d) => (log += d));
  const base = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 120; i++) {
    try { if ((await fetch(`${base}/health`)).ok) return base; } catch { /* not yet */ }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`server never answered /health:\n${log.slice(-1500)}`);
}

const token = (sub: string) => new SignJWT({ roles: [ROLE] })
  .setProtectedHeader({ alg: "RS256", kid: "test-key-1" }).setIssuer(ISSUER).setAudience(AUDIENCE)
  .setSubject(sub).setIssuedAt().setExpirationTime("5m").sign(key.privateKey);
const initialize = (base: string, bearer?: string) => fetch(`${base}/mcp`, {
  method: "POST",
  headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream", ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}) },
  body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "rateLimit.test", version: "1" } } }),
}).then(async (r) => { await r.text(); return r.status; });

before(async () => {
  key = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(key.publicKey)), kid: "test-key-1", alg: "RS256", use: "sig" };
  jwks = http.createServer((_q, r) => { r.writeHead(200, { "Content-Type": "application/json" }); r.end(JSON.stringify({ keys: [jwk] })); });
  await new Promise<void>((ok) => jwks.listen(0, "127.0.0.1", ok));
  jwksUrl = `http://127.0.0.1:${(jwks.address() as net.AddressInfo).port}/.well-known/jwks.json`;
});
after(() => { for (const s of servers) s.kill(); jwks?.close(); });

test("with auth required, each verified caller has its own budget — one busy caller does not starve another", async () => {
  const base = await startServer({
    MCP_AUTH_MODE: "required", ENTRA_ISSUER: ISSUER, ENTRA_API_AUDIENCE: AUDIENCE, MCP_JWKS_URI: jwksUrl,
    ENTRA_REQUIRED_SCOPES: ROLE, MCP_PUBLIC_URL: "http://127.0.0.1",
  });
  const a = await token("agent-a@example.com");
  for (let i = 0; i < LIMIT; i++) assert.equal(await initialize(base, a), 200, `caller A request ${i + 1}`);
  assert.equal(await initialize(base, a), 429, "caller A is over its own budget");
  // Same source address, different verified caller: a bucket of its own.
  assert.equal(await initialize(base, await token("agent-b@example.com")), 200, "caller B must not inherit A's exhaustion");
  // A request with no token is refused by auth and spends nobody's budget.
  for (let i = 0; i < LIMIT + 2; i++) assert.equal(await initialize(base), 401);
  assert.equal(await initialize(base, await token("agent-c@example.com")), 200);
});

test("with auth off (the X-DB-* header deployment), the budget stays per source address", async () => {
  const base = await startServer({ MCP_AUTH_MODE: "off" });
  for (let i = 0; i < LIMIT; i++) assert.equal(await initialize(base), 200, `request ${i + 1}`);
  assert.equal(await initialize(base), 429);
});
