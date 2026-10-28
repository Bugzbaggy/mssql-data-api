# Program for ci/gate-dev-all-protected.sh (kept in a file so no shell can mangle its escapes).
# Inputs: the base config, then every config/dev-all/*.json.  $list: the protected-excluded.txt
# text.  $base: the base path as passed.  Emits "checked=<n>" then one line per problem.
include "dab-perms";

# The @env() key of a config's connection string, or null unless it is exactly @env('<KEY>').
def conn_key:
  (.["data-source"]["connection-string"] // "") | tostring
  | if test("^@env\\('[A-Z0-9_a-z]+'\\)$") then capture("^@env\\('(?<k>[A-Z0-9_a-z]+)'\\)$").k else null end;

# The file name the dev-all naming rule gives the config on key $k (docs/dev-all-status.md, and
# expected_file in ci/gate-dev-all-tree.sh): CONN_DEV_AppDb_MNO_DEV -> dab-config.dev-all.mno.json,
# CONN_DEVVO_<...> -> dab-config.dev-all.vo.<short>.json.
def expected_file($k):
  ($k | startswith("CONN_DEVVO_")) as $vo
  | ($k | if $vo then ltrimstr("CONN_DEVVO_") else ltrimstr("CONN_DEV_") end
        | rtrimstr("_DEV") | ltrimstr("AppDb_") | split("_") | join("") | ascii_downcase) as $short
  | "dab-config.dev-all." + (if $vo then "vo." else "" end) + $short + ".json";

[inputs | {path: input_filename, file: (input_filename | split("/") | last), base: (input_filename == $base),
           key: conn_key, raw: ., entities: ((.entities // {}) | if type == "object" then to_entries else [] end
                                              | map(. + {obj: (.value | src_object | norm_object)}))}] as $cfgs
| ($cfgs | map(select(.base | not) | {(.file): .key}) | add // {}) as $keyof
| [ $list | split("\n")[] | rtrimstr("\r")
    | select(length > 0 and (startswith("#") | not)) | split("\t")
    | {file: .[0], object: (.[1] // ""), reason: (.[2] // "")} ] as $rows
| [ # the tree itself: shapes DAB would serve that no line can see
    ( $cfgs[] | . as $c
      | ($c.raw | config_problems($c.file; $c.base)),
        (if $c.key == null then "\($c.file): connection-string is not exactly @env('<KEY>')"
         elif ($c.base | not) and ($c.file != expected_file($c.key)) then
           "\($c.file) resolves \($c.key), which the naming rule writes as \(expected_file($c.key)) — a renamed or decoy config would point the list at the wrong database"
         else empty end),
        ($c.entities[] | .key as $n | .value | entity_problems($c.file; $n)) ),
    # every line, against every entity on the same database
    ( $rows[] as $r
      | if ($r.object == "" or $r.reason == "") then
          "malformed line (want <config> TAB <schema.object> TAB <reason>): \([$r.file, $r.object, $r.reason] | join(" | "))"
        elif ($keyof | has($r.file) | not) then
          "\($r.file) is on the list but not in the config dir — a stale list; update it with the tree (docs/dev-all-status.md)"
        elif $keyof[$r.file] == null then
          "\($r.file): cannot tell which database it serves (connection-string is not exactly @env('<KEY>'))"
        else
          $keyof[$r.file] as $k
          | ($r.object | norm_object) as $o
          | [ $cfgs[] | select(.key == $k) | .file as $cf | .entities[]
              | select(.obj == $o) | {cfg: $cf, key, value} ] as $hits
          | ($r.reason | index(":")) as $colon
          | ($r.reason | if $colon then .[:$colon] else . end) as $kind
          | ($r.reason | if $colon then .[($colon + 1):] else "" end) as $arg
          | if ($kind == "secret-columns" or $kind == "pii-columns") then
              $hits[] as $h | ($arg | split(","))[] as $col
              | ($h.value | roles_serving($col)) as $roles
              | select(($roles | length) > 0)
              | "\($h.cfg) serves \($r.object) as [\($h.key)] with \($kind | rtrimstr("s")) \($col) visible to role(s) \($roles | join(","))"
            elif $kind == "canonical" then
              # A client pins this one entity NAME. The same object name served under any other
              # name, on this database or any other (another database's copy, or a synonym), is an
              # unpinned read of the same rows.
              ( [ $cfgs[] | .file as $cf | .entities[] | select(.obj == $o) | {cfg: $cf, key} ][]
                | select(.key != $arg)
                | "\(.cfg) serves \($r.object) as [\(.key)] — only [\($arg)] may, the name the client pins" )
            else
              $hits[] | "\(.cfg) serves \($r.object) as [\(.key)] — \($r.reason); it must not be served"
            end
        end )
  ] as $problems
| "checked=\($rows | length)", $problems[]
