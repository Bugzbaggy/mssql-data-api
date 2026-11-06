#!/usr/bin/env bash
# Gate VENDOR-DRIFT — services/dba-mcp/ is a VENDORED COPY of mssql-dba-mcp at the
# commit pinned in services/dba-mcp/.upstream. Editing it here forks the server
# silently: upstream keeps shipping, this copy quietly diverges, and nothing says so.
#
# This gate hashes the vendored tree and compares it to the hash recorded in the pin.
# To change the server: land the change upstream, then
#   node scripts/sync-dba-mcp.mjs --sha <new-sha>
#   ci/gate-vendor-drift.sh --write
#
# Scope: this only catches ACCIDENTAL drift - someone editing services/dba-mcp/ in this
# repo without realising it's vendored. Nothing here verifies that the recorded `hash`
# actually corresponds to the content at the pinned `sha` in the upstream repo; running
# --write is an assertion by the person who ran it that the tree matches upstream, not
# proof of it. A deliberate local edit followed by --write will launder it into a green
# gate.
#
# Usage: ci/gate-vendor-drift.sh [alternate-root]
#        ci/gate-vendor-drift.sh --write     recompute and store the hash
set -uo pipefail
. "$(dirname "$0")/lib.sh"

WRITE=0
if [ "${1:-}" = "--write" ]; then WRITE=1; shift; fi
# Paths resolve from the CURRENT DIRECTORY; the self-test runs this against a copy in
# a temp root while lib.sh still comes from the real repo.
if [ "$#" -ge 1 ]; then cd "$1" || exit 2; fi

require_jq

DIR=services/dba-mcp
PIN="$DIR/.upstream"
require_files "$PIN"

# What we hash, and why: services/dba-mcp/ also holds package-lock.json (repo-owned,
# not part of the upstream pin), and node_modules/ + dist/ (git-ignored build output
# that's machine-dependent and wasn't even fetched from upstream). Hashing the whole
# directory would make the hash depend on local `npm install` state and on files a
# later task adds (Dockerfile, .dockerignore) that have nothing to do with vendoring.
# Instead we hash exactly the paths the pin claims to vendor: .upstream's own `paths`
# array (each entry is "server/X" upstream, mapped to "services/dba-mcp/X" here),
# read at runtime so adding a vendored path to the pin automatically extends coverage.
#
# Deterministic: LC_ALL=C sort, and hash both path and content so an add, a delete
# and an edit each move the hash.
# Populates the global VENDOR_FILES array with every file the pin's `paths` resolve to.
# Deliberately NOT run inside a command substitution: `foo=$(...)` forks a subshell, and
# a count set there would vanish the instant the substitution returns, leaving the
# caller unable to tell "walked zero files" apart from "walked files that happen to hash
# to X". Collecting the list here, in the caller's own shell, is what makes that
# distinction observable at all.
collect_vendor_files() {
  local rel mapped f
  VENDOR_FILES=()
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    mapped="$DIR/${rel#server/}"
    if [ -d "$mapped" ]; then
      while IFS= read -r -d '' f; do VENDOR_FILES+=("$f"); done \
        < <(find "$mapped" -type f -print0 2>/dev/null)
    elif [ -f "$mapped" ]; then
      VENDOR_FILES+=("$mapped")
    fi
  done < <(jq -r '.paths[]' "$PIN" 2>/dev/null | tr -d '\r')
}

vendor_hash() {   # vendor_hash <file...>
  printf '%s\0' "$@" | LC_ALL=C sort -z \
    | xargs -0 sha256sum 2>/dev/null \
    | sed -E 's/^([0-9a-f]{64}) [ *]/\1  /' \
    | sha256sum | cut -d' ' -f1
}
# The sed step above normalises the per-file separator before the outer hash: Git
# Bash's sha256sum prints "<hash> *<path>" (binary-mode marker), GNU coreutils on
# Linux prints "<hash>  <path>" (two spaces, text mode). Same bytes, different
# separator, so without this the outer hash is platform-dependent and the gate
# reports drift on an unmodified tree. Anchored to the 64-hex prefix so a path that
# happens to contain " *" is never touched — do not loosen this to a bare `s/ \*/  /`.

collect_vendor_files
if [ "${#VENDOR_FILES[@]}" -eq 0 ]; then
  gate_fail "Gate VENDOR-DRIFT FAIL: $PIN's 'paths' resolved to zero files under $DIR — likely an empty or stale paths array (has upstream's layout moved, e.g. server/src renamed?). Refusing to record or verify a hash over nothing."
  exit 1
fi

actual=$(vendor_hash "${VENDOR_FILES[@]}")

if [ "$WRITE" -eq 1 ]; then
  tmp=$(mktemp)
  jq --arg h "$actual" '.hash = $h' "$PIN" > "$tmp" && mv "$tmp" "$PIN"
  gate_ok "Gate VENDOR-DRIFT: hash recorded ($actual)"
  exit 0
fi

expected=$(jq -r '.hash // empty' "$PIN" 2>/dev/null | tr -d '\r')
if [ -z "$expected" ]; then
  gate_fail "Gate VENDOR-DRIFT FAIL: $PIN records no hash — run: ci/gate-vendor-drift.sh --write"
  exit 1
fi

if [ "$actual" != "$expected" ]; then
  gate_fail "Gate VENDOR-DRIFT FAIL: $DIR does not match its pin. Land the change in mssql-dba-mcp, then re-sync. (pinned $expected, found $actual)"
  exit 1
fi

gate_ok "Gate VENDOR-DRIFT: $DIR matches $(jq -r '.sha' "$PIN" | tr -d '\r' | cut -c1-7)"
exit 0
