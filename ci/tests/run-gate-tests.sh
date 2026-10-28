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
run pass "$CI/gate-rbac.sh" config/dab-config.region2.json
run pass "$CI/gate-rbac.sh" config/dab-config.dev.json
run pass "$CI/gate-rbac.sh" dab-config.json config/dab-config.region2.json config/dab-config.dev.json

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

# --- Gate KEY-FIELDS ---
# Positives: every config in the repo (stored procedures only, so each is skipped), the SP-only
# shape, and a table entity over the demo schema's core.Account with its key declared.
run pass "$CI/gate-key-fields.sh"                       # no args -> every config in the repo
run pass "$CI/gate-key-fields.sh" "$FIX/good-keyfields-sp-only.json"
run pass "$CI/gate-key-fields.sh" --require-tables "$FIX/good-keyfields-table.json"

# Negatives: each way a key-fields declaration can be absent or useless. rc=1 (a finding), never
# rc=2 (a usage error), so a fixture that went missing cannot score as caught.
for fx in missing empty not-array blank-name view; do   # missing: the shape that fails DAB's runtime init
  expect_rc 1 "key-fields: bad-keyfields-$fx.json" "$CI/gate-key-fields.sh" "$FIX/bad-keyfields-$fx.json"
done
run fail "$CI/gate-key-fields.sh" "$FIX/bad-not-json.json"

# One bad file among good ones must fail the whole run.
run fail "$CI/gate-key-fields.sh" "$FIX/good-keyfields-table.json" "$FIX/bad-keyfields-missing.json"

# --require-tables exists so a deployment that lost its entities cannot pass vacuously. The same
# SP-only file passes without it and fails with it — that contrast IS the flag's whole behaviour.
run fail "$CI/gate-key-fields.sh" --require-tables "$FIX/good-keyfields-sp-only.json"
# Today's curated tree has no table entity at all, so --require-tables refuses it too.
run fail "$CI/gate-key-fields.sh" --require-tables dab-config.json config/dab-config.region2.json

# The regression case: a base whose table is keyed plus a regional data-source-file whose table is
# not — the multi-file shape a deployment loads. A gate that cannot catch it is decoration.
K="$FIX/keyfields-tree"
run pass "$CI/gate-key-fields.sh" --require-tables "$K/dab-config.json"
expect_rc 1 "key-fields: the tree with an unkeyed regional table" \
  "$CI/gate-key-fields.sh" --require-tables "$K/dab-config.json" "$K/config/dab-config.region1.json"

# Argument handling.
expect_rc 2 "key-fields: a missing file is a usage error" "$CI/gate-key-fields.sh" config/does-not-exist.json

# --- Gate HEALTH-PROBE ---
# dab-config.json answers /health anonymously, so no entity in it or its data-source-files may run
# an entity-level check. Negatives mutate one file of a copy and must fail with a finding (rc=1).
hpcase() {  # hpcase <rc> <description> <file> <jq filter on it>
  local want="$1" desc="$2" file="$3" filter="$4" t out
  t=$(mktemp -d); mkdir -p "$t/config"; cp dab-config.json "$t/"; cp config/dab-config.region2.json "$t/config/"
  if ! out=$(jq "$filter" "$t/$file") || [ -z "$out" ]; then bad "health-probe: jq mutation failed: $desc"; rm -rf "$t"; return; fi
  printf '%s\n' "$out" > "$t/$file"
  expect_rc "$want" "health-probe: $desc" bash -c 'cd "$1" && "$2"' _ "$t" "$CI_ABS/gate-health-probe.sh"
  rm -rf "$t"
}
CI_ABS=$(cd "$CI" && pwd)
run pass "$CI/gate-health-probe.sh"
hpcase 0 "control: an untouched copy" dab-config.json '.'
hpcase 1 "a base entity turns its health check back on" dab-config.json '.entities.get_account_balance.health.enabled = true'
hpcase 1 "a base entity drops its health block (DAB defaults it on)" dab-config.json 'del(.entities.get_subaccount.health)'
hpcase 1 "a region entity drops its health block" config/dab-config.region2.json 'del(.entities.region2_search_sms.health)'
hpcase 1 'health.enabled as the string "false"' dab-config.json '.entities.get_channels_config.health.enabled = "false"'
hpcase 1 "health.enabled from @env()" config/dab-config.region2.json \
  '.entities.region2_lookup_sms_region_by_umid.health.enabled = "@env('"'"'X_HEALTH'"'"')"'
hpcase 1 "a new entity added without a health block" dab-config.json \
  '.entities.get_x = (.entities.get_account_balance | del(.health))'
hpcase 1 'roles spelled "Anonymous" still count as anonymous' dab-config.json \
  '.runtime.health.roles = ["Anonymous"] | .entities.get_account_balance.health.enabled = true'
# Controls: no anonymous health, so entity checks are not exposed and the gate does not apply.
hpcase 0 "control: health roles without anonymous" dab-config.json \
  '.runtime.health.roles = ["appdb-data-api-msg-reader"] | del(.entities.get_account_balance.health)'
hpcase 0 "control: runtime health disabled" dab-config.json \
  '.runtime.health.enabled = false | del(.entities.get_account_balance.health)'
expect_rc 2 "health-probe: a missing base is a usage error" "$CI/gate-health-probe.sh" config/does-not-exist.json

# --- Gate DEV-ALL-PROTECTED ---
# Fixture: a clean messaging config (the canonical msg_core_Account hiding two PII columns,
# msg_core_User hiding two secrets), an entity-less base on the same connection, and a list with
# one line of each kind: canonical, pii-columns, secret-columns, an alias view and a table that
# must not be served at all. dapcase copies the fixture, mutates the config with jq, optionally
# runs a setup step in the copy, and expects rc=0 (controls) or rc=1 (each way of re-serving
# protected data with every other gate green).
P=$FIX/dev-all-protected
P_ABS=$(cd "$P" && pwd)
run pass "$CI/gate-dev-all-protected.sh"
expect_rc 0 "dev-all-protected: clean fixture" "$CI/gate-dev-all-protected.sh" "$P/protected-excluded.txt" "$P/clean" "$P/base.json"
dapcase() {  # dapcase <rc> <description> <jq filter on the msg config> [setup run inside the copy]
  local want="$1" desc="$2" filter="$3" setup="${4:-}" d out
  d=$(mktemp -d); mkdir -p "$d/cfg"
  cp "$P/clean/dab-config.dev-all.msg.json" "$d/cfg/"; cp "$P/base.json" "$d/base.json"
  cp "$P/protected-excluded.txt" "$d/list.txt"
  if ! out=$(jq "$filter" "$d/cfg/dab-config.dev-all.msg.json") || [ -z "$out" ]; then
    bad "dev-all-protected: jq mutation failed: $desc"; rm -rf "$d"; return
  fi
  printf '%s\n' "$out" > "$d/cfg/dab-config.dev-all.msg.json"
  if [ -n "$setup" ] && ! (cd "$d" && eval "$setup"); then
    bad "dev-all-protected: setup failed: $desc"; rm -rf "$d"; return
  fi
  expect_rc "$want" "dev-all-protected: $desc" "$CI/gate-dev-all-protected.sh" "$d/list.txt" "$d/cfg" "$d/base.json"
  rm -rf "$d"
}
VIEW='{source: {object: "core.vwAccountContact", type: "view", "key-fields": ["AccountUid"]}, permissions: [{role: "appdb-data-api-msg-reader", actions: ["read"]}]}'
USR='.entities.msg_core_User.permissions[0].actions'
ACC='.entities.msg_core_Account.permissions[0].actions'

# Controls (rc=0).
dapcase 0 "control: untouched copy" '.'
dapcase 0 "control: CRLF list" '.' "sed -i 's/\$/\r/' list.txt"
# shellcheck disable=SC2016  # the setup string runs in the copy, where $(cat ...) must expand
dapcase 0 "control: list without a final newline" '.' 'printf "%s" "$(cat list.txt)" > l && mv l list.txt'
dapcase 0 "control: the same object on ANOTHER database is not this line's" '.' "cp '$P_ABS/other-db.json' cfg/dab-config.dev-all.msgdata.json"
dapcase 0 "control: an include list without the secrets" "$USR"' = [{"action": "read", "fields": {"include": ["UserId", "Email"]}}]'
dapcase 0 "control: an include list in another case without secrets" "$USR"' = [{"action": "read", "fields": {"include": ["userid", "email"]}}]'
dapcase 0 'control: exclude ["*"] serves nothing' "$USR"' = [{"action": "read", "fields": {"exclude": ["*"]}}]'
dapcase 0 "control: a second role that also hides both" \
  '.entities.msg_core_User.permissions += [{role: "other", actions: [{action: "read", fields: {exclude: ["PasswordHash", "ApiSecret"]}}]}]'

# Dropped objects served again, under every spelling DAB resolves to the same object (rc=1).
dapcase 1 "alias view served again" ".entities.msg_core_vwAccountContact = $VIEW"
dapcase 1 "alias as [core].[vwAccountContact]" ".entities.msg_core_vwAccountContact = ($VIEW | .source.object = \"[core].[vwAccountContact]\")"
dapcase 1 "alias in upper case" ".entities.msg_core_vwAccountContact = ($VIEW | .source.object = \"CORE.VWACCOUNTCONTACT\")"
dapcase 1 "alias as a string-form source" ".entities.msg_core_vwAccountContact = ($VIEW | .source = \"core.vwAccountContact\")"
dapcase 1 "protected table without its schema (DAB defaults to dbo)" \
  ".entities.msg_x = ($VIEW | .source.object = \"AccountBilling\" | .source.type = \"table\")"
dapcase 1 "protected table as [dbo].[AccountBilling]" \
  ".entities.msg_x = ($VIEW | .source.object = \"[dbo].[AccountBilling]\" | .source.type = \"table\")"
dapcase 1 "alias in a second config on the same database" '.' "cp '$P_ABS/alias-file.json' cfg/dab-config.dev-all.msg2.json"
dapcase 1 "alias in the base's own entities" '.' "cp '$P_ABS/base-with-alias.json' base.json"

# The canonical table: only its pinned name, and never with the PII columns (rc=1).
dapcase 1 "another entity over core.Account (even one hiding the PII)" \
  '.entities.msg_core_AccountDirectory = .entities.msg_core_Account'
dapcase 1 "canonical entity renamed" '.entities.msg_core_Accounts = .entities.msg_core_Account | del(.entities.msg_core_Account)'
dapcase 1 "canonical Account no longer hides Address" "$ACC"'[0].fields.exclude |= map(select(. != "Address"))'

# Secret columns (rc=1).
dapcase 1 "core.User back to a bare read" "$USR"' = ["read"]'
dapcase 1 "core.User hides only PasswordHash" "$USR"'[0].fields.exclude = ["PasswordHash"]'
dapcase 1 'a later "read" undoes the exclude' "$USR"' += ["read"]'
dapcase 1 'a later "*" undoes the exclude' "$USR"' += ["*"]'
dapcase 1 'a later "all" undoes the exclude' "$USR"' += ["all"]'
dapcase 1 'a later {"action": "Read"} undoes the exclude' "$USR"' += [{"action": "Read"}]'
dapcase 1 "a second permissions entry for the same role wins" \
  '.entities.msg_core_User.permissions += [{role: "appdb-data-api-msg-reader", actions: ["read"]}]'
dapcase 1 "the excludes sit on a create action, read is bare" \
  "$USR"' = [{"action": "create", "fields": {"exclude": ["PasswordHash", "ApiSecret"]}}, "read"]'
dapcase 1 "another role reads with a bare read" '.entities.msg_core_User.permissions += [{role: "authenticated", actions: ["read"]}]'
dapcase 1 "excludes in the wrong case (DAB compares exactly)" "$USR"'[0].fields.exclude = ["passwordhash", "apisecret"]'
dapcase 1 "one comma-joined exclude entry" "$USR"'[0].fields.exclude = ["PasswordHash,ApiSecret"]'
dapcase 1 "an include list that names a secret" "$USR"' = [{"action": "read", "fields": {"include": ["UserId", "PasswordHash"]}}]'
dapcase 1 "an include list naming secrets in another case (DAB matches include ignoring case)" \
  "$USR"' = [{"action": "read", "fields": {"include": ["UserId", "Email", "passwordhash", "apisecret"]}}]'
dapcase 1 'an exclude mixing "*" with names (read literally in production mode)' "$USR"'[0].fields.exclude = ["*", "Email"]'
dapcase 1 "an earlier bare read (GraphQL unions every read action)" "$USR"' = ["read"] + '"$USR"

# The list itself (rc=1).
dapcase 1 "stale list: the config it names was renamed" '.' 'mv cfg/dab-config.dev-all.msg.json cfg/dab-config.dev-all.msg1.json'
dapcase 1 "an unterminated last line is still checked" "$USR"' = ["read"]' \
  'grep -v core.User list.txt > l && grep core.User list.txt | tr -d "\n" >> l && mv l list.txt'
dapcase 1 "a malformed line" '.' "printf 'dab-config.dev-all.msg.json\tcore.User\n' >> list.txt"
dapcase 1 "a config that is not JSON" '.' "printf '{' > cfg/dab-config.dev-all.msg.json"

# Spellings SQL Server still resolves to a listed object, and shapes the line checks cannot see (rc=1).
dapcase 1 "alias with a trailing space" ".entities.msg_core_vwAccountContact = ($VIEW | .source.object = \"core.vwAccountContact \")"
dapcase 1 "alias with a zero-width joiner" ".entities.msg_core_vwAccountContact = ($VIEW | .source.object = \"core.vwAccount\\u200dContact\")"
dapcase 1 "alias with fullwidth letters" ".entities.msg_core_vwAccountContact = ($VIEW | .source.object = \"\\uff43\\uff4f\\uff52\\uff45.vwAccountContact\")"
dapcase 1 "protected table with an empty schema (.X resolves to dbo)" \
  ".entities.msg_x = ($VIEW | .source.object = \".AccountBilling\" | .source.type = \"table\")"
dapcase 1 "protected table with an empty bracketed schema ([].X)" \
  ".entities.msg_x = ($VIEW | .source.object = \"[].AccountBilling\" | .source.type = \"table\")"
dapcase 1 "mappings serve a secret under an allowed name" '.entities.msg_core_User.mappings = {"PasswordHash": "Email"}'
dapcase 1 "entity-level fields alias a secret" '.entities.msg_core_User.fields = [{"name": "PasswordHash", "alias": "Email"}]'
dapcase 1 "@env() as an action" "$USR"' += ["@env('"'"'X_ACT'"'"')"]'
dapcase 1 "autoentities in a config" '.autoentities = {}'
dapcase 1 "autoentities in the base" '.' "jq '.autoentities = {}' base.json > b && mv b base.json"
dapcase 1 "a config loading its own data-source-files" '.["data-source-files"] = ["x.json"]'
# A decoy: the real config is renamed and re-opens core.User, while a HARMLESS config on another
# database sits under the listed name. Every line then resolves to the decoy's database and finds
# nothing wrong, so only the file-name check (expected_file) can catch it.
dapcase 1 "a decoy: the msg file name on another database, the real config renamed" \
  "$USR"' = ["read"]' \
  "mv cfg/dab-config.dev-all.msg.json cfg/dab-config.dev-all.msgx.json && jq '.entities.msgdata_core_User.permissions[0].actions = [{\"action\": \"read\", \"fields\": {\"include\": [\"*\"], \"exclude\": [\"PasswordHash\", \"ApiSecret\"]}}]' '$P_ABS/other-db.json' > cfg/dab-config.dev-all.msg.json"
dapcase 1 "a connection string with trailing text" \
  '.["data-source"]["connection-string"] = "@env('"'"'CONN_DEV_AppDb_MSG_DEV'"'"');Application Name=x'"'"')"'
dapcase 1 "a non-plain entity name" '.entities["msg core User"] = .entities.msg_core_User | del(.entities.msg_core_User)'
expect_rc 1 "dev-all-protected: empty list" "$CI/gate-dev-all-protected.sh" "$P/empty.txt" "$P/clean" "$P/base.json"
expect_rc 1 "dev-all-protected: missing list" "$CI/gate-dev-all-protected.sh" "$P/does-not-exist.txt" "$P/clean" "$P/base.json"
expect_rc 1 "dev-all-protected: missing config dir" "$CI/gate-dev-all-protected.sh" "$P/protected-excluded.txt" "$P/does-not-exist" "$P/base.json"
expect_rc 1 "dev-all-protected: missing base" "$CI/gate-dev-all-protected.sh" "$P/protected-excluded.txt" "$P/clean" "$P/does-not-exist.json"

# The real (example) tree and its list, with a protected object served (rc=1). The list's objects
# are ones the example tree does not serve, so each line holds today; these prove each line bites.
realcase() {  # realcase <rc> <description> <config file in config/dev-all> <jq filter on it>
  local want="$1" desc="$2" file="$3" filter="$4" d out; d=$(mktemp -d); mkdir -p "$d/cfg"; cp config/dev-all/*.json "$d/cfg/"
  if ! out=$(jq "$filter" "config/dev-all/$file") || [ -z "$out" ]; then
    bad "dev-all-protected (real tree): jq mutation failed: $desc"; rm -rf "$d"; return
  fi
  printf '%s\n' "$out" > "$d/cfg/$file"
  expect_rc "$want" "dev-all-protected (real tree): $desc" "$CI/gate-dev-all-protected.sh" \
    config/dev-all/protected-excluded.txt "$d/cfg" dab-config.dev-all.json
  rm -rf "$d"
}
MNO=dab-config.dev-all.mno.json
VMNO=dab-config.dev-all.vo.mno.json
# shellcheck disable=SC2016  # $o $k $r $a are jq variables, bound by each realcase filter
ADD='{source: {object: $o, type: "table", "key-fields": [$k]}, permissions: [{role: $r, actions: $a}]}'
realcase 0 "control: an untouched copy" "$MNO" '.'
realcase 1 "core.User served with a bare read" "$MNO" \
  ".entities.mno_core_User = (\"core.User\" as \$o | \"UserId\" as \$k | \"appdb-data-api-msg-reader\" as \$r | [\"read\"] as \$a | $ADD)"
realcase 1 "core.vwAccountContact served" "$MNO" \
  ".entities.mno_core_vwAccountContact = (\"core.vwAccountContact\" as \$o | \"AccountUid\" as \$k | \"appdb-data-api-msg-reader\" as \$r | [\"read\"] as \$a | $ADD | .source.type = \"view\")"
realcase 1 "core.AccountBilling served" "$MNO" \
  ".entities.mno_core_AccountBilling = (\"core.AccountBilling\" as \$o | \"AccountUid\" as \$k | \"appdb-data-api-msg-reader\" as \$r | [\"read\"] as \$a | $ADD)"
realcase 0 "control: core.Account served under its canonical name" "$MNO" \
  ".entities.mno_core_Account = (\"core.Account\" as \$o | \"AccountUid\" as \$k | \"appdb-data-api-msg-reader\" as \$r | [\"read\"] as \$a | $ADD)"
realcase 1 "core.Account served under another name, on the voice host" "$VMNO" \
  ".entities.voi_core_Account = (\"core.Account\" as \$o | \"AccountUid\" as \$k | \"appdb-data-api-voi-reader\" as \$r | [\"read\"] as \$a | $ADD)"
realcase 1 "voice mno.CarrierSettings served with a bare read" "$VMNO" \
  ".entities.voi_mno_CarrierSettings = (\"mno.CarrierSettings\" as \$o | \"CarrierId\" as \$k | \"appdb-data-api-voi-reader\" as \$r | [\"read\"] as \$a | $ADD)"
realcase 1 "voice mno.CarrierContact hiding ContactName but not Email" "$VMNO" \
  ".entities.voi_mno_CarrierContact = (\"mno.CarrierContact\" as \$o | \"CarrierContactId\" as \$k | \"appdb-data-api-voi-reader\" as \$r | [{action: \"read\", fields: {exclude: [\"ContactName\"]}}] as \$a | $ADD)"
realcase 0 "control: voice mno.CarrierContact hiding both listed columns" "$VMNO" \
  ".entities.voi_mno_CarrierContact = (\"mno.CarrierContact\" as \$o | \"CarrierContactId\" as \$k | \"appdb-data-api-voi-reader\" as \$r | [{action: \"read\", fields: {include: [\"*\"], exclude: [\"ContactName\", \"Email\"]}}] as \$a | $ADD)"

# --- Gate PROTECTION: the config-protection gates as one list (CI, and Gate ARTIFACT on an image) ---
# It runs from its own tree's root, so a copy of the tree is checked, not the caller's directory.
# Each negative breaks exactly one gate in the list.
protcase() {  # protcase <pass|fail> <description> <file> <jq filter on it>
  local want="$1" desc="$2" file="$3" filter="$4" t out
  t=$(mktemp -d); cp -R ci config "$t/"; cp dab-config*.json "$t/"
  if ! out=$(jq "$filter" "$file") || [ -z "$out" ]; then bad "gate-protection: jq mutation failed: $desc"; rm -rf "$t"; return; fi
  printf '%s\n' "$out" > "$t/$file"
  expect "$want" "gate-protection: $desc" "$t/ci/gate-protection.sh"
  rm -rf "$t"
}
protcase pass "control: an untouched copy of the tree" dab-config.json '.'
protcase fail "the curated config gains create-record (DML-TOOLS, NO-WRITE-TOOLS)" dab-config.json \
  '.runtime.mcp["dml-tools"]["create-record"] = true'
protcase fail "a voice entity re-roled to msg-reader (RBAC)" config/dev-all/dab-config.dev-all.vo.mno.json \
  '.entities.voi_lookup_operator.permissions[0].role = "appdb-data-api-msg-reader"'
protcase fail "dev-all serves a protected secret column (DEV-ALL-PROTECTED)" config/dev-all/dab-config.dev-all.mno.json \
  '.entities.mno_core_User = {source: {object: "core.User", type: "table", "key-fields": ["UserId"]}, permissions: [{role: "appdb-data-api-msg-reader", actions: ["read"]}]}'
protcase fail "dev-all serves a table without key-fields (KEY-FIELDS)" config/dev-all/dab-config.dev-all.mno.json \
  '.entities.mno_mno_Operator = {source: {object: "mno.Operator", type: "table"}, permissions: [{role: "appdb-data-api-msg-reader", actions: ["read"]}]}'
protcase fail "autoentities in the dev-all base (DEV-ALL-TREE)" dab-config.dev-all.json '.autoentities = {}'

# --- Gate ARTIFACT (ci/gate-image-configs.sh): the protection gates on a built image's own configs ---
# No image ref at all is a usage error, not a silent pass.
run fail "$CI/gate-image-configs.sh"
# The image-side cases need a built image, so they are opt-in like GATE_IMAGE_UID_IMAGE:
#   GATE_ARTIFACT_IMAGE=<ref> ci/tests/run-gate-tests.sh
# CI's stack-smoke job runs the gate itself on the image it builds.
if [ -n "${GATE_ARTIFACT_IMAGE:-}" ]; then
  run pass "$CI/gate-image-configs.sh" "$GATE_ARTIFACT_IMAGE"
  # An image whose baked dev-all child re-serves a protected secret column must be refused, though
  # this checkout's own configs are clean: the gate judges the image, not the checkout.
  d=$(mktemp -d)
  jq '.entities.mno_core_User = {source: {object: "core.User", type: "table", "key-fields": ["UserId"]}, permissions: [{role: "appdb-data-api-msg-reader", actions: ["read"]}]}' \
    config/dev-all/dab-config.dev-all.mno.json > "$d/bad.json"
  printf 'FROM %s\nCOPY bad.json /App/config/dev-all/dab-config.dev-all.mno.json\n' "$GATE_ARTIFACT_IMAGE" > "$d/Dockerfile"
  # The build context goes in on stdin as a tar, so no host path reaches docker (Git Bash on
  # Windows would hand it an MSYS /tmp path it cannot resolve).
  if tar -C "$d" -cf - . | docker build -q -t gate-artifact-bad:test - >/dev/null 2>&1; then
    run fail "$CI/gate-image-configs.sh" gate-artifact-bad:test
    docker rmi gate-artifact-bad:test >/dev/null 2>&1
  else
    bad "gate-artifact: could not build the bad image"
  fi
  # An image with no configs at all must fail, not pass on nothing to check.
  printf 'FROM %s\nUSER root\nRUN rm -f /App/dab-config*.json\n' "$GATE_ARTIFACT_IMAGE" > "$d/Dockerfile"
  if tar -C "$d" -cf - . | docker build -q -t gate-artifact-empty:test - >/dev/null 2>&1; then
    run fail "$CI/gate-image-configs.sh" gate-artifact-empty:test
    docker rmi gate-artifact-empty:test >/dev/null 2>&1
  else
    bad "gate-artifact: could not build the config-less image"
  fi
  rm -rf "$d"
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

# The base's own entities are served on its data source outside every child config, so a list
# keyed to those configs could miss them.
t=$(treerepo)
jq '.entities = {mno_core_vwAccountContact: {source: {object: "core.vwAccountContact", type: "view", "key-fields": ["AccountUid"]}, permissions: [{role: "appdb-data-api-msg-reader", actions: ["read"]}]}}' \
   "$t/dab-config.dev-all.json" > "$t/x" && mv "$t/x" "$t/dab-config.dev-all.json"
treerun fail "tree: base declares its own entity" "$t"; rm -rf "$t"

# DAB serves autoentities and a child's own data-source-files; no .entities walk sees them.
t=$(treerepo); jq '.autoentities = {}' "$t/dab-config.dev-all.json" > "$t/x" && mv "$t/x" "$t/dab-config.dev-all.json"
treerun fail "tree: autoentities in the base" "$t"; rm -rf "$t"
t=$(treerepo); jq '.autoentities = {}' "$t/config/dev-all/dab-config.dev-all.mno.json" > "$t/x" \
   && mv "$t/x" "$t/config/dev-all/dab-config.dev-all.mno.json"
treerun fail "tree: autoentities in a child" "$t"; rm -rf "$t"
t=$(treerepo); jq '.["data-source-files"] = ["config/dev-all/x.json"]' "$t/config/dev-all/dab-config.dev-all.mno.json" > "$t/x" \
   && mv "$t/x" "$t/config/dev-all/dab-config.dev-all.mno.json"
treerun fail "tree: a child loading its own data-source-files" "$t"; rm -rf "$t"

# A child renamed consistently in the base still matches every other check, but no longer the
# name its key derives, so a protected-excluded.txt line could point at another database.
t=$(treerepo); mv "$t/config/dev-all/dab-config.dev-all.mno.json" "$t/config/dev-all/dab-config.dev-all.mno2.json"
jq '.["data-source-files"] |= map(if . == "config/dev-all/dab-config.dev-all.mno.json" then "config/dev-all/dab-config.dev-all.mno2.json" else . end)' \
   "$t/dab-config.dev-all.json" > "$t/x" && mv "$t/x" "$t/dab-config.dev-all.json"
treerun fail "tree: a child whose file name does not match its key" "$t"; rm -rf "$t"

# DAB's @env() match is lazy: trailing text still resolves the key, with the rest riding along.
t=$(treerepo)
jq '.["data-source"]["connection-string"] = "@env('"'"'CONN_DEV_AppDb_MNO_DEV'"'"');Application Name=x'"'"')"' \
   "$t/config/dev-all/dab-config.dev-all.mno.json" > "$t/x" && mv "$t/x" "$t/config/dev-all/dab-config.dev-all.mno.json"
treerun fail "tree: a connection string with trailing text" "$t"; rm -rf "$t"

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
