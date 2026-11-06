/**
 * Microsoft Entra (Azure AD) OAuth — this server as an OAuth *Resource Server*.
 *
 * This is the TypeScript counterpart to the reference MCP server's FastMCP `AzureProvider`,
 * but deliberately the *slim* half of it. the reference MCP server's AzureProvider does three
 * things: (1) a Dynamic-Client-Registration shim so Claude can register, (2) it
 * proxies authorize/token to Entra and mints its own JWT, and (3) On-Behalf-Of to
 * Power BI. Entra does **not** support DCR, so a 1:1 OAuth-proxy port would mean
 * hand-writing that shim. We don't: appdb-sql-mcp acts purely as a Resource Server.
 * It *verifies* Entra-issued access tokens (audience = our API) on every /mcp call;
 * the MCP client obtains those tokens from Entra directly (discovery via the
 * Protected-Resource-Metadata document we publish — see buildProtectedResourceMetadata).
 *
 * Any other OIDC issuer works the same way — for example an upstream gateway that issues
 * JWTs to the agents behind it: MCP_JWKS_URI names its key set, ENTRA_ISSUER its issuer and
 * ENTRA_API_AUDIENCE the audience it mints for this server.
 *
 * The OBO exchange that turns the verified user token into a *SQL* access token
 * (Path A) lives in connectionManager.ts, gated per-instance — see ENTRA_SQL_OBO.
 *
 * Auth is OFF by default (MCP_AUTH_MODE=off) so the existing X-DB-User/X-DB-Password
 * deployment keeps working until the Entra app + platform config are in place. Set
 * MCP_AUTH_MODE=required to enforce a valid JWT on every /mcp request.
 */

import { createRemoteJWKSet, jwtVerify, errors as joseErrors, type JWTPayload } from "jose";
import { InsufficientScopeError, InvalidTokenError, ServerError } from "@modelcontextprotocol/sdk/server/auth/errors.js";
import type { OAuthTokenVerifier } from "@modelcontextprotocol/sdk/server/auth/provider.js";
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js";

export type AuthMode = "off" | "optional" | "required";

export interface EntraAuthConfig {
  mode: AuthMode;
  tenantId: string;
  /** App (client) ID of THIS server's Entra app registration. */
  clientId: string;
  /** Token audience we accept — the "Expose an API" App ID URI, default api://{clientId}. */
  audience: string;
  /** Issuer we accept — the v2 issuer for our tenant. */
  issuer: string;
  /** Scopes the caller's token MUST carry (the custom API scope, e.g. access_as_user). */
  requiredScopes: string[];
  /** This server's public resource identifier (the /mcp URL), advertised in PRM + RFC8707. */
  resourceUrl: string;
  /**
   * The issuer's key set, for an issuer that is not Entra (MCP_JWKS_URI) — typically
   * {issuer}/.well-known/jwks.json. Empty means Entra's keys for `tenantId`.
   */
  jwksUri: string;
}

/** Identity extracted from a verified token, threaded into the request context. */
export interface EntraIdentity {
  /** Raw bearer token — reused as the OBO user-assertion for the SQL token exchange (Path A). */
  token: string;
  /** Stable object ID of the signed-in user (audit key; never reassigned). */
  oid?: string;
  /** UPN / email — what a human recognises in the audit trail. */
  upn?: string;
  /** Tenant ID the token was issued for. */
  tid?: string;
  /** `sub` — how a non-Entra issuer names the caller; Entra tokens carry it too. */
  sub?: string;
}

export function loadAuthConfig(): EntraAuthConfig {
  const mode = (process.env.MCP_AUTH_MODE ?? "off").toLowerCase() as AuthMode;
  // example tenant default — same GUID the reference MCP server ships with.
  const tenantId = process.env.ENTRA_TENANT_ID ?? "00000000-0000-0000-0000-000000000000";
  const clientId = process.env.ENTRA_CLIENT_ID ?? "";
  const audience = process.env.ENTRA_API_AUDIENCE ?? (clientId ? `api://${clientId}` : "");
  const issuer = process.env.ENTRA_ISSUER ?? `https://login.microsoftonline.com/${tenantId}/v2.0`;
  const requiredScopes = (process.env.ENTRA_REQUIRED_SCOPES ?? "access_as_user")
    .split(/[ ,]+/).map((s) => s.trim()).filter(Boolean);
  // Absolute or nothing: with MCP_PUBLIC_URL unset this used to be the bare path "/mcp", and
  // `new URL("/mcp")` in the verifier threw on EVERY authenticated request.
  const resourceUrl =
    process.env.MCP_RESOURCE_URL ??
    (process.env.MCP_PUBLIC_URL ? `${process.env.MCP_PUBLIC_URL.replace(/\/$/, "")}/mcp` : "");
  const jwksUri = process.env.MCP_JWKS_URI ?? "";

  if (mode !== "off") {
    // ENTRA_CLIENT_ID only derives the Entra audience. An issuer named by MCP_JWKS_URI has no
    // client id here and states its audience outright; demanding one anyway would stop such a
    // deployment from starting at all.
    if (!clientId && !jwksUri) throw new Error("MCP_AUTH_MODE is set but ENTRA_CLIENT_ID is missing.");
    if (!audience) throw new Error("MCP_AUTH_MODE is set but ENTRA_API_AUDIENCE could not be derived.");
  }
  return { mode, tenantId, clientId, audience, issuer, requiredScopes, resourceUrl, jwksUri };
}

/**
 * Build the Resource-Server token verifier. It validates signature (via the issuer's
 * JWKS), issuer, audience, and expiry, then maps the token to the SDK's AuthInfo.
 * `extra.entra` carries the identity connectionManager needs for audit + OBO.
 */
export function buildVerifier(cfg: EntraAuthConfig): OAuthTokenVerifier {
  // JWKS is fetched once and cached/rotated by jose; keys roll without a restart. A non-Entra
  // issuer names its own key set: looking its token's kid up in Entra's keys finds nothing,
  // and every call 401s.
  const JWKS = createRemoteJWKSet(
    new URL(cfg.jwksUri || `https://login.microsoftonline.com/${cfg.tenantId}/discovery/v2.0/keys`),
  );

  return {
    async verifyAccessToken(token: string): Promise<AuthInfo> {
      let payload: JWTPayload;
      try {
        ({ payload } = await jwtVerify(token, JWKS, {
          issuer: cfg.issuer,
          audience: cfg.audience,
          // Pin the signing algorithm. Entra v2 access tokens are RS256; restricting the
          // accepted set is defence-in-depth against alg-substitution (jose already rejects
          // "none" and won't use an RSA JWKS key as an HMAC secret, but pinning is explicit).
          algorithms: ["RS256"],
        }));
      } catch (e) {
        throw verificationError(e);
      }

      // jose (and most service meshes' JWT policies) accept a token whose `aud` ARRAY merely
      // contains ours. A token minted for several services at once is such an array — one
      // credential for every backend behind a gateway — and a caller holding it must not reach
      // this server's tools directly, around the gateway that would exchange it for a token
      // minted for this server alone. So only that shape passes: `aud` exactly ours, as a string
      // or a one-element array. Entra's tokens are a string.
      if (!audienceIsExactly(payload.aud, cfg.audience)) {
        throw new InvalidTokenError(
          `The token's audience must be exactly '${cfg.audience}'. A token for several services is ` +
          `refused: exchange it for one minted for this server first.`,
        );
      }

      // Entra puts delegated scopes in `scp` (space-delimited) and app roles in `roles`.
      const scp = typeof payload.scp === "string" ? payload.scp.split(" ").filter(Boolean) : [];
      const roles = Array.isArray(payload.roles) ? (payload.roles as string[]) : [];
      const scopes = [...scp, ...roles];

      // requireBearerAuth checks requiredScopes too, but failing here gives a precise error.
      for (const need of cfg.requiredScopes) {
        if (!scopes.includes(need)) {
          throw new InsufficientScopeError(`Token is missing required scope '${need}'.`);
        }
      }

      const p = payload as JWTPayload & {
        oid?: string; tid?: string; upn?: string; preferred_username?: string;
        azp?: string; appid?: string;
      };
      const identity: EntraIdentity = {
        token,
        oid: p.oid,
        upn: p.upn ?? p.preferred_username,
        tid: p.tid,
        sub: typeof p.sub === "string" ? p.sub : undefined,
      };

      return {
        token,
        clientId: p.azp ?? p.appid ?? "",
        scopes,
        expiresAt: typeof payload.exp === "number" ? payload.exp : undefined,
        resource: URL.canParse(cfg.resourceUrl) ? new URL(cfg.resourceUrl) : undefined,
        extra: { entra: identity },
      };
    },
  };
}

/** `aud` names exactly one audience, and it is `expected` (RFC 7519 allows a string or an array). */
export function audienceIsExactly(aud: unknown, expected: string): boolean {
  if (typeof aud === "string") return aud === expected;
  return Array.isArray(aud) && aud.length === 1 && aud[0] === expected;
}

/**
 * A failed verification as the SDK's own OAuth error. requireBearerAuth answers 401/403 only for
 * those and turns anything else into a 500, so jose's errors reached callers as "Internal Server
 * Error": an expired token looked like a crash, and no client was told to fetch a new one.
 *
 * The token's own faults are 401. A key set this server could not fetch or parse is OUR fault —
 * a 401 there would send every client to re-authenticate against an outage. The message lands in
 * a quoted WWW-Authenticate parameter, and jose's messages quote claim names, so quotes go.
 */
function verificationError(e: unknown): Error {
  const msg = (e instanceof Error ? e.message : String(e)).replace(/"/g, "'");
  const code = e instanceof joseErrors.JOSEError ? e.code : undefined;
  // ERR_JOSE_GENERIC is a key set that answered non-200 or not-JSON — jose's only generic errors.
  const ours = ["ERR_JWKS_TIMEOUT", "ERR_JWKS_INVALID", "ERR_JOSE_GENERIC"];
  if (code && !ours.includes(code)) return new InvalidTokenError(msg);
  return new ServerError(`Could not verify the token: ${msg}`);
}

/**
 * OAuth 2.0 Protected Resource Metadata (RFC 9728) — served at
 * /.well-known/oauth-protected-resource. An MCP client that gets a 401 reads this
 * to discover WHICH authorization server (Entra, our tenant) to send the user to.
 *
 * NOTE: Entra has no Dynamic Client Registration. A public MCP client (Claude) must
 * therefore use a pre-registered client_id for our app — see AAD-ENTRA-SETUP.md.
 */
export function buildProtectedResourceMetadata(cfg: EntraAuthConfig): Record<string, unknown> {
  return {
    resource: cfg.resourceUrl,
    authorization_servers: [cfg.issuer],
    scopes_supported: cfg.requiredScopes,
    bearer_methods_supported: ["header"],
    resource_name: "appdb-sql",
  };
}

/** Pull the verified identity back out of AuthInfo.extra (set by buildVerifier). */
export function identityFromAuth(auth: AuthInfo | undefined): EntraIdentity | undefined {
  const e = auth?.extra?.entra as EntraIdentity | undefined;
  return e?.token ? e : undefined;
}

/**
 * The caller a verified token names: `sub`, else `oid`, else `upn`, skipping empty claims. ONE
 * definition, because three things key on it and must agree — the rate limit, the HTTP session
 * binding (index.ts) and the service-identity pool (connectionManager.ts). Undefined for a request
 * with no verified token.
 */
export function callerOf(id: EntraIdentity | undefined): string | undefined {
  return id?.token ? (id.sub || id.oid || id.upn || undefined) : undefined;
}
