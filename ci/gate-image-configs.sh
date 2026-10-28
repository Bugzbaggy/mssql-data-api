#!/usr/bin/env bash
# Gate ARTIFACT — the PROTECTION gates on the configs baked into an image, not on the checkout.
#
# Every other gate checks the commit the workflow runs on, but a pod serves the configs inside its
# image (Dockerfile: COPY dab-config*.json ./ and COPY config ./config). A redeploy of an older
# image tag, or an image built from another commit, can predate a protection, so a green gate on
# the checkout says nothing about it. This copies the image's dab-config*.json and config/ into a
# scratch tree, puts THIS checkout's ci/ and protected list beside them (never the image's own,
# which may be older or weaker) and runs ci/gate-protection.sh there. An image whose configs fail
# today's gates is refused.
#
# Needs Docker (the image is created, never run) and GNU tar.
# Usage: ci/gate-image-configs.sh <image:tag | image id>
set -euo pipefail
IMAGE="${1:?usage: ci/gate-image-configs.sh <image:tag>}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # the repo root of this checkout

work="$(mktemp -d)"
cid=""
cleanup() {
  if [ -n "$cid" ]; then docker rm -f "$cid" >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

cid="$(docker create "$IMAGE")"
# docker cp streams /App as a tar archive; extract only the configs. tar fails if either is missing,
# so an image without its configs cannot pass by having nothing to check.
docker cp "$cid:/App" - | tar -x -C "$work" --wildcards 'App/dab-config*.json' 'App/config'
rm -rf "$work/App/ci"
cp -R "$HERE/ci" "$work/App/ci"
mkdir -p "$work/App/config/dev-all"
cp "$HERE/config/dev-all/protected-excluded.txt" "$work/App/config/dev-all/protected-excluded.txt"

echo "Gate ARTIFACT: the configs inside $IMAGE, against this checkout's gates and protected list"
"$work/App/ci/gate-protection.sh"
