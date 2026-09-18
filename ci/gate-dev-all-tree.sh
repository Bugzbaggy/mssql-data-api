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

# --- 5/6. each child serves something, on the right host ----------------------------
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

  conn=$(jq -r '.["data-source"]["connection-string"] // empty' "$f" 2>/dev/null | nocr)
  if [ -z "$conn" ]; then
    gate_fail "Gate DEV-ALL-TREE FAIL: $f has no data-source.connection-string"
    rc=1
    continue
  fi
  key=$(printf '%s' "$conn" | sed "s/@env('//;s/')//")

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
