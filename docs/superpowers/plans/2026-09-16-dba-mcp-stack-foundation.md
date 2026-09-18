# DBA MCP Stack Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `docker compose up` in `mssql-data-api` bring up SQL Server, the DAB MCP endpoint and the vendored DBA MCP endpoint together, with the vendored copy protected against drift.

**Architecture:** `mssql-dba-mcp` stays the upstream source of truth. Its server is vendored into `services/dba-mcp/` at a pinned commit, refreshed by `scripts/sync-dba-mcp.mjs` and policed by `ci/gate-vendor-drift.sh`. A compose file runs three services; a second compose file overrides the SQL container away in favour of a real fleet.

**Tech Stack:** Node 22 + TypeScript (esbuild), PowerShell 7 + dbatools, Data API Builder 2.0.9, SQL Server 2022, Docker Compose, bash gates using `ci/lib.sh` and `ci/tests/harness.sh`.

**Spec:** `docs/superpowers/specs/2026-09-16-dba-mcp-stack-design.md`

## Global Constraints

- Upstream repo: `https://github.com/Bugzbaggy/mssql-dba-mcp.git`
- Pinned upstream commit for the initial vendor: `249bd1086547228c9da820096d95d54517bf1595`
- DAB image tag is `2.0.9` everywhere. `ci/gate-version.sh` fails the build if any file disagrees with the `Dockerfile` `FROM` tag.
- Node `>=22`. The vendored `package.json` declares `"engines": { "node": ">=22" }`.
- Every new `*.sh` is `text eol=lf` per the existing `.gitattributes`, and must be `chmod +x`.
- `ci/leak-scan.sh` runs over the whole tree. No real hostnames, AWS account numbers, RFC1918 addresses, or the identifiers it lists. Examples use `192.0.2.x` (RFC5737) and `111111111111`-style account placeholders.
- Gate scripts resolve paths from the **current directory**, and take an optional alternate root as `$1`. Do not `cd` to `$0`'s directory — the self-tests run gates against mutated copies in temp roots.
- `jq` output is piped through `tr -d '\r'` before any path comparison. jq built for Windows emits CRLF; this is a no-op on Linux.
- Service names in compose: `sqlserver`, `dab-mcp`, `dba-mcp`.
- **Docker Compose v2.24 or newer.** `docker-compose.fleet.yml` uses the `!reset` merge tag to drop `depends_on` and `INSTANCES` from the base file; on older Compose the tag is a parse error, not a silent no-op. Check with `docker compose version`.
- dbatools is pinned to `2.1.14` in the image. An unpinned `Install-Module` makes the build non-reproducible and can change cmdlet output shape between rebuilds, which is exactly what the later parity tests exist to catch.

---

### Task 1: Vendor the upstream server

**Files:**
- Create: `services/dba-mcp/.upstream`
- Create: `services/dba-mcp/` (copied tree: `src/`, `tests/`, `package.json`, `tsconfig.json`)
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: the directory `services/dba-mcp/` and the pin file `services/dba-mcp/.upstream`, a JSON document with keys `repo` (string), `sha` (string, 40 hex chars), `paths` (string array of upstream paths that were copied) and `hash` (string, sha256 of the vendored tree — written in Task 3, absent until then).

- [ ] **Step 1: Copy the upstream server tree**

Run from the repo root, with `mssql-dba-mcp` checked out as a sibling directory:

```bash
mkdir -p services/dba-mcp
cp -R ../mssql-dba-mcp/server/src services/dba-mcp/src
cp -R ../mssql-dba-mcp/server/tests services/dba-mcp/tests
cp ../mssql-dba-mcp/server/package.json services/dba-mcp/package.json
cp ../mssql-dba-mcp/server/tsconfig.json services/dba-mcp/tsconfig.json
```

- [ ] **Step 2: Write the pin file**

Create `services/dba-mcp/.upstream`:

```json
{
  "repo": "https://github.com/Bugzbaggy/mssql-dba-mcp.git",
  "sha": "249bd1086547228c9da820096d95d54517bf1595",
  "paths": [
    "server/src",
    "server/tests",
    "server/package.json",
    "server/tsconfig.json"
  ]
}
```

- [ ] **Step 3: Keep build output out of git**

Append to `.gitignore`:

```
# Vendored DBA MCP server build output and deps
services/dba-mcp/node_modules/
services/dba-mcp/dist/
```

- [ ] **Step 4: Verify the vendored copy builds and tests clean**

```bash
cd services/dba-mcp && npm install --no-audit --no-fund && npm run typecheck && npm test && npm run build
```

Expected: `typecheck` exits 0, tests report `pass 3`, `build` writes `dist/index.js`.

- [ ] **Step 5: Verify the leak scan still passes**

Run: `bash ci/leak-scan.sh`
Expected: `Leak scan clean.`

- [ ] **Step 6: Commit**

```bash
git add services/dba-mcp .gitignore
git commit -m "feat: vendor mssql-dba-mcp server at 249bd10"
```

---

### Task 2: Sync script

**Files:**
- Create: `scripts/sync-dba-mcp.mjs`
- Create: `ci/tests/run-vendor-tests.sh`

**Interfaces:**
- Consumes: `services/dba-mcp/.upstream` (Task 1).
- Produces: `node scripts/sync-dba-mcp.mjs [--sha <sha>] [--dry]`. Exits 0 on success, 1 on failure. With `--sha` it rewrites `.upstream.sha` to the new value; without it, it re-syncs at the currently pinned sha. `--dry` prints what would change and writes nothing.

- [ ] **Step 1: Write the failing test**

Create `ci/tests/run-vendor-tests.sh`:

```bash
#!/usr/bin/env bash
# Tests for the vendored DBA MCP server: the sync script's contract and the drift gate.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
. ci/tests/harness.sh

CI=ci
PIN=services/dba-mcp/.upstream

# --- the pin file is well-formed -------------------------------------------------
if jq -e '.repo and .sha and (.paths | length > 0)' "$PIN" >/dev/null 2>&1; then
  ok "pin: .upstream has repo, sha and paths"
else
  bad "pin: .upstream is missing repo, sha or paths"
fi

if jq -r '.sha' "$PIN" | tr -d '\r' | grep -qE '^[0-9a-f]{40}$'; then
  ok "pin: sha is a full 40-character commit id"
else
  bad "pin: sha is not a full 40-character commit id"
fi

# --- the sync script honours --dry -----------------------------------------------
before=$(jq -r '.sha' "$PIN" | tr -d '\r')
node scripts/sync-dba-mcp.mjs --dry >/dev/null 2>&1
after=$(jq -r '.sha' "$PIN" | tr -d '\r')
if [ "$before" = "$after" ]; then
  ok "sync: --dry leaves the pin untouched"
else
  bad "sync: --dry rewrote the pin"
fi

# --- the sync script rejects a malformed sha -------------------------------------
expect fail "sync: --sha rejects a short sha" node scripts/sync-dba-mcp.mjs --sha deadbeef --dry

summary vendor
```

Make it executable: `chmod +x ci/tests/run-vendor-tests.sh`

- [ ] **Step 2: Run it to verify it fails**

Run: `bash ci/tests/run-vendor-tests.sh`
Expected: FAIL — `sync: --dry leaves the pin untouched` and the `--sha` case error out because `scripts/sync-dba-mcp.mjs` does not exist.

- [ ] **Step 3: Write the sync script**

Create `scripts/sync-dba-mcp.mjs`:

```javascript
// sync-dba-mcp — refresh services/dba-mcp/ from the upstream mssql-dba-mcp repo at a
// pinned commit. The vendored copy is a CONSUMER: edit upstream, land it there, then
// re-sync here. ci/gate-vendor-drift.sh fails the build if the copy is edited directly.
//
// Run from the repo root:
//   node scripts/sync-dba-mcp.mjs              re-sync at the currently pinned sha
//   node scripts/sync-dba-mcp.mjs --sha <sha>  move the pin, then sync
//   node scripts/sync-dba-mcp.mjs --dry        report, write nothing
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, rmSync, cpSync, mkdtempSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const PIN_PATH = "services/dba-mcp/.upstream";
const DEST = "services/dba-mcp";

const args = process.argv.slice(2);
const dry = args.includes("--dry");
const shaFlag = args.indexOf("--sha");
const newSha = shaFlag !== -1 ? args[shaFlag + 1] : null;

function die(msg) {
  console.error(`sync-dba-mcp: ${msg}`);
  process.exit(1);
}

if (!existsSync(PIN_PATH)) die(`${PIN_PATH} not found — run from the repo root`);
const pin = JSON.parse(readFileSync(PIN_PATH, "utf8"));

// A short sha silently resolves to a different commit later if history is rewritten,
// so the pin only ever holds a full object id.
if (newSha !== null && !/^[0-9a-f]{40}$/.test(newSha ?? "")) {
  die(`--sha must be a full 40-character commit id, got '${newSha}'`);
}
const sha = newSha ?? pin.sha;
if (!/^[0-9a-f]{40}$/.test(sha)) die(`pinned sha '${sha}' is not a full commit id`);

console.log(`upstream ${pin.repo}`);
console.log(`sha      ${sha}${newSha ? " (moving pin)" : ""}`);
for (const p of pin.paths) console.log(`path     ${p}`);

if (dry) {
  console.log("--dry: nothing written");
  process.exit(0);
}

const work = mkdtempSync(join(tmpdir(), "dba-mcp-sync-"));
try {
  execFileSync("git", ["init", "--quiet", work], { stdio: "inherit" });
  execFileSync("git", ["-C", work, "remote", "add", "origin", pin.repo], { stdio: "inherit" });
  execFileSync("git", ["-C", work, "fetch", "--quiet", "--depth", "1", "origin", sha], { stdio: "inherit" });
  execFileSync("git", ["-C", work, "checkout", "--quiet", "FETCH_HEAD"], { stdio: "inherit" });

  for (const p of pin.paths) {
    const from = join(work, p);
    if (!existsSync(from)) die(`upstream path '${p}' does not exist at ${sha}`);
    // Upstream 'server/src' lands as 'services/dba-mcp/src'.
    const to = join(DEST, p.replace(/^server\//, ""));
    rmSync(to, { recursive: true, force: true });
    cpSync(from, to, { recursive: true });
    console.log(`synced   ${p} -> ${to}`);
  }

  pin.sha = sha;
  delete pin.hash;   // recomputed by ci/gate-vendor-drift.sh --write
  writeFileSync(PIN_PATH, JSON.stringify(pin, null, 2) + "\n");
  console.log("Pin updated. Run: ci/gate-vendor-drift.sh --write");
} finally {
  rmSync(work, { recursive: true, force: true });
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash ci/tests/run-vendor-tests.sh`
Expected: all four assertions `ok`, then `All vendor tests passed.`

- [ ] **Step 5: Commit**

```bash
git add scripts/sync-dba-mcp.mjs ci/tests/run-vendor-tests.sh
git commit -m "feat: add sync-dba-mcp script and vendor tests"
```

---

### Task 3: Drift gate

**Files:**
- Create: `ci/gate-vendor-drift.sh`
- Modify: `ci/tests/run-vendor-tests.sh`
- Modify: `services/dba-mcp/.upstream` (gains `hash`)

**Interfaces:**
- Consumes: `services/dba-mcp/.upstream` (Task 1), `ci/lib.sh` helpers `gate_ok`, `gate_fail`, `require_jq`, `require_files`.
- Produces: `ci/gate-vendor-drift.sh [root]` exits 0 when the vendored tree matches `.upstream.hash`, 1 when it differs. `ci/gate-vendor-drift.sh --write` recomputes and stores the hash.

- [ ] **Step 1: Write the failing test**

Append to `ci/tests/run-vendor-tests.sh`, immediately before the final `summary vendor` line:

```bash
# --- the drift gate ---------------------------------------------------------------
# Absolute, because run_in cd's into a temp root before invoking the gate.
CI_ABS=$(cd "$CI" && pwd)

run_in() {  # run_in <pass|fail> <desc> <root>
  expect "$1" "$2" bash -c 'cd "$1" && "$2/gate-vendor-drift.sh"' _ "$3" "$CI_ABS"
}

vendorrepo() {  # vendorrepo -> temp root holding a copy of the vendored tree
  local t; t=$(mktemp -d)
  mkdir -p "$t/services"
  cp -R services/dba-mcp "$t/services/dba-mcp"
  printf '%s\n' "$t"
}

expect pass "drift: the committed tree matches its pin" "$CI/gate-vendor-drift.sh"

t=$(vendorrepo)
printf '\n// local edit\n' >> "$t/services/dba-mcp/src/safety.ts"
run_in fail "drift: a local edit to the vendored tree is refused" "$t"
rm -rf "$t"

t=$(vendorrepo)
rm "$t/services/dba-mcp/src/safety.ts"
run_in fail "drift: a deleted vendored file is refused" "$t"
rm -rf "$t"

t=$(vendorrepo)
printf 'export const x = 1;\n' > "$t/services/dba-mcp/src/extra.ts"
run_in fail "drift: an added vendored file is refused" "$t"
rm -rf "$t"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash ci/tests/run-vendor-tests.sh`
Expected: FAIL on all four drift assertions — `ci/gate-vendor-drift.sh` does not exist.

- [ ] **Step 3: Write the gate**

Create `ci/gate-vendor-drift.sh`:

```bash
#!/usr/bin/env bash
# Gate VENDOR-DRIFT — services/dba-mcp/ is a VENDORED COPY of mssql-dba-mcp at the
# commit pinned in services/dba-mcp/.upstream. Editing it here forks the server
# silently: upstream keeps shipping, this copy quietly diverges, and nothing says so.
#
# This gate hashes the vendored tree and compares it to the hash recorded in the pin.
# To change the server: land the change upstream, then
#   node scripts/sync-dba-mcp.mjs --sha <new-sha>
#   ci/gate-vendor-drift.sh --write
#
# Usage: ci/gate-vendor-drift.sh [alternate-root]
#        ci/gate-vendor-drift.sh --write     recompute and store the hash
set -uo pipefail
. "$(dirname "$0")/lib.sh"

WRITE=0
if [ "${1:-}" = "--write" ]; then WRITE=1; shift; fi
# Paths resolve from the CURRENT DIRECTORY; the self-test runs this against a copy in
# a temp root while lib.sh still comes from the real repo.
if [ "$#" -ge 1 ]; then cd "$1" || exit 2; fi

require_jq

DIR=services/dba-mcp
PIN="$DIR/.upstream"
require_files "$PIN"

# Deterministic: every file under the vendored tree except the pin itself, sorted in
# byte order, hashed by path AND content so an add, a delete and an edit all move it.
vendor_hash() {
  find "$DIR" -type f ! -name '.upstream' -print0 2>/dev/null \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum 2>/dev/null \
    | sha256sum | cut -d' ' -f1
}

actual=$(vendor_hash)

if [ "$WRITE" -eq 1 ]; then
  tmp=$(mktemp)
  jq --arg h "$actual" '.hash = $h' "$PIN" > "$tmp" && mv "$tmp" "$PIN"
  gate_ok "Gate VENDOR-DRIFT: hash recorded ($actual)"
  exit 0
fi

expected=$(jq -r '.hash // empty' "$PIN" 2>/dev/null | tr -d '\r')
if [ -z "$expected" ]; then
  gate_fail "Gate VENDOR-DRIFT FAIL: $PIN records no hash — run: ci/gate-vendor-drift.sh --write"
  exit 1
fi

if [ "$actual" != "$expected" ]; then
  gate_fail "Gate VENDOR-DRIFT FAIL: $DIR does not match its pin. Land the change in mssql-dba-mcp, then re-sync. (pinned $expected, found $actual)"
  exit 1
fi

gate_ok "Gate VENDOR-DRIFT: $DIR matches $(jq -r '.sha' "$PIN" | tr -d '\r' | cut -c1-7)"
exit 0
```

Make it executable: `chmod +x ci/gate-vendor-drift.sh`

- [ ] **Step 4: Record the hash**

Run: `ci/gate-vendor-drift.sh --write`
Expected: `OK: Gate VENDOR-DRIFT: hash recorded (<64 hex chars>)`

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash ci/tests/run-vendor-tests.sh`
Expected: every assertion `ok`, then `All vendor tests passed.`

- [ ] **Step 6: Commit**

```bash
git add ci/gate-vendor-drift.sh ci/tests/run-vendor-tests.sh services/dba-mcp/.upstream
git commit -m "feat: add vendor drift gate"
```

---

### Task 4: Container image for the DBA server

**Files:**
- Create: `services/dba-mcp/Dockerfile`
- Create: `services/dba-mcp/.dockerignore`

**Interfaces:**
- Consumes: the vendored tree (Task 1).
- Produces: an image exposing port 3000, serving `GET /health` and `POST /mcp`, with PowerShell 7 and the `dbatools` module preinstalled so Plan 2's worker has something to import.

- [ ] **Step 1: Write the Dockerfile**

Create `services/dba-mcp/Dockerfile`:

```dockerfile
# The DBA MCP server. dbatools is baked in rather than installed at boot: a cold
# Install-Module on start turns a container restart into a multi-minute outage, and
# pins nothing.
FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

# Node 22 (the server declares engines >= 22).
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
 && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

RUN pwsh -NoProfile -Command \
    "Set-PSRepository PSGallery -InstallationPolicy Trusted; \
     Install-Module dbatools -RequiredVersion 2.1.14 -Scope AllUsers -Force; \
     Import-Module dbatools -ErrorAction Stop; \
     Write-Host ('dbatools ' + (Get-Module dbatools).Version)"

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY tsconfig.json ./
COPY src ./src
RUN npm install --no-audit --no-fund && npx esbuild src/index.ts \
      --platform=node --target=node22 --bundle --packages=external --outfile=dist/index.js \
 && npm prune --omit=dev

ENV MCP_TRANSPORT=http \
    MCP_BIND_HOST=0.0.0.0 \
    PORT=3000 \
    TOOLSET=dba
EXPOSE 3000

# Non-root: the server needs no write access to its own image.
RUN useradd --system --uid 10001 --create-home dbamcp
USER 10001

CMD ["node", "dist/index.js"]
```

- [ ] **Step 2: Write the .dockerignore**

Create `services/dba-mcp/.dockerignore`:

```
node_modules
dist
tests
.upstream
```

- [ ] **Step 3: Build the image**

Run: `docker build -t dba-mcp:dev services/dba-mcp`
Expected: build succeeds and prints a `dbatools 2.1.14` line during the module step.

- [ ] **Step 4: Verify the server answers /health**

```bash
docker run -d --rm --name dba-mcp-probe -p 3000:3000 \
  -e INSTANCES='[{"name":"probe","host":"192.0.2.10","port":1433,"user":"sa","password":"x","database":"master"}]' \
  dba-mcp:dev
sleep 5
curl -fsS http://localhost:3000/health
docker stop dba-mcp-probe
```

Expected: JSON containing `"status":"ok"` and `"server":"sql-server-dba-mcp"`. The instance is unreachable on purpose — `/health` reports process liveness, not connectivity.

- [ ] **Step 5: Commit**

```bash
git add services/dba-mcp/Dockerfile services/dba-mcp/.dockerignore
git commit -m "feat: containerise the DBA MCP server with pwsh and dbatools"
```

---

### Task 5: The compose stack

**Files:**
- Create: `docker-compose.stack.yml`
- Create: `docker-compose.fleet.yml`
- Create: `seed/01-demo-schema.sql`
- Create: `.env.stack.example`

**Interfaces:**
- Consumes: the image from Task 4, the existing root `Dockerfile` (DAB, Task-independent).
- Produces: services `sqlserver` (1433), `dab-mcp` (5000), `dba-mcp` (3000). `docker-compose.fleet.yml` is an overlay applied with `-f docker-compose.stack.yml -f docker-compose.fleet.yml`.

The existing `docker-compose.yml` stays as the DAB-only dev loop. The stack is a separate file so neither breaks the other.

- [ ] **Step 1: Write the seed schema**

Create `seed/01-demo-schema.sql`:

```sql
-- Demo data for the self-contained stack. Nothing here mirrors production; it exists
-- so both MCP endpoints have something real to answer questions about.
IF DB_ID('AppDb_Demo') IS NULL
    CREATE DATABASE AppDb_Demo;
GO
USE AppDb_Demo;
GO
IF SCHEMA_ID('core') IS NULL EXEC('CREATE SCHEMA core');
GO
IF OBJECT_ID('core.Account') IS NULL
CREATE TABLE core.Account (
    AccountUid  UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_Account PRIMARY KEY,
    Name        NVARCHAR(200)    NOT NULL,
    IsActive    BIT              NOT NULL CONSTRAINT DF_Account_IsActive DEFAULT (1),
    CreatedDate DATETIME2(3)     NOT NULL CONSTRAINT DF_Account_Created  DEFAULT (SYSUTCDATETIME())
);
GO
IF NOT EXISTS (SELECT 1 FROM core.Account)
INSERT core.Account (AccountUid, Name, IsActive) VALUES
    ('11111111-1111-1111-1111-111111111111', N'Demo Account One', 1),
    ('22222222-2222-2222-2222-222222222222', N'Demo Account Two', 0);
GO
CREATE OR ALTER PROCEDURE core.Account_GetByUid
    @AccountUid UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT AccountUid, Name, IsActive, CreatedDate
    FROM core.Account
    WHERE AccountUid = @AccountUid;
END
GO
```

- [ ] **Step 2: Write the env example**

Create `.env.stack.example`:

```bash
# Copy to .env.stack and fill in. Used by docker-compose.stack.yml only.
# Local container credentials. Never reuse a real password here.
MSSQL_SA_PASSWORD=Str0ng!DemoPassw0rd
# The read-only login the DBA server uses. Created by the seed step.
DBA_MCP_USER=sa
DBA_MCP_PASSWORD=Str0ng!DemoPassw0rd
# Ports on the host.
DAB_MCP_PORT=5000
DBA_MCP_PORT=3000
```

- [ ] **Step 3: Write the stack compose file**

Create `docker-compose.stack.yml`:

```yaml
# The full stack: SQL Server, the DAB MCP endpoint (application data) and the DBA MCP
# endpoint (diagnostics). Two endpoints, two security postures - DAB never exposes a raw
# table, the DBA server never reads application data.
#
#   docker compose --env-file .env.stack -f docker-compose.stack.yml up
#
# Against a real fleet instead of the container, add the overlay:
#   docker compose --env-file .env.stack \
#     -f docker-compose.stack.yml -f docker-compose.fleet.yml up dab-mcp dba-mcp
services:
  sqlserver:
    image: mcr.microsoft.com/mssql/server:2022-latest
    container_name: stack-sqlserver
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: ${MSSQL_SA_PASSWORD}
      MSSQL_PID: Developer
    ports:
      - "1433:1433"
    healthcheck:
      test: ["CMD-SHELL", "/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"$$MSSQL_SA_PASSWORD\" -C -Q 'SELECT 1' || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 20s

  seed:
    image: mcr.microsoft.com/mssql-tools:latest
    container_name: stack-seed
    depends_on:
      sqlserver:
        condition: service_healthy
    volumes:
      - ./seed:/seed:ro
    entrypoint: >
      /bin/bash -c "/opt/mssql-tools/bin/sqlcmd -S sqlserver -U sa
      -P \"$$MSSQL_SA_PASSWORD\" -i /seed/01-demo-schema.sql"
    environment:
      MSSQL_SA_PASSWORD: ${MSSQL_SA_PASSWORD}
    restart: "no"

  dab-mcp:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: stack-dab-mcp
    depends_on:
      seed:
        condition: service_completed_successfully
    ports:
      - "${DAB_MCP_PORT:-5000}:5000"
    environment:
      CONN_GLOBAL_CONFIG: "Server=sqlserver,1433;Database=AppDb_Demo;User ID=sa;Password=${MSSQL_SA_PASSWORD};Encrypt=True;TrustServerCertificate=True"
    restart: unless-stopped

  dba-mcp:
    build:
      context: ./services/dba-mcp
    container_name: stack-dba-mcp
    depends_on:
      seed:
        condition: service_completed_successfully
    ports:
      - "${DBA_MCP_PORT:-3000}:3000"
    environment:
      MCP_TRANSPORT: http
      MCP_BIND_HOST: 0.0.0.0
      PORT: "3000"
      TOOLSET: dba
      SQL_USER: ${DBA_MCP_USER}
      SQL_PASSWORD: ${DBA_MCP_PASSWORD}
      INSTANCES: >-
        [{"name":"local","host":"sqlserver","port":1433,
          "user":"${DBA_MCP_USER}","password":"${DBA_MCP_PASSWORD}",
          "database":"master","trustServerCertificate":true}]
    restart: unless-stopped
```

- [ ] **Step 4: Write the fleet overlay**

Create `docker-compose.fleet.yml`:

```yaml
# Overlay: point the stack at a real fleet instead of the demo container.
#
#   docker compose --env-file .env.stack \
#     -f docker-compose.stack.yml -f docker-compose.fleet.yml up dab-mcp dba-mcp
#
# Name dab-mcp and dba-mcp explicitly: `up` with no services would still start
# sqlserver and seed, which this overlay cannot remove.
#
# fleet.json holds topology only - hosts, ports, databases. Credentials resolve from
# SQL_USER / SQL_PASSWORD, so no secret is ever written into it.
services:
  dab-mcp:
    depends_on: !reset []
    environment:
      CONN_GLOBAL_CONFIG: ${CONN_GLOBAL_CONFIG:?set CONN_GLOBAL_CONFIG for fleet mode}

  dba-mcp:
    depends_on: !reset []
    volumes:
      - ${FLEET_FILE:-./fleet.json}:/app/fleet.json:ro
    environment:
      INSTANCES: !reset null
      INSTANCES_FILE: /app/fleet.json
```

- [ ] **Step 5: Verify the stack comes up and both endpoints answer**

```bash
cp .env.stack.example .env.stack
docker compose --env-file .env.stack -f docker-compose.stack.yml up -d --build
# wait for the seed job to finish and both servers to bind
until curl -fsS http://localhost:3000/health >/dev/null 2>&1; do sleep 3; done
curl -fsS http://localhost:3000/health
curl -fsS http://localhost:5000/health
docker compose --env-file .env.stack -f docker-compose.stack.yml down -v
```

Expected: the DBA endpoint returns `"status":"ok"`; the DAB endpoint returns its own health JSON.

- [ ] **Step 6: Verify the fleet overlay parses**

Run:

```bash
CONN_GLOBAL_CONFIG=x docker compose --env-file .env.stack \
  -f docker-compose.stack.yml -f docker-compose.fleet.yml config >/dev/null
```

Expected: exits 0 and prints nothing. This validates the overlay without starting anything.

- [ ] **Step 7: Verify the leak scan still passes**

Run: `bash ci/leak-scan.sh`
Expected: `Leak scan clean.` — `192.0.2.x` and the demo GUIDs are placeholders by design.

- [ ] **Step 8: Commit**

```bash
git add docker-compose.stack.yml docker-compose.fleet.yml seed .env.stack.example
git commit -m "feat: compose SQL Server, DAB MCP and DBA MCP into one stack"
```

---

### Task 6: CI wiring

**Files:**
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `ci/gate-vendor-drift.sh` (Task 3), `ci/tests/run-vendor-tests.sh` (Task 2/3), `docker-compose.stack.yml` (Task 5).
- Produces: two new jobs, `vendor` and `stack-smoke`.

- [ ] **Step 1: Add the vendor gate to the existing gates job**

In `.github/workflows/ci.yml`, inside the `gates` job, immediately after the `Gate DEV-ALL-TREE` step, add:

```yaml
      - name: Gate VENDOR-DRIFT
        run: ./ci/gate-vendor-drift.sh
```

- [ ] **Step 2: Add the vendor test job**

Add as a new top-level job:

```yaml
  vendor:
    name: Vendor tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Make executable
        run: chmod +x ci/*.sh ci/tests/*.sh
      - name: Run vendor tests
        run: ./ci/tests/run-vendor-tests.sh
```

- [ ] **Step 3: Add the stack smoke test job**

Add as a new top-level job:

```yaml
  stack-smoke:
    name: Stack smoke test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Bring the stack up
        run: |
          cp .env.stack.example .env.stack
          docker compose --env-file .env.stack -f docker-compose.stack.yml up -d --build

      # A fixed sleep hides a slow start as a pass or a fast one as wasted minutes.
      - name: Wait for both endpoints
        run: |
          for i in $(seq 1 60); do
            if curl -fsS http://localhost:3000/health >/dev/null 2>&1 \
            && curl -fsS http://localhost:5000/health >/dev/null 2>&1; then
              echo "both endpoints up after ${i}0s"; exit 0
            fi
            sleep 10
          done
          echo "::error::endpoints did not come up"; exit 1

      - name: Both endpoints list tools
        run: |
          body='{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
          for port in 3000 5000; do
            n=$(curl -fsS -X POST "http://localhost:$port/mcp" \
                  -H 'Content-Type: application/json' \
                  -H 'Accept: application/json, text/event-stream' \
                  -d "$body" | grep -o '"name"' | wc -l)
            echo "port $port advertises $n tool(s)"
            [ "$n" -gt 0 ] || { echo "::error::port $port advertised no tools"; exit 1; }
          done

      - name: Fleet overlay parses
        run: |
          CONN_GLOBAL_CONFIG=x docker compose --env-file .env.stack \
            -f docker-compose.stack.yml -f docker-compose.fleet.yml config >/dev/null

      - name: Logs on failure
        if: failure()
        run: docker compose --env-file .env.stack -f docker-compose.stack.yml logs --no-color

      - name: Tear down
        if: always()
        run: docker compose --env-file .env.stack -f docker-compose.stack.yml down -v
```

- [ ] **Step 4: Verify the workflow is valid YAML**

Run: `python -c "import yaml;list(yaml.safe_load_all(open('.github/workflows/ci.yml',encoding='utf-8')));print('valid')"`
Expected: `valid`

- [ ] **Step 5: Commit and push**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: gate vendor drift and smoke-test the stack"
git push origin main
```

- [ ] **Step 6: Verify CI is green**

Run: `gh run list --repo Bugzbaggy/mssql-data-api --limit 1 --json status,conclusion`
Expected: `completed` / `success`, with the `Vendor tests` and `Stack smoke test` jobs both passing.

---

## Follow-on plans

This plan stops at a running stack. Two more follow, each independently shippable:

- **Plan 2 — pwsh worker and wave 1.** `services/dba-mcp/src/pwshWorker.ts`, its supervisor and timeout handling, the parity-test harness, and the wave-1 tool migrations (backup/restore, AG, jobs, instance configuration, security). Needs this plan's image, which already carries dbatools.
- **Plan 3 — waves 2 and 3.** Storage/index/statistics tools, then live diagnostics behind `DBATOOLS_FIRST=1` with the DMV path retained as the default.

Plan 2 cannot start until Task 4's image exists; Plan 3 depends on Plan 2's worker and parity harness.
