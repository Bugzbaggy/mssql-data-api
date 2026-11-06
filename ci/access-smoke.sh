#!/usr/bin/env bash
# Gate API-ACCESS / access smoke — the negative security test at the API layer: through DAB itself, no Ops entity returns
# a field outside its approved list, a blocked column can be neither selected nor filtered on, and a caller without the
# Ops role is refused.
#
# Two modes, one set of checks:
#   --mode simulator  ci/sql-views/run.sh: DAB in development mode with the Simulator provider, in front of the views
#                     in a SQL Server container. The role comes from the X-MS-API-ROLE header. --canary also fails the run
#                     if a response holds a CANARY fixture value.
#   --mode jwt        after a deploy, through the mesh, with real short-lived tokens: ACCESS_SMOKE_TOKEN_OPS must carry the
#                     contract's role (deploy/ops-expansion/ops-columns.json "role"); ACCESS_SMOKE_TOKEN_OTHER the other
#                     role (ACCESS_SMOKE_OTHER_ROLE, default appdb-data-api-msg-reader; optional, without it the cross-role
#                     check is skipped). With no OPS token the run is skipped with a warning, unless
#                     ACCESS_SMOKE_REQUIRED=true, which fails it instead.
#
# What the mesh lets through decides what can be tested (deploy/chart/templates/authpolicy.yaml, istio.allowedPaths):
#   --expect-rest open    (dev: allowedPaths empty) REST reaches DAB, so the per-entity checks below run. A refusal by the
#                         mesh (Envoy's plain-text "RBAC: access denied") is not a DAB refusal: here it stops the run
#                         (exit 2), and it never counts as a blocked column being refused.
#   --expect-rest closed  (prod: allowedPaths ["/mcp"]) JWT callers reach only /mcp. The test is then that /api and
#                         /graphql are refused AT THE MESH for every token the run holds; REST answering is a finding.
#                         The per-entity field checks do not apply there: the field rules are the same DAB entities the
#                         simulator run and the dev run prove, and /mcp is bounded by the gateway (ops-gateway-policy.json).
#
# Checks per Ops entity (--expect-rest open; deploy/ops-expansion/dab-entities.ops.json; _dev-excludes skipped with --env dev):
#   1. GET ?$first=5 as the Ops role -> 200, and every returned field is in the entity's fields.include.
#   2. Each blocked column of the entity (ops-columns.json) in $select and in $filter -> refused by DAB (400, or a 403
#      that is not the mesh's).
#   3. GET as the other role (and, in simulator mode, with no role header, which DAB treats as "authenticated") -> DAB's 403.
#
# Usage: ci/access-smoke.sh --base <url> --mode simulator|jwt [--env dev|prod] [--expect-rest open|closed] [--canary]
#   --base is the API root as callers reach it (for example https://data-api.example.com), never hard-coded here.
# Exit: 0 pass (or skipped), 1 a finding, 2 bad arguments, the API not reachable, a rejected token, or a mesh refusal
#       where REST should be open (nothing could be tested).
set -uo pipefail
# shellcheck source=ci/lib.sh
. "$(dirname "$0")/lib.sh"
require_jq
cd "$(dirname "$0")/.." || exit 2   # -> the repo root

base='' mode='' env=prod canary=0 rest=open
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="${2%/}"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --env) env="$2"; shift 2 ;;
    --expect-rest) rest="$2"; shift 2 ;;
    --canary) canary=1; shift ;;
    *) gate_fail "access-smoke: unknown argument $1"; exit 2 ;;
  esac
done
[ -n "$base" ] && { [ "$mode" = simulator ] || [ "$mode" = jwt ]; } && { [ "$rest" = open ] || [ "$rest" = closed ]; } \
  && { [ "$env" = prod ] || [ "$env" = dev ]; } \
  || { gate_fail "usage: ci/access-smoke.sh --base <url> --mode simulator|jwt [--env dev|prod] [--expect-rest open|closed] [--canary]"; exit 2; }
[ "$mode" = jwt ] || [ "$rest" = open ] || { gate_fail "access smoke: --expect-rest closed needs --mode jwt (the mesh)"; exit 2; }
ENTS=deploy/ops-expansion/dab-entities.ops.json
SPEC=deploy/ops-expansion/ops-columns.json
require_files "$ENTS" "$SPEC"
OPS_ROLE=$(jq -r '.role' "$SPEC" | tr -d '\r')
OTHER_ROLE="${ACCESS_SMOKE_OTHER_ROLE:-appdb-data-api-msg-reader}"

if [ "$mode" = jwt ] && [ -z "${ACCESS_SMOKE_TOKEN_OPS:-}" ]; then
  if [ "${ACCESS_SMOKE_REQUIRED:-false}" = true ]; then
    gate_fail "access smoke: ACCESS_SMOKE_TOKEN_OPS is not set and ACCESS_SMOKE_REQUIRED=true"
    exit 1
  fi
  echo "::warning title=access smoke skipped::No ACCESS_SMOKE_TOKEN_OPS: the post-deploy access test did not run. Set ACCESS_SMOKE_REQUIRED=true once CI can mint a token for $OPS_ROLE."
  exit 0
fi

fails=0 checks=0 skipped=0
bad() { gate_fail "access smoke: $1"; fails=$((fails + 1)); }
body="$(mktemp)"; trap 'rm -f "$body"' EXIT

call_path() {  # call_path <role> <path?query under the base> -> prints the HTTP status; the body lands in $body
  local role="$1" url="$base/$2" auth=() code
  if [ "$mode" = simulator ]; then
    [ "$role" = none ] || auth=(-H "X-MS-API-ROLE: $role")
  else
    # DAB evaluates a request as "authenticated" unless X-MS-API-ROLE names a role the token's roles claim carries.
    case "$role" in
      "$OPS_ROLE") auth=(-H "Authorization: Bearer $ACCESS_SMOKE_TOKEN_OPS" -H "X-MS-API-ROLE: $role") ;;
      "$OTHER_ROLE") auth=(-H "Authorization: Bearer ${ACCESS_SMOKE_TOKEN_OTHER:-}" -H "X-MS-API-ROLE: $role") ;;
    esac
  fi
  code=$(curl -sS -o "$body" -w '%{http_code}' --max-time 20 "${auth[@]}" "$url" 2>/dev/null) || true
  printf '%s' "${code:-000}"
}
call() { call_path "$1" "api/$2"; }
# The mesh's refusal is Envoy's plain-text "RBAC: access denied"; DAB's own 403 is JSON. Only DAB's counts as a check.
mesh_refused() { [ "$1" = 403 ] && grep -q 'RBAC: access denied' "$body"; }
dab_refused() { case "$1" in 400) return 0 ;; 403) ! mesh_refused 403 ;; *) return 1 ;; esac; }
# Entity and column names are plain [A-Za-z0-9_] (Gate OPS-ENTITIES pins that), so this is all the encoding a query needs.
filter_eq_x() { printf '%s%%20eq%%20%%27x%%27' "$1"; }

# One line per entity: name, served fields, blocked columns (tr: jq on Windows ends lines with CR).
mapfile -t plan < <(jq -r --arg env "$env" --slurpfile spec "$SPEC" '
    (."_dev-excludes" // []) as $x
    | .entities | to_entries[] | .key as $e
    | select($env == "prod" or (($x | index($e)) == null))
    | [$e, (.value.permissions[0].actions[0].fields.include | join(",")),
       ([$spec[0].entities[] | select(.entity == $e) | .blocked | keys[]] | join(","))] | @tsv' "$ENTS" | tr -d '\r')
[ "${#plan[@]}" -gt 0 ] || { gate_fail "access smoke: no Ops entities in $ENTS"; exit 2; }
first="${plan[0]%%$'\t'*}"

# Reachability first: a dead endpoint or a rejected token is "could not look", not a pass.
st=$(call "$OPS_ROLE" "$first?\$first=1")
case "$st" in
  000|'') gate_fail "access smoke: $base is not reachable"; exit 2 ;;
  401) gate_fail "access smoke: $base rejected the $OPS_ROLE token (401): expired, wrong issuer or wrong audience"; exit 2 ;;
esac

if [ "$rest" = closed ]; then
  # Prod: only /mcp is open to JWT callers. Prove it for every token this run holds, on REST and on GraphQL.
  roles=("$OPS_ROLE"); [ -n "${ACCESS_SMOKE_TOKEN_OTHER:-}" ] && roles+=("$OTHER_ROLE")
  for r in "${roles[@]}"; do
    for p in "api/$first?\$first=1" "api/" "graphql"; do
      checks=$((checks + 1))
      st=$(call_path "$r" "$p")
      mesh_refused "$st" || bad "/$p as $r returned $st, not the mesh's refusal: REST or GraphQL is open to JWT callers on $base"
    done
  done
  if [ "$fails" -gt 0 ]; then gate_fail "access smoke FAIL: $fails finding(s) in $checks checks ($base)"; exit 1; fi
  gate_ok "access smoke: $base refuses /api and /graphql at the mesh for every token tested ($checks checks); JWT callers reach only /mcp, so the REST field checks do not apply here"
  exit 0
fi

if mesh_refused "$st"; then
  gate_fail "access smoke: $base refuses /api at the mesh (istio.allowedPaths), so the REST checks cannot run here; use --expect-rest closed where that is intended"
  exit 2
fi

entities=()
for line in "${plan[@]}"; do
  IFS=$'\t' read -r e include blocked_csv <<<"$line"
  entities+=("$e")
  st=$(call "$OPS_ROLE" "$e?\$first=5")
  if [ "$st" = 404 ] && [ "$mode" = jwt ]; then
    skipped=$((skipped + 1)); continue          # not deployed in this environment yet
  fi
  checks=$((checks + 1))
  if [ "$st" != 200 ]; then bad "$e: GET as $OPS_ROLE returned $st"; continue; fi
  extra=$(jq -r --arg inc "$include" '($inc | split(",")) as $i | [ .value[]? | keys[] ] | unique
                                      | map(select(. as $k | $i | index($k) | not)) | join(",")' "$body" | tr -d '\r')
  [ -z "$extra" ] || bad "$e: response has fields outside fields.include: $extra"
  if [ "$canary" = 1 ] && grep -q CANARY "$body"; then bad "$e: response holds a CANARY fixture value"; fi
  IFS=',' read -r -a blocked <<<"$blocked_csv"
  for c in "${blocked[@]}"; do
    [ -n "$c" ] || continue
    checks=$((checks + 2))
    st=$(call "$OPS_ROLE" "$e?\$select=$c")
    dab_refused "$st" || bad "$e: \$select=$c returned $st (want DAB's 400 or 403)"
    st=$(call "$OPS_ROLE" "$e?\$filter=$(filter_eq_x "$c")")
    dab_refused "$st" || bad "$e: \$filter on $c returned $st (want DAB's 400 or 403)"
  done
  others=("$OTHER_ROLE")
  [ "$mode" = simulator ] && others+=(none)
  [ "$mode" = jwt ] && [ -z "${ACCESS_SMOKE_TOKEN_OTHER:-}" ] && others=()
  for r in "${others[@]}"; do
    checks=$((checks + 1))
    st=$(call "$r" "$e?\$first=1")
    { [ "$st" = 403 ] && ! mesh_refused "$st"; } || bad "$e: GET as ${r/none/a caller with no role header} returned $st (want DAB's 403)"
  done
done

if [ "$fails" -gt 0 ]; then
  gate_fail "access smoke FAIL: $fails finding(s) in $checks checks ($mode, $base)"
  exit 1
fi
gate_ok "access smoke: $checks checks passed on ${#entities[@]} Ops entities ($mode, $base)$([ "$skipped" -gt 0 ] && echo "; $skipped not deployed here, skipped")"
exit 0
