#!/usr/bin/env bash
# Gate CONFIG-FLAG — `--config-file` must appear in no compose file or k8s manifest anywhere in the
# repo. The image ENTRYPOINT is the service and silently ignores it, so the container loads the base
# prod config instead of the intended one. Selecting a config means running the CLI: `start -c <path>`.
# Prose may name the flag; only `command:`/`args:`/`entrypoint:` uses are a defect.
# Optional arg: alternate root, used by the self-test. See docs/ci-cd-dev.md §2.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
cd "${1:-$(dirname "$0")/..}" || exit 2   # -> repo root

rc=0
found=0
while IFS= read -r f; do
  found=1
  # ^[^#]* cannot cross a '#', so a commented-out example is ignored while a real key with a
  # trailing comment still matches.
  hits=$(grep -nE '^[^#]*(command|args|entrypoint):.*--config-file' "$f")
  if [ -n "$hits" ]; then
    gate_fail "Gate CONFIG-FLAG FAIL: $f uses the ignored --config-file flag; use \`start -c <path>\` on the CLI"
    printf '%s\n' "$hits"
    rc=1
  fi
done < <(find . -path ./node_modules -prune -o \
              \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \
                 -o -name '*deployment.yaml' -o -name '*deployment.yml' \) -print)

# A find that matches nothing would pass vacuously — same trap gate-rbac.sh guards against.
[ "$found" -eq 1 ] || { gate_fail "Gate CONFIG-FLAG: no compose/manifest files found under $PWD"; exit 2; }
[ "$rc" -eq 0 ] && gate_ok "Gate CONFIG-FLAG: no compose file or manifest uses --config-file"

exit "$rc"
