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
