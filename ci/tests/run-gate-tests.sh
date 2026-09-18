#!/usr/bin/env bash
# Proves the gates actually gate (docs/ci-cd-dev.md §10).
# Positive cases: the real configs must PASS. Negative cases: each fixture must FAIL.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1   # -> appdb-data-api/

. ci/tests/harness.sh

CI=ci
FIX=ci/tests/fixtures

# Proves the gate LOGIC. GATE_RBAC_CLI=auto also runs the container cross-check.
export GATE_RBAC_CLI="${GATE_RBAC_CLI:-off}"

run() {  # run <expect:pass|fail> <script> <args...>
  local want="$1"; shift
  expect "$want" "$*" "$@"
}

# --- Gate RBAC: positives (the real configs today) ---
run pass "$CI/gate-rbac.sh" dab-config.json
run pass "$CI/gate-rbac.sh" config/dab-config.id.json
run pass "$CI/gate-rbac.sh" config/dab-config.dev.json
run pass "$CI/gate-rbac.sh" dab-config.json config/dab-config.id.json config/dab-config.dev.json

# --- Gate RBAC: negative ---
run fail "$CI/gate-rbac.sh" "$FIX/bad-role-anonymous.json"
run fail "$CI/gate-rbac.sh" "$FIX/bad-role-missing-permissions.json"
# Covers the `jq failed -> rc=1; continue` branch, which no other fixture reaches.
run fail "$CI/gate-rbac.sh" "$FIX/bad-not-json.json"

# The CLI cross-check is off by default (a container start per config). Exercise it once so the
# Role:-line parser and its stale-parser guard are not dead code. Needs Docker; CI has it.
if docker info >/dev/null 2>&1; then
  GATE_RBAC_CLI=auto
  run pass "$CI/gate-rbac.sh" config/dab-config.dev.json
  GATE_RBAC_CLI=off
else
  ok "Gate RBAC CLI cross-check (skipped — no Docker)"
fi

# --- Gate DML-TOOLS: positives ---
run pass "$CI/gate-dml-tools.sh" dab-config.json
run pass "$CI/gate-dml-tools.sh" config/dab-config.dev.json
run pass "$CI/gate-dml-tools.sh" dab-config.json config/dab-config.dev.json

# --- Gate DML-TOOLS: negatives (§10 table) ---
run fail "$CI/gate-dml-tools.sh" "$FIX/bad-dml-read-records-true.json"
run fail "$CI/gate-dml-tools.sh" "$FIX/bad-dml-underscore-typo.json"
# Omitted key = enabled write tool; only the exact-key-set assertion catches it.
run fail "$CI/gate-dml-tools.sh" "$FIX/bad-dml-missing-read-records.json"

# --- A multi-file invocation must fail if ANY file fails ---
run fail "$CI/gate-dml-tools.sh" dab-config.json "$FIX/bad-dml-underscore-typo.json"

# --- Argument handling ---
run fail "$CI/gate-rbac.sh"                                    # no args
run fail "$CI/gate-dml-tools.sh" config/does-not-exist.json    # missing file

# --- dev-all conn-key derivation (feeds Gate VALIDATE's `docker run -e <KEY>` list) ---
# Assert the CONTENT, not just exit 0: a silently-truncated list would pass and then validate
# against a subset of the data sources.
want_keys=$(jq -r '.["data-source"]["connection-string"]' dab-config.dev-all.json config/dev-all/*.json \
              | sed "s/@env('//;s/')//" | sort -u)
got_keys=$("$CI/gate-conn-keys.sh")          # no args -> the canonical dev-all tree
if [ "$got_keys" = "$want_keys" ] && [ -n "$got_keys" ]; then
  ok "conn-keys: default dev-all tree ($(printf '%s\n' "$got_keys" | wc -l | tr -d ' ') keys, exact match)"
else
  bad "conn-keys: default dev-all tree — derived list does not match the configs' @env() references"
fi

run fail "$CI/gate-conn-keys.sh" "$FIX/bad-conn-no-data-source.json"   # would derive the key "null"
run fail "$CI/gate-conn-keys.sh" "$FIX/bad-conn-plaintext.json"        # committed credential
run fail "$CI/gate-conn-keys.sh" "$FIX/bad-not-json.json"
run fail "$CI/gate-conn-keys.sh" config/does-not-exist.json
# One bad file among good ones must fail the whole run, not skip the file.
run fail "$CI/gate-conn-keys.sh" dab-config.dev-all.json "$FIX/bad-conn-no-data-source.json"

# --- Gate NO-WRITE-TOOLS: the write flags are off in every self-contained config ---
run pass "$CI/gate-no-write-tools.sh"            # no args -> discovers every config
run fail "$CI/gate-no-write-tools.sh" "$FIX/bad-dml-missing-create-record.json"   # omitted = enabled
# A self-contained config that lost its whole mcp block must FAIL, not skip as an overlay.
run fail "$CI/gate-no-write-tools.sh" "$FIX/bad-mcp-block-deleted.json"
run fail "$CI/gate-no-write-tools.sh" "$FIX/bad-not-json.json"
# Both overlay shapes inherit dml-tools: data-source-file (no runtime) and DAB_ENVIRONMENT (no
# data-source). Skipping every input must not pass vacuously.
run fail "$CI/gate-no-write-tools.sh" config/dev-all/dab-config.dev-all.mno.json
run fail "$CI/gate-no-write-tools.sh" dab-config.Staging.json
run pass "$CI/gate-no-write-tools.sh" dab-config.Staging.json dab-config.json

# gate-conn-keys.sh must keep ::error:: off stdout under Actions, or the caller parses it as a key.
if [ -z "$(GITHUB_ACTIONS=true "$CI/gate-conn-keys.sh" "$FIX/bad-conn-plaintext.json" 2>/dev/null)" ]; then
  ok "conn-keys: stdout stays clean under GITHUB_ACTIONS=true"
else
  bad "conn-keys: an ::error:: line reached stdout under GITHUB_ACTIONS=true"
fi

# The plaintext rejection must not print the credential it rejected.
if "$CI/gate-conn-keys.sh" "$FIX/bad-conn-plaintext.json" 2>&1 | grep -q 'Password='; then
  bad "conn-keys: plaintext rejection leaked the connection string into its own error message"
else
  ok "conn-keys: plaintext rejection does not echo the credential"
fi

# --- Gate VERSION ---
run pass "$CI/gate-version.sh"

# Skew ONE file at a time in a throwaway copy. Skewing the Dockerfile trips every comparison at
# once; skewing a downstream file is the real case (a bump that forgot one) and is the only way
# a regression in a single `same` call gets caught.
vrepo() {  # vrepo [file-to-skew] -> temp root; the gate runs against "$root/app"
  local skew="${1:-}" t
  t=$(mktemp -d)
  mkdir -p "$t/app/ci" "$t/app/deploy/chart" "$t/app/docs" "$t/app/.github/workflows"
  cp Dockerfile docker-compose.yml README.md "$t/app/"
  cp deploy/README.md deploy/deployment.yaml "$t/app/deploy/"
  cp deploy/chart/Chart.yaml "$t/app/deploy/chart/"
  cp docs/ci-cd-dev.md "$t/app/docs/"
  cp ci/gate-rbac.sh "$t/app/ci/"
  # The workflow lives INSIDE the repo. It sat one level up when this project was a
  # directory in a monorepo; gate-version.sh reads .github/workflows/ci.yml now.
  cp .github/workflows/ci.yml "$t/app/.github/workflows/"
  if [ -n "$skew" ]; then
    # Note: the badge tag sits between two literal hyphens (Builder-<tag>-<color>), so a
    # "-skew" suffix would break the gate's own [^-]* extraction and hide the mismatch
    # behind a "no badge" failure instead of exercising the real skew-mismatch message.
    sed -i.bak -e 's|\(data-api-builder\):[^ `")]*|\1:0.0.0-skew|g' \
               -e 's|^appVersion: .*|appVersion: "0.0.0-skew"|' \
               -e 's|\(Data%20API%20Builder-\)[^-]*\(-[0-9A-Fa-f]*)\)|\10.0.0\2|' "$t/app/$skew"
    rm -f "$t/app/$skew.bak"
  fi
  printf '%s\n' "$t"
}

for case in "":pass Dockerfile:fail deploy/chart/Chart.yaml:fail docs/ci-cd-dev.md:fail README.md:fail; do
  f=${case%:*}; want=${case##*:}
  t=$(vrepo "$f")
  run "$want" "$CI/gate-version.sh" "$t/app"    # skewed: ${f:-none}
  rm -rf "$t"
done

# A doc that drops its pin entirely must FAIL, not pass vacuously on an empty tag list.
t=$(vrepo)
sed -i.bak 's|data-api-builder:[A-Za-z0-9_][A-Za-z0-9._-]*|data-api-builder|g' "$t/app/docs/ci-cd-dev.md"
rm -f "$t/app/docs/ci-cd-dev.md.bak"
run fail "$CI/gate-version.sh" "$t/app"         # docs/ci-cd-dev.md pin removed
rm -rf "$t"

# --- Gate DEV-ALL-TREE ---
# Takes no args (the invariant is about the canonical tree), so each negative runs against a
# mutated COPY of the tree in a temp root. The gate resolves paths from CWD; lib.sh comes from
# $0's directory, which stays in the real repo.
CI_ABS=$(cd "$CI" && pwd)

treerepo() {  # treerepo -> temp root holding the base + config/dev-all
  local t; t=$(mktemp -d)
  mkdir -p "$t/config/dev-all"
  cp dab-config.dev-all.json "$t/"
  cp config/dev-all/*.json "$t/config/dev-all/"
  printf '%s\n' "$t"
}
treerun() {  # treerun <pass|fail> <desc> <temp-root>
  # shellcheck disable=SC2016  # the $1/$2 are the inner bash's positionals, passed after `_`
  expect "$1" "$2" bash -c 'cd "$1" && "$2/gate-dev-all-tree.sh"' _ "$3" "$CI_ABS"
}

# Positive: the real tree, and an untouched copy (proves the fixture harness itself is faithful).
run pass "$CI/gate-dev-all-tree.sh"
t=$(treerepo); treerun pass "tree: untouched copy" "$t"; rm -rf "$t"

# A base whose children were dropped: every other gate still passes, this must not.
t=$(treerepo)
jq '.["data-source-files"] = []' "$t/dab-config.dev-all.json" > "$t/x" && mv "$t/x" "$t/dab-config.dev-all.json"
treerun fail "tree: base with empty data-source-files" "$t"; rm -rf "$t"

# A voice child rewired to a messaging key — the credential-crossing case. The pod would resolve
# the wrong host's credential, and Gate RBAC (pinning by filename) would still expect voi-reader.
t=$(treerepo)
jq '.["data-source"]["connection-string"] = "@env('"'"'CONN_DEV_AppDb_Routing_DEV'"'"')"' \
   "$t/config/dev-all/dab-config.dev-all.vo.mno.json" > "$t/x" \
   && mv "$t/x" "$t/config/dev-all/dab-config.dev-all.vo.mno.json"
treerun fail "tree: voice child resolving a messaging key" "$t"; rm -rf "$t"

# The mirror image: a messaging-named child on a voice key, so Gate RBAC pins msg-reader on data
# that lives on the voice host.
t=$(treerepo)
jq '.["data-source"]["connection-string"] = "@env('"'"'CONN_DEVVO_AppDb_Routing_DEV'"'"')"' \
   "$t/config/dev-all/dab-config.dev-all.mno.json" > "$t/x" \
   && mv "$t/x" "$t/config/dev-all/dab-config.dev-all.mno.json"
treerun fail "tree: messaging-named child resolving a voice key" "$t"; rm -rf "$t"

# Generator wrote a config nothing serves — invisible until someone asks for that data.
t=$(treerepo)
cp "$t/config/dev-all/dab-config.dev-all.vo.mno.json" "$t/config/dev-all/dab-config.dev-all.orphan.json"
treerun fail "tree: orphan config the base does not list" "$t"; rm -rf "$t"

# The base listing a file that does not exist.
t=$(treerepo)
rm "$t/config/dev-all/dab-config.dev-all.vo.mno.json"
treerun fail "tree: base lists a missing file" "$t"; rm -rf "$t"

# A child that serves nothing.
t=$(treerepo)
jq '.entities = {}' "$t/config/dev-all/dab-config.dev-all.vo.mno.json" > "$t/x" \
   && mv "$t/x" "$t/config/dev-all/dab-config.dev-all.vo.mno.json"
treerun fail "tree: child with zero entities" "$t"; rm -rf "$t"

# The same child listed twice: the count looks right while a file is missing from disk.
t=$(treerepo)
jq '.["data-source-files"] += ["config/dev-all/dab-config.dev-all.vo.mno.json"]' \
   "$t/dab-config.dev-all.json" > "$t/x" && mv "$t/x" "$t/dab-config.dev-all.json"
treerun fail "tree: base lists the same child twice" "$t"; rm -rf "$t"

# --- Gate VALIDATE (ci/validate-base.sh) ---
# The argument and vacuity checks run before the secret fetch, so they need neither AWS nor Docker.
# The live path is exercised by the workflow, not here.
export DAB_IMAGE="${DAB_IMAGE:-mcr.microsoft.com/azure-databases/data-api-builder:2.0.9}"
run fail "$CI/validate-base.sh"                                        # no args
run fail "$CI/validate-base.sh" some-secret                            # no config
run fail "$CI/validate-base.sh" some-secret config/does-not-exist.json
run fail "$CI/validate-base.sh" some-secret dab-config.dev-all.json --alias            # --alias with no value
run fail "$CI/validate-base.sh" some-secret dab-config.dev-all.json --alias NOEQUALS
run fail "$CI/validate-base.sh" some-secret dab-config.dev-all.json --bogus

# A config that serves nothing must not report a green validate. `dab validate` accepts it.
t=$(mktemp -d)
jq '.entities = {} | .["data-source-files"] = []' dab-config.dev-all.json > "$t/empty.json"
run fail "$CI/validate-base.sh" some-secret "$t/empty.json"
# Same file with its children restored is rejected only later (at the AWS fetch), not by this guard.
rm -rf "$t"

# DAB_IMAGE is required — without it the docker run would be silently malformed.
expect fail "validate-base: unset DAB_IMAGE" \
  env -u DAB_IMAGE "$CI_ABS/validate-base.sh" some-secret dab-config.dev-all.json

# --- Gate CONFIG-FLAG ---
run pass "$CI/gate-config-flag.sh"

# A manifest that reintroduces the ignored flag must FAIL; prose naming it must not.
t=$(mktemp -d)
printf 'spec:\n  args: ["--config-file", "/App/dab-config.json"]\n' > "$t/deployment.yaml"
run fail "$CI/gate-config-flag.sh" "$t"
printf '# note: args: ["--config-file", ...] is ignored by the ENTRYPOINT\nspec: {}\n' > "$t/deployment.yaml"
run pass "$CI/gate-config-flag.sh" "$t"
rm -rf "$t"

# No compose/manifest at all must error, not pass vacuously.
t=$(mktemp -d)
run fail "$CI/gate-config-flag.sh" "$t"
rm -rf "$t"

# --- Gate IMAGE-UID ---
# The image-side cases need a built image, so they are opt-in like GATE_RBAC_CLI:
#   GATE_IMAGE_UID_IMAGE=<ref> ci/tests/run-gate-tests.sh
# The cases below cover the chart-side parsing, which needs no image.

# No image ref at all is a usage error, not a silent pass.
run fail "$CI/gate-image-uid.sh"

# A values.yaml with no podSecurityContext.runAsUser must FAIL: that is the render which emits
# runAsNonRoot with no uid, i.e. the bug the gate exists to catch.
# The FROM tag is never built, so it is deliberately a placeholder: hardcoding the real one here
# would be one more pin for a version bump to skew, which is what Gate VERSION exists to prevent.
uidrepo() {  # uidrepo <runAsUser-line> -> temp root
  local d; d=$(mktemp -d)
  mkdir -p "$d/deploy/chart"
  printf 'FROM example/data-api-builder:unused\nUSER $APP_UID\n' > "$d/Dockerfile"
  printf 'podSecurityContext:\n%b' "$1" > "$d/deploy/chart/values.yaml"
  printf '%s' "$d"
}

t=$(uidrepo '  runAsGroup: 1654\n')
run fail "$CI/gate-image-uid.sh" some-image:tag "$t"     # runAsUser absent
rm -rf "$t"

if [ -n "${GATE_IMAGE_UID_IMAGE:-}" ]; then
  run pass "$CI/gate-image-uid.sh" "$GATE_IMAGE_UID_IMAGE"
  # Same image, chart pinning a different uid: the drift a base-image bump would introduce.
  t=$(uidrepo '  runAsUser: 9999\n')
  run fail "$CI/gate-image-uid.sh" "$GATE_IMAGE_UID_IMAGE" "$t"
  rm -rf "$t"
  # An image that never issues USER is the original defect and must FAIL. Base tag read from the
  # Dockerfile rather than pinned again here; in CI the gate job has already pulled it (Gate A).
  run fail "$CI/gate-image-uid.sh" "$(sed -n 's|^FROM \(.*\)|\1|p' Dockerfile | head -1)"
fi

summary gate
