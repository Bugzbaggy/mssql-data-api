#!/usr/bin/env bash
# Gate PROTECTION — the config-protection gates as one command, so every path that judges a set of
# configs runs exactly one list: the self-tests run it on the checkout, and Gate ARTIFACT
# (ci/gate-image-configs.sh) runs it again on the configs baked into a built image. The CI workflow
# runs the same gates as separate steps so a failure names its gate.
#
# Pure jq: no Docker, no database, no credentials. Gate RBAC runs here as its jq assertion only
# (GATE_RBAC_CLI=off); its Docker effective-permissions cross-check stays in the self-tests.
#
# Usage: ci/gate-protection.sh   (any working directory; it runs from its own tree's root)
set -euo pipefail
cd "$(dirname "$0")/.."

ci/gate-dev-all-tree.sh
ci/gate-no-write-tools.sh
ci/gate-key-fields.sh
ci/gate-health-probe.sh
ci/gate-dev-all-protected.sh
ci/gate-conn-keys.sh >/dev/null
ci/gate-dml-tools.sh dab-config.json config/dab-config.dev.json
GATE_RBAC_CLI=off ci/gate-rbac.sh dab-config.json config/dab-config.region2.json config/dab-config.dev.json \
  dab-config.dev-all.json config/dev-all/*.json
