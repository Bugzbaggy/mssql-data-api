# DAB 2.0.9 permission semantics for the column gate (DEV-ALL-PROTECTED), kept apart so another gate can share them.
# Load with:  jq -L "$(dirname "$0")" 'include "dab-perms"; ...'
#
# What DAB resolves at startup (Azure/data-api-builder v2.0.9), and therefore what these helpers model
# (each point reproduced against a real 2.0.9 container on 2026-10-10):
#  - Action names match case-insensitively ("Read", "READ"), and "*" and "all" cover read.
#  - REST and MCP use a role's LAST permissions entry and its LAST read action (AuthorizationResolver
#    assigns RoleToOperationMap[role] and OperationToColumnMap[op]), but GraphQL unions EVERY read
#    action of every entry for the role (FieldToRolesMap). So a column counts as served when ANY read
#    action of the role serves it — the union covers every surface.
#  - include absent, or exactly ["*"], means every column; otherwise each include entry that is not
#    in exclude (EXACT name) is looked up in the column map IGNORING ASCII case. exclude exactly ["*"]
#    hides everything; otherwise it removes entries by exact name ("A,B" is one name). A list mixing
#    "*" with names is read literally in production mode (only dev-mode validation rejects it).
#  - source is a string "schema.object" or {"object": ...}; brackets only quote; no schema means dbo.
#    SQL Server ignores trailing spaces and folds width/case, and skips some invisible characters, so
#    only plain ASCII names can be compared safely: anything else is a problem, not a guess.
#  - autoentities (in any config) and data-source-files inside a child config both make DAB serve
#    entities that no .entities walk sees; mappings and entity-level fields can serve a hidden column
#    under an allowed name; @env()/@akv() is expanded inside actions and field lists.

def src_object:
  (.source // "") | if type == "string" then . elif type == "object" then (.object // "" | tostring) else "" end;

# [schema.]object, each part plain ASCII and optionally bracketed. No spaces, no empty schema.
def plain_object: test("^(\\[?[A-Za-z0-9_]+\\]?\\.)?\\[?[A-Za-z0-9_]+\\]?$");
def plain_name: test("^[A-Za-z0-9_]+$");

def norm_object:
  ascii_downcase | split("[") | join("") | split("]") | join("")
  | if index(".") then . else "dbo." + . end;

def action_name:
  if type == "string" then ascii_downcase
  elif type == "object" then ((.action // "") | tostring | ascii_downcase)
  else "" end;

def is_read_action: action_name as $n | ($n == "read" or $n == "*" or $n == "all");

def wildcard_only: type == "array" and length == 1 and .[0] == "*";

# {role: [every read-capable action of every permissions entry for that role]}
def read_actions_by_role:
  reduce ((.permissions // []) | if type == "array" then .[] else empty end) as $p ({};
    .[($p.role // "") | tostring] += [($p.actions // []) | if type == "array" then .[] else empty end
                                       | select(is_read_action)]);

# Given one read action: is column $c served?
def serves($c):
  if type == "string" then true
  else
    (.fields.include // null) as $inc
    | (.fields.exclude // []) as $exc
    | if ($exc | wildcard_only) then false
      elif ($inc == null or ($inc | wildcard_only)) then (($exc | index($c)) == null)
      else any(($inc | if type == "array" then .[] else empty end);
               (tostring | ascii_downcase) == ($c | ascii_downcase) and (. as $i | ($exc | index($i)) == null))
      end
  end;

# Roles of this entity for which some read action serves column $c.
def roles_serving($c): read_actions_by_role | to_entries | map(select(any(.value[]; serves($c))) | .key);

# Config-level shapes DAB serves without any .entities walk seeing them.
def config_problems($cfg; $is_base):
  (if has("autoentities") then "\($cfg): declares autoentities — DAB generates entities from it with no field filter (an empty {} in the base switches child autoentities on)" else empty end),
  (if ($is_base | not) and has("data-source-files") then "\($cfg): declares data-source-files — DAB loads nested configs that no gate reads" else empty end),
  (if has("entities") and ((.entities | type) != "object") then "\($cfg): entities is not an object" else empty end);

# Entity-level shapes that defeat the column checks, or that the checks cannot evaluate.
def entity_problems($cfg; $name):
  . as $e
  | ( (if ($name | plain_name | not) then "entity name \($name | tojson) is not plain [A-Za-z0-9_]" else empty end),
      (if ($e | src_object | plain_object | not) then "source \($e | src_object | tojson) is not a plain [schema.]object name — SQL Server may still resolve it to a protected object" else empty end),
      (if ($e | type) == "object" and ($e | has("mappings")) then "declares mappings — they can serve a hidden column under an allowed name" else empty end),
      (if ($e | type) == "object" and ($e | has("fields")) then "declares entity-level fields — aliases can serve a hidden column under an allowed name" else empty end),
      ([$e | .. | strings | select(test("@(env|akv)\\("))] | if length > 0 then "uses \(.[0] | tojson) — DAB expands @env()/@akv() inside entities; keep it to the data source" else empty end),
      (($e.permissions // null) as $ps
       | if ($ps | type) != "array" then "permissions is not a list"
         else ($ps[] | . as $p
           | if (type != "object") then "a permissions entry is not an object"
             elif (($p.role // null) | type) != "string" then "a permissions entry has no role name"
             elif (($p.actions // null) | type) != "array" then "the actions of role \($p.role | tojson) are not a list"
             else ($p.actions[] | . as $a
               | if type == "string" then empty
                 elif type != "object" then "role \($p.role | tojson) has an action that is neither a name nor an object"
                 elif ((.action // null) | type) != "string" then "role \($p.role | tojson) has an action object with no action name"
                 else ((.fields // {}) as $f
                   | if ($f | type) != "object" then "role \($p.role | tojson): fields is not an object"
                     else (["include", "exclude"][] as $k | ($f[$k] // null) as $l
                       | if $l == null then empty
                         elif ($l | type) != "array" or any($l[]; type != "string") then "role \($p.role | tojson): fields.\($k) is not a list of names"
                         elif (($l | index("*")) != null and ($l | length) > 1) then "role \($p.role | tojson): fields.\($k) mixes \"*\" with names — DAB reads that list literally in production mode"
                         else empty end)
                     end)
                 end)
             end)
         end)
    ) | "\($cfg) [\($name)]: \(.)";
