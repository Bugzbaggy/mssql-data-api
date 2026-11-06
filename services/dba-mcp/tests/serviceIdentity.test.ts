/**
 * The service identity, behind an upstream gateway that issues JWTs, end to end in-process: a
 * token verifies against that issuer's own key set, the server starts without an Entra client id,
 * and the service login is reachable ONLY for a caller such a token identified.
 *
 * Each of these fails in a way no test with MCP_AUTH_MODE=off can see: without MCP_JWKS_URI support
 * every call 401s (only Entra's keys are consulted); demanding ENTRA_CLIENT_ID stops the process
 * from starting; and without a service-identity branch the HTTP credential guard refuses every tool.
 */
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { generateKeyPair, exportJWK, SignJWT } from "jose";
import { resolveSqlCredential, agentAppName, type DbCredentials } from "../src/connectionManager.js";
import { loadAuthConfig, buildVerifier, identityFromAuth } from "../src/auth.js";
import { InsufficientScopeError, InvalidTokenError, ServerError } from "@modelcontextprotocol/sdk/server/auth/errors.js";

const SVC = { user: "svc_sqldiag", password: "from-the-secret-store" };
const AUDIENCE = "appdb-sql-mcp";
const ROLE = "appdb-sql-mcp-reader";
const verified = (claims: { sub?: string; oid?: string; upn?: string }): DbCredentials =>
  ({ user: "", password: "", entra: { token: "eyJ.verified.token", ...claims } });

// ── resolveSqlCredential ─────────────────────────────────────────────────────

test("stdio uses the process credential, as before", () => {
  assert.deepEqual(resolveSqlCredential(undefined, SVC, { http: false, serviceIdentity: false }),
    { user: "svc_sqldiag", password: SVC.password, identity: "svc_sqldiag", credentialKey: "svc_sqldiag" });
});

test("on the per-user HTTP service a caller's own X-DB-* login wins", () => {
  const r = resolveSqlCredential({ user: "dba_alice", password: "own" }, SVC, { http: true, serviceIdentity: false });
  assert.deepEqual([r.user, r.password, r.identity], ["dba_alice", "own", "dba_alice"]);
  assert.match(r.credentialKey, /^hdr:dba_alice:[A-Za-z0-9_-]{22}$/);
});

test("the service-identity deployment refuses X-DB-* outright, verified caller or not", () => {
  // Otherwise a caller could connect as any login it holds, or lock svc_sqldiag out with bad passwords.
  for (const ctx of [
    { user: "svc_sqldiag", password: "a-guess" },
    { user: "svc:svc_sqldiag:agent-a@example.com", password: "x" },
    { ...verified({ sub: "agent-a@example.com" }), user: "sa", password: "x" },
    { ...verified({ sub: "agent-a@example.com" }), user: "", password: "x" },
  ] as DbCredentials[]) {
    assert.throws(() => resolveSqlCredential(ctx, SVC, { http: true, serviceIdentity: true }), /not accepted on this deployment/);
  }
});

test("a caller-supplied login's pool is keyed on its password too, never on the bare name", () => {
  const key = (user: string, password: string) =>
    resolveSqlCredential({ user, password }, SVC, { http: true, serviceIdentity: false }).credentialKey;
  // The bypass this closes: a request naming a DBA's login with a wrong password reused the DBA's
  // already-authenticated pool, because a connected pool is returned without a password check.
  assert.notEqual(key("dba_alice", "right"), key("dba_alice", "wrong"));
  assert.equal(key("dba_alice", "right"), key("dba_alice", "right"));
  assert.ok(!key("dba_alice", "right").includes("right"), "the password itself never appears in the key");
  // A user name shaped like a service-identity key still lands in its own namespace.
  assert.ok(key("svc:svc_sqldiag:agent-a@example.com", "x").startsWith("hdr:"));
});

test("HTTP without headers is refused unless service identity is on (per-user identity holds by default)", () => {
  assert.throws(() => resolveSqlCredential(verified({ sub: "agent-a@example.com" }), SVC, { http: true, serviceIdentity: false }), /never falls back/);
  assert.throws(() => resolveSqlCredential(undefined, SVC, { http: true, serviceIdentity: false }), /never falls back/);
});

test("with service identity on, an unverified request still gets NOTHING", () => {
  assert.throws(() => resolveSqlCredential(undefined, SVC, { http: true, serviceIdentity: true }), /No verified caller/);
  assert.throws(() => resolveSqlCredential({ user: "", password: "" }, SVC, { http: true, serviceIdentity: true }), /No verified caller/);
  // An identity block without a token is not a verified caller (index.ts sets it only from req.auth).
  assert.throws(() => resolveSqlCredential({ user: "", password: "", entra: { token: "", sub: "agent-a@example.com" } }, SVC, { http: true, serviceIdentity: true }), /No verified caller/);
});

test("a verified caller gets the service login, in a pool of its own", () => {
  const a = resolveSqlCredential(verified({ sub: "agent-a@example.com" }), SVC, { http: true, serviceIdentity: true });
  assert.deepEqual(a, { user: "svc_sqldiag", password: SVC.password, identity: "svc:svc_sqldiag:agent-a@example.com",
    credentialKey: "svc:svc_sqldiag:agent-a@example.com", caller: "agent-a@example.com" });
  const b = resolveSqlCredential(verified({ sub: "agent-b@example.com" }), SVC, { http: true, serviceIdentity: true });
  assert.notEqual(a.identity, b.identity, "two agent principals must never share a pool");
  assert.equal(resolveSqlCredential(verified({ oid: "o-1" }), SVC, { http: true, serviceIdentity: true }).caller, "o-1");
  assert.equal(resolveSqlCredential(verified({ upn: "u@example.com" }), SVC, { http: true, serviceIdentity: true }).caller, "u@example.com");
});

test("service identity on but no service login configured is an explicit error", () => {
  assert.throws(() => resolveSqlCredential(verified({ sub: "agent-a@example.com" }), {}, { http: true, serviceIdentity: true }), /not configured/);
});

test("the caller is carried into program_name, sanitised and bounded", () => {
  assert.equal(agentAppName("agent-a@example.com"), "appdb-sql-mcp (agent) for=agent-a@example.com");
  const odd = agentAppName("a b;c'" + "x".repeat(300));
  assert.ok(odd.length <= 128, `program_name is 128 chars at most, got ${odd.length}`);
  assert.doesNotMatch(odd.slice(odd.indexOf("for=") + 4), /[ ;']/, "the caller part carries no space, semicolon or quote");
});

// ── A gateway's token verification, against a real (local) JWKS ─────────────

const ISSUER = "https://gateway-issuer.test";
let jwksServer: http.Server;
let jwksUrl = "";
let key: Awaited<ReturnType<typeof generateKeyPair>>;
let otherKey: Awaited<ReturnType<typeof generateKeyPair>>;
const saved: Record<string, string | undefined> = {};
const ENV = ["MCP_AUTH_MODE", "MCP_JWKS_URI", "ENTRA_ISSUER", "ENTRA_API_AUDIENCE", "ENTRA_REQUIRED_SCOPES", "ENTRA_CLIENT_ID"];

before(async () => {
  key = await generateKeyPair("RS256");
  otherKey = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(key.publicKey)), kid: "test-key-1", alg: "RS256", use: "sig" };
  jwksServer = http.createServer((_req, res) => { res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify({ keys: [jwk] })); });
  await new Promise<void>((ok) => jwksServer.listen(0, "127.0.0.1", ok));
  jwksUrl = `http://127.0.0.1:${(jwksServer.address() as { port: number }).port}/.well-known/jwks.json`;
  for (const k of ENV) saved[k] = process.env[k];
  Object.assign(process.env, {
    MCP_AUTH_MODE: "required", MCP_JWKS_URI: jwksUrl, ENTRA_ISSUER: ISSUER,
    ENTRA_API_AUDIENCE: AUDIENCE, ENTRA_REQUIRED_SCOPES: ROLE,
  });
  delete process.env.ENTRA_CLIENT_ID;
});
after(() => {
  jwksServer.close();
  for (const k of ENV) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
});

async function gatewayToken(over: { aud?: string; roles?: string[]; exp?: number; signer?: typeof key; sub?: string } = {}): Promise<string> {
  return new SignJWT({ roles: over.roles ?? [ROLE] })
    .setProtectedHeader({ alg: "RS256", kid: "test-key-1" })
    .setIssuer(ISSUER).setAudience(over.aud ?? AUDIENCE).setSubject(over.sub ?? "agent-a@example.com")
    .setIssuedAt().setExpirationTime(over.exp ?? Math.floor(Date.now() / 1000) + 300)
    .sign((over.signer ?? key).privateKey);
}

test("a gateway config loads with no ENTRA_CLIENT_ID", () => {
  const cfg = loadAuthConfig();
  assert.equal(cfg.jwksUri, jwksUrl);
  assert.equal(cfg.audience, AUDIENCE);
  assert.deepEqual(cfg.requiredScopes, [ROLE]);
});

test("the Entra path still demands a client id when no key set is named", () => {
  const prev = process.env.MCP_JWKS_URI;
  delete process.env.MCP_JWKS_URI;
  try { assert.throws(() => loadAuthConfig(), /ENTRA_CLIENT_ID is missing/); }
  finally { process.env.MCP_JWKS_URI = prev; }
});

test("a gateway token verifies against MCP_JWKS_URI, and its sub becomes the caller", async () => {
  const auth = await buildVerifier(loadAuthConfig()).verifyAccessToken(await gatewayToken());
  assert.ok(auth.scopes.includes(ROLE));
  const id = identityFromAuth(auth);
  assert.equal(id?.sub, "agent-a@example.com");
  // The identity index.ts threads into the request is exactly what resolveSqlCredential admits.
  const cred = resolveSqlCredential({ user: "", password: "", entra: id }, SVC, { http: true, serviceIdentity: true });
  assert.equal(cred.identity, "svc:svc_sqldiag:agent-a@example.com");
});

// requireBearerAuth answers 401/403 only for the SDK's own OAuth error classes and turns anything
// else into a 500 — so the class is the HTTP status the caller sees, and is what is pinned here.
const refusedAs = (cls: new (m: string) => Error, msg: RegExp) => (e: unknown) => {
  assert.ok(e instanceof cls, `expected ${cls.name}, got ${(e as Error)?.constructor?.name}: ${(e as Error)?.message}`);
  assert.match((e as Error).message, msg);
  assert.doesNotMatch((e as Error).message, /"/, "the message lands in a quoted WWW-Authenticate parameter");
  return true;
};

test("wrong audience, a foreign key and an expired token are 401s; a missing role is a 403", async () => {
  const v = buildVerifier(loadAuthConfig());
  await assert.rejects(v.verifyAccessToken(await gatewayToken({ aud: "appdb-data-api" })), refusedAs(InvalidTokenError, /aud/i));
  await assert.rejects(v.verifyAccessToken(await gatewayToken({ signer: otherKey })), refusedAs(InvalidTokenError, /signature|no applicable key/i));
  await assert.rejects(v.verifyAccessToken(await gatewayToken({ exp: Math.floor(Date.now() / 1000) - 60 })), refusedAs(InvalidTokenError, /exp/i));
  await assert.rejects(v.verifyAccessToken("not.a.jwt"), refusedAs(InvalidTokenError, /./));
  await assert.rejects(v.verifyAccessToken(await gatewayToken({ roles: ["appdb-data-api-reader"] })), refusedAs(InsufficientScopeError, /missing required scope/));
});

test("a key set this server cannot fetch is a server error, not the caller's bad token", async () => {
  // A 401 here would send every client to re-authenticate against an outage of ours.
  const v = buildVerifier({ ...loadAuthConfig(), jwksUri: "http://127.0.0.1:1/.well-known/jwks.json" });
  await assert.rejects(v.verifyAccessToken(await gatewayToken()), refusedAs(ServerError, /could not verify/i));
});

test("a key set that answers with an error, or with something not JSON, is a server error too", async () => {
  // jose reports both as its generic JOSEError, which would otherwise map to a 401: an issuer
  // outage would read as "this caller's token is bad".
  for (const [status, body] of [[503, "unavailable"], [200, "not json"]] as const) {
    const srv = http.createServer((_req, res) => { res.writeHead(status, { "content-type": "application/json" }); res.end(body); });
    await new Promise<void>((ok) => srv.listen(0, "127.0.0.1", ok));
    try {
      const v = buildVerifier({ ...loadAuthConfig(), jwksUri: `http://127.0.0.1:${(srv.address() as { port: number }).port}/.well-known/jwks.json` });
      await assert.rejects(v.verifyAccessToken(await gatewayToken()), refusedAs(ServerError, /could not verify/i), `key set HTTP ${status}`);
    } finally {
      await new Promise<void>((ok) => srv.close(() => ok()));
    }
  }
});

// ── The startup refusal, in a real server process ─────────────────────────────

test("the server refuses to start with service identity on and auth not required", async () => {
  const env: Record<string, string | undefined> = { ...process.env, MCP_TRANSPORT: "http", SQL_SERVICE_IDENTITY: "1", MCP_AUTH_MODE: "off",
    PORT: "0", INSTANCES_FILE: fileURLToPath(new URL("../../fleet.example.json", import.meta.url)) };
  for (const k of ["SQL_CRED_TARGET", "MCP_JWKS_URI"]) delete env[k];
  const r = await new Promise<{ code: number | null; stderr: string }>((resolve) => {
    execFile(process.execPath, ["--import", "tsx", fileURLToPath(new URL("../src/index.ts", import.meta.url))],
      { env, encoding: "utf8", timeout: 60_000 }, (e, _out, stderr) => resolve({ code: (e as { code?: number } | null)?.code ?? 0, stderr }));
  });
  assert.equal(r.code, 1, `expected exit 1, got ${r.code}; stderr: ${r.stderr.slice(-400)}`);
  assert.match(r.stderr, /SQL_SERVICE_IDENTITY=1 requires MCP_AUTH_MODE=required/);
});
