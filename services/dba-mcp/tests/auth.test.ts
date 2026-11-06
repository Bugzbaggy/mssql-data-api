/**
 * The token's audience must be exactly this server's.
 *
 * jose's `audience` option — and most service meshes' JWT policies — accept a token whose `aud`
 * ARRAY merely contains ours. A token minted for several services at once is such an array: one
 * credential for every backend behind a gateway. A caller holding it could call /mcp around the
 * gateway, which would otherwise exchange it for a token minted for this server alone. So the
 * verifier refuses any `aud` but exactly ours, with a 401.
 */
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { generateKeyPair, exportJWK, SignJWT } from "jose";
import { InvalidTokenError } from "@modelcontextprotocol/sdk/server/auth/errors.js";
import { audienceIsExactly, buildVerifier, type EntraAuthConfig } from "../src/auth.js";

const ISSUER = "https://auth-audience.test";
const AUD = "appdb-sql-mcp";
const OTHER = "appdb-data-api";
const ROLE = "appdb-sql-mcp-reader";
let jwks: http.Server;
let key: Awaited<ReturnType<typeof generateKeyPair>>;
let verify: (token: string) => Promise<unknown>;

const token = (aud: string | string[]) => new SignJWT({ roles: [ROLE] })
  .setProtectedHeader({ alg: "RS256", kid: "test-key-1" }).setIssuer(ISSUER).setAudience(aud)
  .setSubject("agent@example.com").setIssuedAt().setExpirationTime("5m").sign(key.privateKey);

before(async () => {
  key = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(key.publicKey)), kid: "test-key-1", alg: "RS256", use: "sig" };
  jwks = http.createServer((_q, r) => { r.writeHead(200, { "Content-Type": "application/json" }); r.end(JSON.stringify({ keys: [jwk] })); });
  await new Promise<void>((ok) => jwks.listen(0, "127.0.0.1", ok));
  const { port } = jwks.address() as { port: number };
  const cfg: EntraAuthConfig = {
    mode: "required", tenantId: "", clientId: "", audience: AUD, issuer: ISSUER, requiredScopes: [ROLE],
    resourceUrl: "", jwksUri: `http://127.0.0.1:${port}/.well-known/jwks.json`,
  };
  const verifier = buildVerifier(cfg);
  verify = (t) => verifier.verifyAccessToken(t);
});
after(() => jwks?.close());

test("audienceIsExactly: one audience, and it is ours", () => {
  assert.equal(audienceIsExactly(AUD, AUD), true);
  assert.equal(audienceIsExactly([AUD], AUD), true, "RFC 7519 allows a one-element array");
  assert.equal(audienceIsExactly([AUD, OTHER], AUD), false, "a token for several services");
  assert.equal(audienceIsExactly([OTHER, AUD], AUD), false);
  assert.equal(audienceIsExactly(OTHER, AUD), false);
  assert.equal(audienceIsExactly([], AUD), false);
  assert.equal(audienceIsExactly(undefined, AUD), false);
});

test("a token minted for this server alone is accepted, as a string or a one-element array", async () => {
  await verify(await token(AUD));
  await verify(await token([AUD]));
});

test("a multi-audience token is refused as invalid (401), though jose itself would pass it", async () => {
  const refusedOnAudience = (e: unknown) => e instanceof InvalidTokenError && /audience must be exactly 'appdb-sql-mcp'/.test((e as Error).message);
  await assert.rejects(async () => verify(await token([AUD, OTHER, "appdb-ops"])), refusedOnAudience);
  await assert.rejects(async () => verify(await token(["appdb-ops", AUD])), refusedOnAudience);
});

test("a token for another service only is refused too", async () => {
  await assert.rejects(async () => verify(await token(OTHER)), InvalidTokenError);
});
