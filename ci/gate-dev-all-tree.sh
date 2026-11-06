#!/usr/bin/env bash
# Gate DEV-ALL-TREE — the dev-all base and its child configs must agree with each other
# and with what is on disk. Optional arg: alternate root, used by the self-test.
#
# `dab validate` is happy with a base that lists nothing, a child nothing serves, or a
# child wired to the wrong host's credential: each file is individually well-formed. The
# damage only shows at runtime, as an entity that silently serves no data or - worse - one
# that resolves the wrong host's connection string while Gate RBAC still pins the role by
# filename. This gate checks the tree as a whole.
#
# Checks:
#   1. the base lists at least one data-source-file
#   2. every file it lists exists
#   3. no file is listed twice
#   4. no config in config/dev-all/ is missing from the base's list (no orphans)
#   5. every child serves at least one entity
#   6. a child's connection key matches its filename's domain:
#        config/dev-all/*.vo.*.json  -> @env('CONN_DEVVO_...')   (voice host)
#        every other child           -> @env('CONN_DEV_...')     (messaging host)
#   7. the base declares NO entities of its own — DAB would serve them on the base's data
#      source, outside every child config and Gate DEV-ALL-PROTECTED's per-file list
#   8. no config declares "autoentities" (an empty {} in the base switches child autoentities
#      on), and no child declares its own data-source-files: DAB serves both, no gate reads them
#   9. each child's connection string is exactly @env('<KEY>'), and its file name is the one the
#      naming rule derives from that key, so the file a protected-excluded.txt line names always
#      means the same database (no decoys)
#
# Check 6 is the credential-crossing case and the reason this gate exists: Gate RBAC pins
# appdb-data-api-voi-reader on *.vo.*.json by filename, so a voice-named child pointed at a
# messaging key would hand voice callers messaging data under a voice role.
#
# See docs/ci-cd-dev.md and docs/dev-all-status.md.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

# Paths resolve from the CURRENT DIRECTORY, not from $0's. The self-test runs this gate
# against a mutated COPY of the tree in a temp root while lib.sh still comes from the real
# repo, so a `cd` to $0/.. here would silently re-test the real tree and pass every
# negative case. An explicit root may still be passed as $1.
if [ "$#" -ge 1 ]; then cd "$1" || exit 2; fi

require_jq

BASE=dab-config.dev-all.json
DIR=config/dev-all
require_files "$BASE"

rc=0

# jq built for Windows emits CRLF. Left in place the CR rides along inside every path and
# turns each comparison below into a false failure, so strip it at the source.
nocr() { tr -d '\r'; }

# The naming rule (docs/dev-all-status.md): CONN_DEV_AppDb_MNO_DEV -> dab-config.dev-all.mno.json,
# CONN_DEVVO_AppDb_MNO_DEV -> dab-config.dev-all.vo.mno.json. Drop the host prefix, the _DEV
# suffix and a leading AppDb_, then the underscores, and lower-case what is left.
expected_file() {   # expected_file <key> -> the path the naming rule gives that key
  local k="$1" vo="" short
  case "$k" in CONN_DEVVO_*) vo="vo."; short=${k#CONN_DEVVO_} ;; *) short=${k#CONN_DEV_} ;; esac
  short=${short%_DEV}
  short=${short#AppDb_}
  short=$(printf '%s' "$short" | tr -d '_' | tr '[:upper:]' '[:lower:]')
  printf '%s/dab-config.dev-all.%s%s.json' "$DIR" "$vo" "$short"
}

# --- 1. the base must list children -------------------------------------------------
listed=$(jq -r '(.["data-source-files"] // [])[]' "$BASE" 2>/dev/null | nocr)
if [ -z "$listed" ]; then
  gate_fail "Gate DEV-ALL-TREE FAIL: $BASE lists no data-source-files"
  exit 1
fi
n_listed=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')

# --- 2/3. listed files exist, and are listed once -----------------------------------
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ ! -f "$f" ]; then
    gate_fail "Gate DEV-ALL-TREE FAIL: $BASE lists '$f', which does not exist"
    rc=1
  fi
done <<EOF
$listed
EOF

dupes=$(printf '%s\n' "$listed" | sort | uniq -d)
if [ -n "$dupes" ]; then
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    gate_fail "Gate DEV-ALL-TREE FAIL: $BASE lists '$d' more than once"
    rc=1
  done <<EOF
$dupes
EOF
fi

# --- 4. no orphan config on disk ----------------------------------------------------
if [ -d "$DIR" ]; then
  for f in "$DIR"/*.json; do
    [ -e "$f" ] || continue
    if ! printf '%s\n' "$listed" | grep -qxF "$f"; then
      gate_fail "Gate DEV-ALL-TREE FAIL: $f is on disk but $BASE does not list it"
      rc=1
    fi
  done
fi

# --- 7. the base serves nothing of its own ------------------------------------------
base_ents=$(jq -r '(.entities // {}) | length' "$BASE" 2>/dev/null | nocr)
if [ "$base_ents" != 0 ]; then
  gate_fail "Gate DEV-ALL-TREE FAIL: $BASE declares entities of its own (${base_ents:-unreadable}) — DAB serves them on the base's data source, outside every child config; move them to a config/dev-all/ child"
  rc=1
fi

# --- 8a. autoentities anywhere in the tree ------------------------------------------
# DAB generates entities from it, with no field filter, that no .entities walk sees.
for f in "$BASE" "$DIR"/*.json; do
  [ -e "$f" ] || continue
  if jq -e 'has("autoentities")' "$f" >/dev/null 2>&1; then
    gate_fail "Gate DEV-ALL-TREE FAIL: $f declares autoentities — DAB serves generated entities no gate reads (even an empty {} in the base switches child autoentities on)"
    rc=1
  fi
done

# --- 5/6/8b/9. each child serves something, on the right host, under its own name ----
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] || continue

  n_ent=$(jq -r '(.entities // {}) | length' "$f" 2>/dev/null | nocr)
  if [ -z "$n_ent" ]; then
    gate_fail "Gate DEV-ALL-TREE FAIL: $f is not valid JSON"
    rc=1
    continue
  fi
  if [ "$n_ent" -eq 0 ]; then
    gate_fail "Gate DEV-ALL-TREE FAIL: $f serves zero entities"
    rc=1
  fi

  if jq -e 'has("data-source-files")' "$f" >/dev/null 2>&1; then
    gate_fail "Gate DEV-ALL-TREE FAIL: $f declares its own data-source-files — DAB loads nested configs that no gate reads"
    rc=1
  fi

  conn=$(jq -r '.["data-source"]["connection-string"] // empty' "$f" 2>/dev/null | nocr)
  if [ -z "$conn" ]; then
    gate_fail "Gate DEV-ALL-TREE FAIL: $f has no data-source.connection-string"
    rc=1
    continue
  fi
  case "$conn" in
    "@env('"*"')") key=${conn#@env(\'}; key=${key%\')} ;;
    *) key="" ;;
  esac
  # DAB's @env() match is lazy, so "@env('K');Application Name=x')" still resolves K, with the
  # rest of the string riding along: only a bare key counts.
  if ! [[ "$key" =~ ^[A-Za-z0-9_]+$ ]]; then
    gate_fail "Gate DEV-ALL-TREE FAIL: $f connection-string is not exactly @env('<KEY>')"
    rc=1
    continue
  fi

  want=$(expected_file "$key")
  if [ "$f" != "$want" ]; then
    gate_fail "Gate DEV-ALL-TREE FAIL: $f resolves $key, which the naming rule writes as $want — a renamed or decoy config would point config/dev-all/protected-excluded.txt at the wrong database"
    rc=1
  fi

  case "$f" in
    *dab-config.dev-all.vo.*.json)
      # CONN_DEV_ does not match CONN_DEVVO_: the underscore after DEV keeps them distinct.
      if ! printf '%s' "$key" | grep -qE '^CONN_DEVVO_'; then
        gate_fail "Gate DEV-ALL-TREE FAIL: $f is a voice config (Gate RBAC pins voi-reader on it) but resolves '$key', which is not a CONN_DEVVO_ key"
        rc=1
      fi
      ;;
    *)
      if ! printf '%s' "$key" | grep -qE '^CONN_DEV_'; then
        gate_fail "Gate DEV-ALL-TREE FAIL: $f is a messaging config (Gate RBAC pins msg-reader on it) but resolves '$key', which is not a CONN_DEV_ key"
        rc=1
      fi
      ;;
  esac
done <<EOF
$listed
EOF

[ "$rc" -eq 0 ] && gate_ok "Gate DEV-ALL-TREE: $BASE + $n_listed child config(s) consistent"
exit "$rc"
