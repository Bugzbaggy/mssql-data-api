#!/usr/bin/env bash
# Gate OPS-ENTITIES — every Ops_* entity is exactly what the reviewed column contract allows, and no config serves
# a base table that the contract serves only through a projection view.
#
# The contract is deploy/ops-expansion/ops-columns.json: per entity, the dataapi view it is served through, the
# served columns, every left-out column with its reason (credential, personal, content, free text, commercial), and
# the key and the filters the gateway must require. It fails when:
#   - the contract contradicts itself (a column both served and blocked, a key that is not served, a non-plain name),
#     or a served column whose name looks sensitive (password, key, token, e-mail, phone, body, cost...) carries no
#     'reviewed' reason;
#   - deploy/ops-expansion/dab-entities.ops.json differs from the contract: an entity missing or extra, a source other
#     than its dataapi view, other key fields, health checks on, a role other than the contract's, an action other
#     than read, a fields.include that is not exactly the served list (or a wildcard), an exclude or a policy, a REST
#     method other than GET, a GraphQL mutation, or any shape ci/dab-perms.jq treats as a bypass (mappings,
#     entity-level fields, @env()...);
#   - any config the pods can load serves an Ops_* entity or a dataapi view that is not the staged entity, unchanged
#     (so activating one is a copy, and a hand edit on the way fails here);
#   - any config serves one of the contract's base objects (an entity's source, or a deny-also object) directly,
#     under any entity name: the column lists only hold if the view is the only way in.
# The views themselves are checked against the same contract by Gate SQL-VIEWS (ci/sql-views/run.sh), in a
# SQL Server container. Pure jq: no Docker, no database.
#
# Usage: ci/gate-ops-entities.sh [config.json ...]   (default: every config, ci/lib.sh all_configs)
# Exit: 0 pass, 1 a finding, 2 a missing file or bad arguments.
set -uo pipefail
# shellcheck source=ci/lib.sh
. "$(dirname "$0")/lib.sh"

require_jq
SPEC=deploy/ops-expansion/ops-columns.json
STAGED=deploy/ops-expansion/dab-entities.ops.json
require_files "$SPEC" "$STAGED"
if [ "$#" -gt 0 ]; then
  files=("$@")
else
  mapfile -t files < <(all_configs | tr -d '\r')
fi
require_files "${files[@]}"
for f in "$SPEC" "$STAGED" "${files[@]}"; do
  jq empty "$f" >/dev/null 2>&1 || { gate_fail "Gate OPS-ENTITIES FAIL: $f is not valid JSON"; exit 1; }
done

CI_DIR="$(dirname "$0")"
if ! problems=$(jq -n -r -L "$CI_DIR" -f "$CI_DIR/gate-ops-entities.jq" \
                  --slurpfile spec "$SPEC" --slurpfile staged "$STAGED" "${files[@]}" | tr -d '\r'); then
  gate_fail "Gate OPS-ENTITIES FAIL: could not evaluate $SPEC, $STAGED and the configs"
  exit 1
fi
if [ -n "$problems" ]; then
  gate_fail "Gate OPS-ENTITIES FAIL: an Ops entity, or a config, is not what the reviewed column contract allows"
  printf '  %s\n' "$problems" >&2
  exit 1
fi
n=$(jq '.entities | length' "$STAGED" | tr -d '\r')
role=$(jq -r '.role' "$SPEC" | tr -d '\r')
gate_ok "Gate OPS-ENTITIES: $n staged Ops entities match $SPEC exactly (read-only, $role only, exact fields.include); no config serves one any other way or serves a base object behind a view (${#files[@]} configs checked)"
exit 0
