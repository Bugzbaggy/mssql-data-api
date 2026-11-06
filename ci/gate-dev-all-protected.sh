#!/usr/bin/env bash
# Gate DEV-ALL-PROTECTED — the broad-read dev-all tree never serves an object it was told to drop,
# serves a canonical table only under the one entity name a client pins, and never serves a secret
# or personal-data column it was told to hide.
#
# config/dev-all/protected-excluded.txt holds one line per protected object:
#   <config file> TAB <schema.object> TAB <reason>
# reason "secret-columns:<a,b>" / "pii-columns:<a,b>" = may be served, but no role may see those columns;
#        "canonical:<entity>"                         = may be served ONLY as that entity, on ANY
#                                                       database (a client pins that one name);
#        anything else                                = must not be served at all.
# Every line is checked against EVERY entity on the same database — the named config, any other
# config on the same connection key, and the base's own entities — because a copy in another file
# is the same exposure. Canonical lines are checked against every config: a protected table's name
# on another database is a copy or a synonym of the same rows. Permissions are evaluated the way
# DAB 2.0.9 resolves them (ci/dab-perms.jq: case-insensitive actions incl. "*"/"all", every read
# action of a role counts, include entries match columns ignoring case, a wildcard counts only
# when alone).
#
# Fails if the list is missing/empty, names a config that no longer exists (a stale list), any line
# is violated (a hand edit, a regeneration that lost an exclusion), or the tree has a shape the line
# checks cannot see: autoentities, nested data-source-files, mappings or entity-level fields, @env()
# inside an entity, a non-plain object or entity name, a connection string other than exactly
# @env('<KEY>'), or a config whose file name is not the one the naming rule derives from its key
# (a decoy). See docs/dev-all-status.md.
#
# Usage: ci/gate-dev-all-protected.sh [excluded-list] [config-dir] [base]
#        defaults: config/dev-all/protected-excluded.txt config/dev-all dab-config.dev-all.json
set -uo pipefail
# shellcheck source=ci/lib.sh
. "$(dirname "$0")/lib.sh"

require_jq

LIST="${1:-config/dev-all/protected-excluded.txt}"
DIR="${2:-config/dev-all}"
BASE="${3:-dab-config.dev-all.json}"

if ! grep -q -v -e '^#' -e '^[[:space:]]*$' "$LIST" 2>/dev/null; then
  gate_fail "Gate DEV-ALL-PROTECTED FAIL: $LIST is missing or empty — every broad-read tree needs its protected list (docs/dev-all-status.md)"
  exit 1
fi
[ -f "$BASE" ] || { gate_fail "Gate DEV-ALL-PROTECTED FAIL: base config not found: $BASE"; exit 1; }
shopt -s nullglob
configs=("$DIR"/*.json)
shopt -u nullglob
if [ "${#configs[@]}" -eq 0 ]; then
  gate_fail "Gate DEV-ALL-PROTECTED FAIL: no configs under $DIR — nothing checked is not a pass"
  exit 1
fi

CI_DIR="$(dirname "$0")"
if ! result=$(jq -n -r -L "$CI_DIR" -f "$CI_DIR/gate-dev-all-protected.jq" \
                 --rawfile list "$LIST" --arg base "$BASE" "$BASE" "${configs[@]}"); then
  gate_fail "Gate DEV-ALL-PROTECTED FAIL: could not evaluate $LIST against $DIR and $BASE (invalid JSON?)"
  exit 1
fi
result=${result//$'\r'/}   # jq built for Windows emits CRLF

checked=$(printf '%s\n' "$result" | sed -n 's/^checked=//p' | head -1)
problems=$(printf '%s\n' "$result" | grep -v '^checked=')
if [ -n "$problems" ]; then
  while IFS= read -r p; do gate_fail "Gate DEV-ALL-PROTECTED FAIL: $p"; done <<<"$problems"
  exit 1
fi
gate_ok "Gate DEV-ALL-PROTECTED: $checked protected line(s) hold across $BASE and ${#configs[@]} config(s) in $DIR"
exit 0
