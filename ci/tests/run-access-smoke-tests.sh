#!/usr/bin/env bash
# Self-test for ci/access-smoke.sh, against a fake DAB and mesh (ci/tests/fake-dab.py) on 127.0.0.1: a clean API must
# pass; each finding the smoke exists for must fail it (rc=1); and "could not look" (no server, a rejected token, a mesh
# refusal where REST should be open) must never pass (rc=2). Needs python3 and curl; no Docker, no database.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1   # -> the repo root

. ci/tests/harness.sh
command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 2; }
E=deploy/ops-expansion/dab-entities.ops.json
S=deploy/ops-expansion/ops-columns.json
pid='' URL=''
stop() { if [ -n "$pid" ]; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; fi; pid=''; }
serve() {  # serve <mode> -> starts the fake, sets URL
  stop
  local pf; pf="$(mktemp)"; rm -f "$pf"
  python3 -I ci/tests/fake-dab.py "$pf" "$1" "$E" "$S" & pid=$!
  for _ in $(seq 1 100); do [ -s "$pf" ] && break; sleep 0.1; done
  [ -s "$pf" ] || { bad "fake-dab did not start in mode $1"; return 1; }
  URL="http://127.0.0.1:$(cat "$pf")"; rm -f "$pf"
}
trap stop EXIT
SMOKE=ci/access-smoke.sh
JWT=(env ACCESS_SMOKE_TOKEN_OPS=test-token-ops ACCESS_SMOKE_TOKEN_OTHER=test-token-other)

# --- a DAB that serves exactly the contract ---
serve dab
expect_rc 0 "simulator: exactly the contract passes" "$SMOKE" --base "$URL" --mode simulator --canary
expect_rc 0 "simulator, dev: the prod-only entity is skipped and the rest passes" "$SMOKE" --base "$URL" --mode simulator --env dev
expect_rc 0 "jwt, REST open (dev): exactly the contract passes" "${JWT[@]}" "$SMOKE" --base "$URL" --mode jwt --env dev --expect-rest open
# Prod expects the mesh to close REST: a REST API that answers there is the finding.
expect_rc 1 "jwt, REST closed (prod): REST answering is a finding" "${JWT[@]}" "$SMOKE" --base "$URL" --mode jwt --expect-rest closed

# --- findings: each must fail the run ---
serve leak
expect_rc 1 "a field outside fields.include in a response" "$SMOKE" --base "$URL" --mode simulator
serve canary
expect_rc 1 "a CANARY value in a response (--canary)" "$SMOKE" --base "$URL" --mode simulator --canary
expect_rc 0 "control: the same response without --canary" "$SMOKE" --base "$URL" --mode simulator
serve select-open
expect_rc 1 "a blocked column answered in \$select" "$SMOKE" --base "$URL" --mode simulator
serve mesh-select
expect_rc 1 "a mesh 403 never counts as DAB refusing a column" "$SMOKE" --base "$URL" --mode simulator
serve role-open
expect_rc 1 "another role reads an Ops entity" "$SMOKE" --base "$URL" --mode simulator

# --- the prod mesh: /api and /graphql closed, only /mcp open ---
serve mesh-closed
expect_rc 0 "jwt, REST closed (prod): the mesh refuses /api and /graphql for every token" "${JWT[@]}" "$SMOKE" --base "$URL" --mode jwt --expect-rest closed
expect_rc 2 "jwt, REST open: a mesh refusal means nothing could be tested" "${JWT[@]}" "$SMOKE" --base "$URL" --mode jwt --expect-rest open

# --- could not look: never a pass ---
serve unauthorized
expect_rc 2 "a rejected token (401)" "${JWT[@]}" "$SMOKE" --base "$URL" --mode jwt --expect-rest open
dead="$URL"; stop
expect_rc 2 "an unreachable API" "$SMOKE" --base "$dead" --mode simulator
expect_rc 0 "jwt with no token: skipped with a warning" env -u ACCESS_SMOKE_TOKEN_OPS "$SMOKE" --base "$dead" --mode jwt
expect_rc 1 "jwt with no token and ACCESS_SMOKE_REQUIRED=true" env -u ACCESS_SMOKE_TOKEN_OPS ACCESS_SMOKE_REQUIRED=true "$SMOKE" --base "$dead" --mode jwt
expect_rc 2 "--expect-rest closed without --mode jwt" "$SMOKE" --base "$dead" --mode simulator --expect-rest closed
expect_rc 2 "no --base" "$SMOKE" --mode simulator

summary access-smoke
