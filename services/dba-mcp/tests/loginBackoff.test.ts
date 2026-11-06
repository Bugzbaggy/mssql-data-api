/**
 * Lockout protection for CHECK_POLICY = ON logins (svc_sqldiag is one: deploy/01-…sql Part A).
 *
 * SQL honours the Windows lockout policy for such a login, and every failed login is a strike. A
 * wrong or stale password costs TWO strikes per connect here — the catalog fallback retries an
 * 18456 against master, because a bad password and an unopenable catalog look the same to a
 * client — and an agent working an alert storm connects to every node many times a minute. So a
 * login failure the fallback could not rescue must not be re-sent to that host for a while.
 *
 * Driven through the real getPool with the driver's connect() replaced: what is pinned is how
 * many logins reach the server, which is the thing the lockout counter counts.
 */
import { test, before } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import sql from "mssql";

let cm: typeof import("../src/connectionManager.js");
let logins = 0;
let behaviour: "login-failed" | "network" = "login-failed";

before(async () => {
  const dir = mkdtempSync(path.join(tmpdir(), "login-backoff-"));
  const fleet = path.join(dir, "fleet.json");
  // TEST-NET-1 hosts: nothing here ever leaves the process, but if it did it would go nowhere.
  writeFileSync(fleet, JSON.stringify([
    { name: "node-a", region: "t", host: "192.0.2.10", port: 1433, database: "AppCatalog", applicationIntent: "ReadOnly" },
    { name: "node-b", region: "t", host: "192.0.2.11", port: 1433, database: "AppCatalog", applicationIntent: "ReadOnly" },
  ]));
  Object.assign(process.env, {
    INSTANCES_FILE: fleet, DEFAULT_INSTANCE: "node-a", SQL_USER: "svc_sqldiag", SQL_PASSWORD: "stale-secret",
    SQL_LOGIN_FAILURE_BACKOFF_MS: "400", SQL_LOGIN_FAILURE_MAX_HOLDS: "50",
  });
  for (const k of ["SQL_CRED_TARGET", "MCP_TRANSPORT", "SQL_CATALOG_FALLBACK", "SQL_SERVICE_IDENTITY"]) delete process.env[k];
  sql.ConnectionPool.prototype.connect = async function (): Promise<sql.ConnectionPool> {
    logins++;
    if (behaviour === "network") throw Object.assign(new Error("Failed to connect to 192.0.2.10:1433 in 15000ms"), { code: "ETIMEOUT" });
    throw Object.assign(new Error("Login failed for user 'svc_sqldiag'."), { number: 18456, code: "ELOGIN" });
  } as typeof sql.ConnectionPool.prototype.connect;
  cm = await import("../src/connectionManager.js");
  cm.initInstances();
});

test("a login failure costs the two attempts the catalog fallback makes, and no more", async () => {
  logins = 0;
  await assert.rejects(cm.getPool("node-a"), /Login failed/);
  assert.equal(logins, 2, "configured catalog, then master");
});

test("while backing off, the same login is not sent to that host again — the caller gets the error at once", async () => {
  const before = logins;
  for (let i = 0; i < 5; i++) {
    await assert.rejects(cm.getPool("node-a"), (e: Error) => {
      assert.match(e.message, /Login failed/, "the original cause is kept");
      assert.match(e.message, /not retried for another \d+s/);
      assert.match(e.message, /lockout/i);
      return true;
    });
  }
  assert.equal(logins, before, "five calls in the backoff window sent zero logins");
});

test("another host is not held back by one host's failure", async () => {
  const before = logins;
  await assert.rejects(cm.getPool("node-b"), /Login failed/);
  assert.equal(logins, before + 2);
});

test("after the window, one fresh attempt is made", async () => {
  await new Promise((r) => setTimeout(r, 450));
  const before = logins;
  await assert.rejects(cm.getPool("node-a"), (e: Error) => !/not retried/.test(e.message));
  assert.equal(logins, before + 2);
});

test("a network failure is not a strike and is never backed off", async () => {
  behaviour = "network";
  await new Promise((r) => setTimeout(r, 450));
  const before = logins;
  await assert.rejects(cm.getPool("node-a"), /Failed to connect/);
  await assert.rejects(cm.getPool("node-a"), /Failed to connect/);
  assert.equal(logins, before + 2, "each call made its own attempt");
  behaviour = "login-failed";
});

// Keyed on login + host alone, one request naming someone else's login with a wrong password
// (X-DB-User on the per-user service) would hold back that person's right one.
test("one caller's wrong password does not hold back another password for the same login", async () => {
  const as = (password: string) => cm.credentialContext.run({ user: "dba_alice", password }, () => cm.getPool("node-a"));
  const before = logins;
  await assert.rejects(as("wrong"), /Login failed/);
  assert.equal(logins, before + 2);
  await assert.rejects(as("right"), (e: Error) => !/not retried/.test(e.message));
  assert.equal(logins, before + 4, "the other password was sent");
  await assert.rejects(as("wrong"), /not retried/);
  assert.equal(logins, before + 4, "the password that failed is still held back");
});

test("distinct wrong passwords cannot grow the holds without bound, and expired holds are dropped", async () => {
  for (let i = 0; i < 60; i++) {
    await assert.rejects(cm.credentialContext.run({ user: "dba_bob", password: `guess-${i}` }, () => cm.getPool("node-b")));
  }
  // At most the cap (50 here), however fast the guesses come.
  assert.ok(cm.loginHoldsForTest() <= 50, `${cm.loginHoldsForTest()} holds kept`);
  await new Promise((r) => setTimeout(r, 450));
  await assert.rejects(cm.credentialContext.run({ user: "dba_bob", password: "one-more" }, () => cm.getPool("node-b")));
  assert.equal(cm.loginHoldsForTest(), 1, "the expired holds went when a new one was set");
});
