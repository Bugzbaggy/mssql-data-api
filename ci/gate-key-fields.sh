#!/usr/bin/env bash
# Gate KEY-FIELDS — every `table` and `view` entity declares source.key-fields.
#
# DAB's primary-key auto-detection does not reliably resolve a table's PK constraint: it can report
# "Primary key not configured on the given database object <X>" for a table whose PK plainly
# exists. That error is raised in DAB's runtime init, so a hand-written config that leaves
# key-fields out passes every credential-free gate, then kills the first pod that loads it. Views
# are included for the same reason from the other direction: DAB *requires* key-fields on a view,
# so an omission there is a guaranteed failure.
#
# This gate cannot check that the columns are the RIGHT ones — it never opens a database. It checks
# that the author made the declaration at all, which is the failure that actually ships. Where no
# live `dab validate` runs before merge, it is the only pre-merge signal.
#
# The curated configs in this repo expose stored procedures only, so on today's tree every file is
# skipped. The gate exists for the first table or view entity someone adds.
#
# Usage: ci/gate-key-fields.sh [--require-tables] [config.json ...]
#          default inputs: every config in the repo, so a new config is gated on arrival
#          --require-tables: fail if the named configs contain no table/view entity at all, so a
#                            deployment that lost its entities cannot pass this gate vacuously
set -uo pipefail
# shellcheck source=ci/lib.sh
. "$(dirname "$0")/lib.sh"

require_tables=0
if [ "${1:-}" = "--require-tables" ]; then
  require_tables=1
  shift
fi

if [ "$#" -eq 0 ]; then
  mapfile -t set_args < <(all_configs)
  set -- "${set_args[@]}"
fi

require_jq
require_files "$@"

rc=0
checked=0
for f in "$@"; do
  # An overlay or a base with no entities of its own is not a finding — but invalid JSON is.
  n=$(jq -r '(.entities // {}) | [to_entries[] | select(.value.source.type == "table" or .value.source.type == "view")] | length' "$f" 2>/dev/null) || {
    gate_fail "Gate KEY-FIELDS FAIL: $f is not valid JSON"; rc=1; continue; }
  n=${n//$'\r'/}   # jq built for Windows emits CRLF; a CR would break the integer tests below

  if [ "$n" -eq 0 ]; then
    gate_ok "Gate KEY-FIELDS: $f (no table/view entities — skipped)"
    continue
  fi
  checked=$((checked + n))

  # Missing, null, empty, wrong type, or holding a non-string/empty name. `or` short-circuits in
  # jq, so the length/any branches never run against a non-array.
  bad=$(jq -r '
      (.entities // {}) | to_entries
      | map(select(.value.source.type == "table" or .value.source.type == "view"))
      | map(select(
          (.value.source["key-fields"] | type) != "array"
          or (.value.source["key-fields"] | length) == 0
          or (.value.source["key-fields"] | any((type != "string") or (. == "")))
        ))
      | .[] | "    \(.key) — \(.value.source.type) \(.value.source.object // "?")"
    ' "$f" 2>/dev/null)
  bad=${bad//$'\r'/}

  if [ -z "$bad" ]; then
    gate_ok "Gate KEY-FIELDS: $f ($n table/view entities)"
  else
    gate_fail "Gate KEY-FIELDS FAIL: $f — every table/view entity needs source.key-fields listing its real PK columns, in key order"
    printf '%s\n' "$bad" >&2
    rc=1
  fi
done

if [ "$require_tables" -eq 1 ] && [ "$checked" -eq 0 ] && [ "$rc" -eq 0 ]; then
  gate_fail "Gate KEY-FIELDS FAIL: --require-tables given but no table/view entity among $# file(s) — the deployment serves nothing"
  rc=1
fi

exit "$rc"
