#!/usr/bin/env bash
# Gate DML-TOOLS — asserts the EXACT 7-key kebab-case set exists AND every value.
# The key-set half matters as much as the values: every dml-tool defaults to true in the DAB
# schema, so an OMITTED key is an ENABLED write tool, and no schema check catches that because
# all 7 keys are optional. A typo (`read_records`) both adds an unknown key and drops the real
# one. `dab validate` catches neither.
#
# Usage: ci/gate-dml-tools.sh <config.json> [config.json ...]
set -uo pipefail
# shellcheck source=ci/lib.sh
. "$(dirname "$0")/lib.sh"

require_jq
require_files "$@"

rc=0
for f in "$@"; do
  if jq -e '
      .runtime.mcp["dml-tools"] as $d
      | $d != null
        and (($d | keys | sort) == [
              "aggregate-records","create-record","delete-record",
              "describe-entities","execute-entity","read-records","update-record"
            ])
        and $d["describe-entities"] == true
        and $d["execute-entity"]    == true
        and $d["read-records"]      == false
        and $d["create-record"]     == false
        and $d["update-record"]     == false
        and $d["delete-record"]     == false
        and $d["aggregate-records"] == false
    ' "$f" >/dev/null 2>&1; then
    gate_ok "Gate DML-TOOLS: $f"
  else
    gate_fail "Gate DML-TOOLS FAIL: $f — runtime.mcp.dml-tools must be exactly the 7 kebab-case keys with only describe-entities + execute-entity true"
    jq -r '.runtime.mcp["dml-tools"] // "MISSING"' "$f" >&2 2>/dev/null || true
    rc=1
  fi
done

exit "$rc"
