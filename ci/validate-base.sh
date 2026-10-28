#!/usr/bin/env bash
# Live-validate ONE config against ONE Secrets Manager secret: derive the config's CONN_* keys,
# pull each from the secret BY NAME, and run `dab validate` in the DAB image.
#
# Usage: ci/validate-base.sh <secret-id> <config.json> [--alias KEY=SECRET_PROPERTY]...
#   ci/validate-base.sh appdb-data-api/dev/connstrings dab-config.dev-all.json
#   ci/validate-base.sh appdb-data-api/dev/connstrings config/dab-config.dev.json \
#     --alias CONN_DEV=CONN_DEV_AppDb_MSG_DEV
#
# --alias exists for the curated dev config, whose data-source is @env('CONN_DEV') while the secret
# stores the same string under its per-DB name. Left tunable rather than special-cased by filename.
#
# Env: DAB_IMAGE (required). AWS credentials must already be configured for the secret's account.
#
# No connection string ever reaches a command line, a process list, or the log: values are masked,
# exported, and passed to docker by NAME (`-e KEY`).
set -euo pipefail
# shellcheck source=ci/lib.sh
. "$(dirname "$0")/lib.sh"

require_jq
: "${DAB_IMAGE:?DAB_IMAGE is not set}"

if [ "$#" -lt 2 ]; then
  gate_fail "usage: validate-base.sh <secret-id> <config.json> [--alias KEY=SECRET_PROPERTY]..."
  exit 2
fi

secret_id="$1"; shift
config="$1"; shift
require_files "$config"

# `dab validate` accepts a config that serves nothing: entities:{} with an empty data-source-files
# is structurally valid, so a base whose children were dropped would validate green while the
# deployment served zero entities. Refuse to report a vacuous pass.
# (Which children a base SHOULD list is ci/gate-dev-all-tree.sh's job; this only rejects "none".)
n_ent=$(jq -r '(.entities // {}) | length' "$config" 2>/dev/null) || {
  gate_fail "$config is not valid JSON"; exit 1; }
n_src=$(jq -r '(.["data-source-files"] // []) | length' "$config" 2>/dev/null) || n_src=0
if [ "$n_ent" -eq 0 ] && [ "$n_src" -eq 0 ]; then
  gate_fail "$config declares no entities and no data-source-files — validating it proves nothing"
  exit 1
fi

# alias_of[KEY]=SECRET_PROPERTY
declare -A alias_of=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --alias)
      [ "$#" -ge 2 ] || { gate_fail "--alias needs KEY=SECRET_PROPERTY"; exit 2; }
      case "$2" in
        *=*) alias_of["${2%%=*}"]="${2#*=}" ;;
        *)   gate_fail "--alias expects KEY=SECRET_PROPERTY, got: $2"; exit 2 ;;
      esac
      shift 2 ;;
    *) gate_fail "unknown argument: $1"; exit 2 ;;
  esac
done

# jq -c: ::add-mask:: is line-oriented, so a pretty-printed secret would only have its first line
# masked. Compacting also fails fast if the secret is not JSON.
secret_json="$(aws secretsmanager get-secret-value \
  --secret-id "$secret_id" --query SecretString --output text | jq -c .)"
# aws-cli does not mask; mask the whole blob before any later jq error can dump a value.
echo "::add-mask::$secret_json"

# Keys come from the config, not a hardcoded list: when the generator adds a DB this fails naming
# the missing key instead of dying inside DAB's config parser. Command substitution keeps the
# derivation's exit status visible to `set -e`.
keys_raw="$(ci/gate-conn-keys.sh "$config")"
if [ -z "$keys_raw" ]; then
  gate_fail "derived 0 connection-string keys from $config"
  exit 1
fi
mapfile -t keys <<<"$keys_raw"

env_args=()
for k in "${keys[@]}"; do
  prop="${alias_of[$k]:-$k}"
  if ! v="$(jq -er --arg k "$prop" '.[$k]' <<<"$secret_json")"; then
    gate_fail "secret $secret_id has no property $prop (required by $config as $k)"
    exit 1
  fi
  echo "::add-mask::$v"
  export "$k=$v"
  env_args+=( -e "$k" )
done
echo "validating $config with ${#keys[@]} connection string(s) from $secret_id"

# --network host for the route to the dev SQL node. Data-source-files are relative to the base
# config, so plain -w /work resolves them; only the image needs the /App root.
docker run --rm --network host --entrypoint dotnet \
  -v "$PWD:/work:ro" -w /work "${env_args[@]}" \
  "$DAB_IMAGE" /App/Microsoft.DataApiBuilder.dll validate -c "$config"

gate_ok "Gate VALIDATE: $config"
