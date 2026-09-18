#!/usr/bin/env bash
# Shared helpers for the appdb-data-api CI gates.

gate_fail() {   # gate_fail <message>
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::error::%s\n' "$1"
  else
    printf 'ERROR: %s\n' "$1" >&2
  fi
}

gate_ok() {     # gate_ok <message>
  printf 'OK: %s\n' "$1"
}

require_jq() {
  command -v jq >/dev/null 2>&1 || { gate_fail "jq is required but not installed"; exit 127; }
}

require_files() {   # require_files <path...>
  [ "$#" -ge 1 ] || { gate_fail "no config files given"; exit 2; }
  local f
  for f in "$@"; do
    [ -f "$f" ] || { gate_fail "config file not found: $f"; exit 2; }
  done
}

# Config discovery, defined once. Callers run from appdb-data-api/.
# Derived from the base's data-source-files, not a glob: that is what the pod actually resolves.
configs_for_base() {   # configs_for_base <base.json> -> base + each data-source-file it lists
  local base="$1"
  printf '%s\n' "$base"
  # tr -d '\r': jq built for Windows emits CRLF. The CR rides along inside each path and
  # every downstream "config file not found" is then a false negative. No-op on Linux.
  jq -r '(.["data-source-files"] // [])[]' "$base" 2>/dev/null | tr -d '\r'
}
dev_all_configs() { configs_for_base dab-config.dev-all.json; }

# Every config file in the repo. Callers filter; see gate-no-write-tools.sh.
all_configs() {
  printf '%s\n' dab-config*.json config/dab-config.*.json config/dev-all/*.json
}
