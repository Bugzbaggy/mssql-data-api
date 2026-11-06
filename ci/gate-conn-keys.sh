#!/usr/bin/env bash
# Derive the CONN_* env-var names a dev-all config tree requires — one per line, sorted, unique.
# Gate VALIDATE feeds these to `docker run -e <KEY>`, so a generator-added DB fails the gate by
# name. stdout is the key list only; diagnostics go to stderr or the caller parses them as keys.
#
# Usage: ci/gate-conn-keys.sh [config.json ...]   (default: the whole dev-all tree)
set -uo pipefail
# shellcheck source=ci/lib.sh
. "$(dirname "$0")/lib.sh"

# gate_fail writes ::error:: to stdout under GITHUB_ACTIONS, which would land in the key list.
require_jq >&2

# No args -> the dev-all deployment. Args are treated as BASE configs and expanded into
# base + their own data-source-files.
if [ "$#" -eq 0 ]; then
  mapfile -t set_args < <(dev_all_configs)
else
  set_args=()
  for a in "$@"; do
    mapfile -t sub < <(configs_for_base "$a")
    set_args+=( "${sub[@]}" )
  done
fi
set -- "${set_args[@]}"

require_files "$@" >&2

rc=0
keys=()
for f in "$@"; do
  # // empty: a missing data-source yields null from jq -r, which would become the literal key
  # "null" and fail later as "no key null" instead of naming this file.
  cs=$(jq -r '.["data-source"]["connection-string"] // empty' "$f" 2>/dev/null) || {
    gate_fail "conn-keys: $f is not valid JSON" >&2; rc=1; continue; }

  if [ -z "$cs" ]; then
    gate_fail "conn-keys: $f has no .data-source.connection-string" >&2; rc=1; continue
  fi

  # Never echo $cs here — reaching this branch means it is a committed credential.
  case "$cs" in
    "@env('"*"')") : ;;
    *) gate_fail "conn-keys: $f connection-string is not an @env() reference (plaintext secret?)" >&2
       rc=1; continue ;;
  esac

  k=${cs#@env(\'}
  keys+=( "${k%\')}" )
done

[ "$rc" -eq 0 ] || exit "$rc"

printf '%s\n' "${keys[@]}" | sort -u
