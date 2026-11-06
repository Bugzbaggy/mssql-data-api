# Program for ci/gate-ops-entities.sh. $spec: deploy/ops-expansion/ops-columns.json (the column contract).
# $staged: deploy/ops-expansion/dab-entities.ops.json. Inputs: every config file to check. Emits one line per problem.
# Written without backslashes on purpose: Git Bash on Windows mangles them on the way to a native jq.
include "dab-perms";

def is_dataapi_view: startswith("dataapi.vw_") and (.[11:] | plain_name);
def is_schema_object: (split(".") | length == 2 and all(.[]; plain_name));

($spec[0]) as $s
| ($staged[0]) as $st
| ($s.role) as $role
| ($s["sensitive-name-pattern"] | if startswith("(?i)") then .[4:] else . end) as $pat
| ([$s.entities[] | {key: .entity, value: .}] | from_entries) as $want
| ([$s.entities[] | select(.envs | index("dev") | not) | .entity] | sort) as $prod_only
# Base objects that only a view may serve: every entity's source, and the deny-also objects.
| ([$s.entities[] | {key: (.source | norm_object), value: "serve it only through \(.view) (entity \(.entity))"}]
   + [($s["deny-also"] // [])[] | {key: (.object | norm_object), value: "it is a deny-also object, which no entity may serve"}]
   | from_entries) as $base
| (
  # ---- the contract itself
  ( $s.entities[] | . as $e | .entity as $n
    | ( (if ($n | startswith("Ops_") and plain_name | not) then "contract: entity name \($n | tojson) is not Ops_<plain name>" else empty end),
        (if ($e.view | is_dataapi_view | not) then "contract \($n): view \($e.view | tojson) is not dataapi.vw_<plain name>" else empty end),
        (if ($e.source | is_schema_object | not) or ($e.source | startswith("dataapi.")) then
           "contract \($n): source \($e.source | tojson) is not a plain schema.object outside dataapi" else empty end),
        (if ($e.envs | sort) != ["prod"] and ($e.envs | sort) != ["dev", "prod"] then "contract \($n): envs must be [prod] or [prod, dev]" else empty end),
        (($e.served + ($e.blocked | keys))[] | select(plain_name | not) | "contract \($n): column \(tojson) is not a plain name"),
        ($e.served[] as $c | select(($e.blocked | has($c))) | "contract \($n): \($c) is both served and blocked"),
        ($e.served | group_by(.) | map(select(length > 1) | .[0]) | .[] | "contract \($n): \(.) is served twice"),
        (if ($e["key-fields"] | length) == 0 then "contract \($n): no key-fields" else empty end),
        ($e["key-fields"][] as $k | select(($e.served | index($k)) == null) | "contract \($n): key field \($k) is not served"),
        ($e["required-filters"][][] as $k | select(($e.served | index($k)) == null) | "contract \($n): required filter column \($k) is not served"),
        ($e["exact-match-only"][] as $k | select(($e.served | index($k)) == null) | "contract \($n): exact-match-only column \($k) is not served"),
        ($e.served[] as $c | select(($c | test($pat; "i")) and (($e.reviewed // {}) | has($c) | not))
         | "contract \($n): served column \($c) looks sensitive (sensitive-name-pattern) and has no 'reviewed' reason"),
        (($e.reviewed // {}) | keys[] as $c | select(($e.served | index($c)) == null) | "contract \($n): 'reviewed' names \($c), which is not served"),
        ($e.blocked | to_entries[] | select((.value | split(":")[0]) as $k | ($s.categories | has($k)) | not)
         | "contract \($n): blocked \(.key) has no known category (\(.value | tojson))") ) ),
  ( $s.entities | group_by(.entity) | map(select(length > 1) | .[0].entity) | .[] | "contract: entity \(.) is listed twice" ),
  ( $s.entities | group_by(.view) | map(select(length > 1) | .[0].view) | .[] | "contract: view \(.) serves two entities" ),

  # ---- the staged entity file: exactly the contract, nothing more
  ( ($st.entities | keys) as $have | ($want | keys) as $need
    | (($need - $have)[] | "dab-entities.ops.json: \(.) is in the contract but not staged"),
      (($have - $need)[] | "dab-entities.ops.json: \(.) is staged but not in the contract") ),
  ( if ((($st["_dev-excludes"] // []) | sort) != $prod_only) then
      "dab-entities.ops.json: _dev-excludes \(($st["_dev-excludes"] // []) | tojson) is not the contract's prod-only entities \($prod_only | tojson)"
    else empty end ),
  ( $st.entities | to_entries[] | select($want[.key] != null) | .key as $n | .value as $v | $want[$n] as $w
    | ( ($v | entity_problems("dab-entities.ops.json"; $n)),
        (if ($v | src_object) != $w.view then "dab-entities.ops.json [\($n)]: source \($v | src_object | tojson), contract \($w.view | tojson)" else empty end),
        (if ($v.source.type // "") != "view" then "dab-entities.ops.json [\($n)]: source.type is not view" else empty end),
        (if ($v.source["key-fields"] // []) != $w["key-fields"] then "dab-entities.ops.json [\($n)]: key-fields differ from the contract" else empty end),
        (if ($v.health.enabled) != false then "dab-entities.ops.json [\($n)]: health.enabled must be false (Gate HEALTH-PROBE)" else empty end),
        (if ($v.permissions | length) != 1 or $v.permissions[0].role != $role then "dab-entities.ops.json [\($n)]: permissions must be exactly one entry for \($role)" else empty end),
        (if ($v.permissions[0].actions // [] | length) != 1 or (($v.permissions[0].actions[0] | action_name) != "read")
         then "dab-entities.ops.json [\($n)]: the only action must be read" else empty end),
        ($v.permissions[0].actions[0] | if type != "object" then "dab-entities.ops.json [\($n)]: the read action must carry fields.include" else
           ((.fields.include // null) as $inc
            | if ($inc | type) != "array" or ($inc | index("*")) != null then "dab-entities.ops.json [\($n)]: fields.include must list names, never *"
              elif ($inc | sort) != ($w.served | sort) or ($inc | length) != ($w.served | length) then
                "dab-entities.ops.json [\($n)]: fields.include differs from the contract: missing \(($w.served - $inc) | tojson), extra \(($inc - $w.served) | tojson)"
              else empty end),
           (if (.fields.exclude // []) | length > 0 then "dab-entities.ops.json [\($n)]: fields.exclude is not used on Ops entities" else empty end),
           (if has("policy") then "dab-entities.ops.json [\($n)]: a database policy is not part of the contract" else empty end)
         end),
        (if ($v.rest // {}) | (.enabled // true) and ((.methods // ["get"]) != ["get"]) then "dab-entities.ops.json [\($n)]: REST methods must be [get]" else empty end),
        (if ($v.graphql // {}) | (.enabled // true) and ((.operation // "query") != "query") then "dab-entities.ops.json [\($n)]: GraphQL operation must be query" else empty end) ) ),

  # ---- every config the pods can load
  ( [inputs | {file: input_filename, raw: .}][] | .file as $f | (.raw.entities // {}) | if type == "object" then to_entries[] else empty end
    | .key as $n | .value as $v | ($v | src_object | norm_object) as $o
    # An Ops entity, or anything over a dataapi view, must be the staged entity, unchanged: activating one is a copy.
    | ( (if ($n | startswith("Ops_")) or ($o | startswith("dataapi.")) then
           (if $st.entities[$n] == null then "\($f) [\($n)]: serves an Ops entity or a dataapi view that is not in dab-entities.ops.json"
            elif $v != $st.entities[$n] then "\($f) [\($n)]: differs from the staged entity in dab-entities.ops.json (copy it unchanged)"
            else empty end)
         else empty end),
        # A base object that the contract serves only through a view must never be served itself.
        (if $base[$o] != null then "\($f) [\($n)]: serves the base object \($o) directly; \($base[$o])" else empty end) ) )
)
