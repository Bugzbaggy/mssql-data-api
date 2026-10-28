#!/usr/bin/env bash
# Gate HEALTH-PROBE — a config whose comprehensive /health answers anonymous callers must run no
# entity-level health checks.
#
# DAB 2.0.9's /health in production mode answers only the roles in runtime.health.roles. With
# "anonymous" there, probes and monitors read it without a token (the mesh leaves /health open too),
# so it must say nothing about entities: every entity carries health.enabled defaulting to TRUE, and
# an entity check runs a real query against that entity and reports its name, its result and its
# timing to whoever asked. Measured on 2.0.9: stored-procedure entities produce no entity check,
# but one table entity added "rest" and "graphql" endpoint checks naming it, with timings, and
# turned the anonymous report Unhealthy; health.enabled false removed both. So the explicit false
# is what keeps the probe clean the day a table or view joins the curated config. What is left is
# the data-source check (DAB's SELECT 1), which is what a readiness probe needs.
#
# For each base config given whose runtime.health is not disabled and whose roles include
# "anonymous" (any case), every entity in the base AND in each of its data-source-files must declare
# health.enabled as the JSON boolean false. Omitted, true, "false" or @env(...) all fail: only the
# literal false is false whatever the environment says. A base that does not grant anonymous health
# is reported and skipped.
#
# Usage: ci/gate-health-probe.sh [base.json ...]   (default: dab-config.json)
set -uo pipefail
# shellcheck source=ci/lib.sh
. "$(dirname "$0")/lib.sh"

require_jq
[ "$#" -eq 0 ] && set -- dab-config.json
require_files "$@"

rc=0
for base in "$@"; do
  if ! anon=$(jq -r '(.runtime.health // {}) as $h
                     | ($h.enabled != false and $h.enabled != "false")
                       and (($h.roles // []) | map(ascii_downcase) | index("anonymous") != null)' "$base" 2>/dev/null); then
    gate_fail "Gate HEALTH-PROBE FAIL: $base is not valid JSON"; rc=1; continue
  fi
  anon=${anon//$'\r'/}
  if [ "$anon" != true ]; then
    gate_ok "Gate HEALTH-PROBE: $base does not answer /health anonymously — skipped"
    continue
  fi

  mapfile -t files < <(configs_for_base "$base")
  require_files "${files[@]}"
  n=0
  for f in "${files[@]}"; do
    if ! bad=$(jq -r '(.entities // {}) | to_entries[]
                      | select((.value | type) != "object" or (.value.health.enabled != false))
                      | .key' "$f" 2>/dev/null); then
      gate_fail "Gate HEALTH-PROBE FAIL: $f is not valid JSON"; rc=1; continue
    fi
    bad=${bad//$'\r'/}
    m=$(jq -r '(.entities // {}) | length' "$f" 2>/dev/null); m=${m//$'\r'/}
    n=$((n + ${m:-0}))
    if [ -n "$bad" ]; then
      gate_fail "Gate HEALTH-PROBE FAIL: $f — $base answers /health anonymously, but these entities do not set health.enabled to false: $(printf '%s' "$bad" | tr '\n' ' ')"
      rc=1
    fi
  done
  [ "$rc" -eq 0 ] && gate_ok "Gate HEALTH-PROBE: $base answers /health anonymously and all $n entities in it and its data-source-files run no entity check"
done
exit "$rc"
