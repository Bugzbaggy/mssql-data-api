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
if node scripts/sync-dba-mcp.mjs --dry >/dev/null 2>&1; then
  status_ok=true
else
  status_ok=false
fi
after=$(jq -r '.sha' "$PIN" | tr -d '\r')
if [ "$status_ok" = true ] && [ "$before" = "$after" ]; then
  ok "sync: --dry succeeds and leaves the pin untouched"
else
  bad "sync: --dry failed or rewrote the pin"
fi

# --- the sync script accepts a valid sha with --dry --------------------------------
expect pass "sync: a valid --sha with --dry is accepted" \
  node scripts/sync-dba-mcp.mjs --sha 249bd1086547228c9da820096d95d54517bf1595 --dry

# --- the sync script rejects a malformed sha -------------------------------------
expect fail "sync: --sha rejects a short sha" node scripts/sync-dba-mcp.mjs --sha deadbeef --dry

# --- the drift gate ---------------------------------------------------------------
# Absolute, because run_in cd's into a temp root before invoking the gate.
CI_ABS=$(cd "$CI" && pwd)

run_in() {  # run_in <pass|fail> <desc> <root>
  expect "$1" "$2" bash -c 'cd "$1" && "$2/gate-vendor-drift.sh"' _ "$3" "$CI_ABS"
}

vendorrepo() {  # vendorrepo -> temp root holding a copy of the vendored tree
  # Exclude node_modules and dist: they are git-ignored build output (thousands of
  # files, machine-dependent), not part of what the drift gate hashes.
  local t; t=$(mktemp -d)
  mkdir -p "$t/services/dba-mcp"
  (cd services/dba-mcp && tar cf - --exclude=node_modules --exclude=dist .) | (cd "$t/services/dba-mcp" && tar xf -)
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

summary vendor
