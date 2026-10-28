#!/usr/bin/env bash
# Gate IMAGE-UID — the uid the built image actually runs as must equal the uid the chart pins.
#
# The Dockerfile says `USER $APP_UID`, which resolves against whatever the BASE image defines; the
# chart hardcodes the number. A base-image bump that changes or drops APP_UID keeps both files
# looking correct while they disagree, and nothing before the kubelet notices: `runAsNonRoot` with
# a uid that does not own the app files, or (if APP_UID vanishes) a root image under runAsNonRoot,
# fails at container-create — after helm template, dab validate and --dry-run=server have all
# passed. That is the failure this gate exists to move left. See docs/ci-cd-dev.md §5, §6a.
#
# Usage: gate-image-uid.sh <built-image-ref> [alternate-root]
set -uo pipefail
. "$(dirname "$0")/lib.sh"

IMAGE="${1:-}"
[ -n "$IMAGE" ] || { gate_fail "Gate IMAGE-UID: usage: $0 <built-image-ref>"; exit 2; }
cd "${2:-$(dirname "$0")/..}" || exit 2   # -> appdb-data-api/

VALUES=deploy/chart/values.yaml
require_files Dockerfile "$VALUES"
command -v docker >/dev/null 2>&1 || { gate_fail "Gate IMAGE-UID: docker is required"; exit 127; }

# The chart side: the literal under podSecurityContext.runAsUser.
want=$(awk '/^podSecurityContext:/ { inblk = 1; next }
            inblk && /^[^ ]/       { inblk = 0 }
            inblk && $1 == "runAsUser:" { print $2; exit }' "$VALUES")
[ -n "$want" ] || { gate_fail "Gate IMAGE-UID: no podSecurityContext.runAsUser in $VALUES"; exit 1; }

# The image side: Config.User is what the kubelet falls back to, so it is the value that decides
# whether runAsNonRoot is satisfiable. Empty means the image never issued USER — the original bug.
got=$(docker image inspect --format '{{.Config.User}}' "$IMAGE" 2>/dev/null)
if [ -z "$got" ]; then
  gate_fail "Gate IMAGE-UID FAIL: $IMAGE sets no USER, so it runs as root and runAsNonRoot rejects it"
  exit 1
fi

# `USER app` is as valid as `USER 1654` but cannot be compared to the chart's number, so resolve a
# name through the image's own passwd. runAsUser must be numeric — the kubelet never reads passwd.
case "$got" in
  *[!0-9]*)
    uid=$(docker run --rm --entrypoint sh "$IMAGE" -c 'id -u' 2>/dev/null)
    [ -n "$uid" ] || { gate_fail "Gate IMAGE-UID FAIL: cannot resolve USER '$got' in $IMAGE to a uid"; exit 1; }
    got="$uid" ;;
esac

if [ "$got" = "$want" ]; then
  gate_ok "Gate IMAGE-UID: image runs as uid $got = chart podSecurityContext.runAsUser"
else
  gate_fail "Gate IMAGE-UID FAIL: image runs as uid '$got' but the chart pins '$want' — a pod will"
  gate_fail "  start as $got with a securityContext demanding $want. Reconcile Dockerfile USER"
  gate_fail "  (APP_UID from the base image) with $VALUES."
  exit 1
fi
