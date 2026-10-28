#!/usr/bin/env bash
# Gate NO-WRITE-TOOLS — the MCP write tools are off in every self-contained config, curated or
# broad-read. Present AND false: all 7 dml-tools default to true when omitted, so an absent key is
# an enabled write tool. Applies to dev-all, whose read profile Gate DML-TOOLS cannot accept.
#
# Discovers its own inputs so a new config is gated on arrival. Gated iff a file has BOTH
# data-source and runtime, i.e. DAB loads it directly: a data-source-file overlay (data-source, no
# runtime) and a DAB_ENVIRONMENT overlay (runtime.host, no data-source) both inherit dml-tools from
# the config they merge into, while a full config that dropped its mcp block still qualifies.
#
# Usage: ci/gate-no-write-tools.sh [config.json ...]   (default: every config in the repo)
set -uo pipefail
# shellcheck source=ci/lib.sh
. "$(dirname "$0")/lib.sh"

if [ "$#" -eq 0 ]; then
  mapfile -t set_args < <(all_configs)
  set -- "${set_args[@]}"
fi

require_jq
require_files "$@"

rc=0
gated=0
for f in "$@"; do
  self_contained=$(jq -r 'has("data-source") and has("runtime")' "$f" 2>/dev/null) || {
    gate_fail "Gate NO-WRITE-TOOLS FAIL: $f is not valid JSON"; rc=1; continue; }
  if [ "$self_contained" != "true" ]; then
    gate_ok "Gate NO-WRITE-TOOLS: $f (overlay, inherits dml-tools — skipped)"
    continue
  fi
  gated=$((gated + 1))

  if jq -e '
      .runtime.mcp["dml-tools"] as $d
      | $d != null
        and ($d | has("create-record")) and $d["create-record"] == false
        and ($d | has("update-record")) and $d["update-record"] == false
        and ($d | has("delete-record")) and $d["delete-record"] == false
    ' "$f" >/dev/null 2>&1; then
    gate_ok "Gate NO-WRITE-TOOLS: $f"
  else
    gate_fail "Gate NO-WRITE-TOOLS FAIL: $f — create-record, update-record and delete-record must each be present and false"
    printf 'actual dml-tools: %s\n' "$(jq -c '.runtime.mcp["dml-tools"] // "MISSING"' "$f" 2>/dev/null)" >&2
    rc=1
  fi
done

# Skipping everything would pass vacuously.
if [ "$gated" -eq 0 ] && [ "$rc" -eq 0 ]; then
  gate_fail "Gate NO-WRITE-TOOLS FAIL: no self-contained config among $# file(s)"
  rc=1
fi

exit "$rc"
