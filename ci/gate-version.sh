#!/usr/bin/env bash
# Gate VERSION — the DAB tag must agree in every file that pins it, docs included; the Dockerfile
# FROM tag is the source of truth. Optional arg: alternate root, used by the self-test.
# See docs/ci-cd-dev.md §5.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
cd "${1:-$(dirname "$0")/..}" || exit 2   # -> appdb-data-api/

WF=.github/workflows/ci.yml
require_files Dockerfile docker-compose.yml deploy/chart/Chart.yaml deploy/deployment.yaml \
              ci/gate-rbac.sh deploy/README.md docs/ci-cd-dev.md README.md "$WF"

want=$(sed -n 's|^FROM .*/data-api-builder:\([^ ]*\).*|\1|p' Dockerfile | head -1)
[ -n "$want" ] || { gate_fail "Gate VERSION: no data-api-builder FROM tag in Dockerfile"; exit 1; }

rc=0
same() {   # same <label> <found>
  if [ "$2" = "$want" ]; then
    gate_ok "Gate VERSION: $1 = $2"
  else
    gate_fail "Gate VERSION FAIL: $1 pins '$2', Dockerfile pins '$want'"
    rc=1
  fi
}

img() { sed -n "s|^ *$2: .*/data-api-builder:\\(.*\\)|\\1|p" "$1" | head -1; }

same "docker-compose.yml"             "$(img docker-compose.yml image)"
same "deploy/deployment.yaml"         "$(img deploy/deployment.yaml image)"
# The workflow only pins DAB_IMAGE when it runs the live validate. This CI does
# not, so check it only if the pin is actually there.
wf_tag=$(img "$WF" DAB_IMAGE)
if [ -n "$wf_tag" ]; then
  same "workflow DAB_IMAGE" "$wf_tag"
else
  gate_ok "Gate VERSION: workflow pins no DAB_IMAGE (live validate not run in CI)"
fi
same "Chart.yaml appVersion"          "$(sed -n 's/^appVersion: *"*\([^"]*\)"*/\1/p' deploy/chart/Chart.yaml | head -1)"
same "gate-rbac.sh DAB_IMAGE default" "$(sed -n 's|^DAB_IMAGE=.*/data-api-builder:\([^}"]*\).*|\1|p' ci/gate-rbac.sh | head -1)"

# README.md's version badge encodes the tag its own way — shields.io URL segments
# (Data%20API%20Builder-<tag>-<color>), not a `data-api-builder:<tag>` pin — so the
# loop below over deploy/README.md and docs/ci-cd-dev.md never sees it. Checked
# separately, same "same" helper.
badge_tag=$(sed -n 's|.*Data%20API%20Builder-\([^-]*\)-[0-9A-Fa-f]*).*|\1|p' README.md | head -1)
if [ -n "$badge_tag" ]; then
  same "README.md DAB badge" "$badge_tag"
else
  gate_fail "Gate VERSION FAIL: README.md has no Data API Builder badge"
  rc=1
fi

# Runnable copy-paste commands in the docs skew the same way, by hand. CHANGELOG.md is excluded
# on purpose: it records the 2.4.29 -> 2.0.9 correction and must keep the old tag.
# Docker's own tag charset, so trailing prose punctuation ("…:2.0.9." or "…:2.0.9,") is not
# swallowed into the tag, and a placeholder like :<tag> or :${TAG} simply does not match.
for d in deploy/README.md docs/ci-cd-dev.md; do
  tags=$(grep -oE 'data-api-builder:[A-Za-z0-9_][A-Za-z0-9._-]*' "$d" | cut -d: -f2 \
         | sed 's/[.,]*$//' | sort -u)
  # Zero tags means the loop below would pass vacuously — a doc that drops its pin is a skew too.
  if [ -z "$tags" ]; then
    gate_fail "Gate VERSION FAIL: $d names no data-api-builder:<tag>"
    rc=1
    continue
  fi
  for t in $tags; do same "$d" "$t"; done
done

exit "$rc"
