#!/usr/bin/env bash
# Gate RBAC — every entity's permissions[].role set must EQUAL the role expected for its config,
# not merely "contain nothing unexpected", which passes vacuously on a config with zero entities.
#
# Usage: ci/gate-rbac.sh <config.json> [config.json ...]
set -uo pipefail
# shellcheck source=ci/lib.sh
. "$(dirname "$0")/lib.sh"

# The role is pinned PER CONFIG FILE by filename: voice configs (config/dev-all/*.vo.*.json) are
# appdb-data-api-voi-reader, everything else appdb-data-api-msg-reader. One deployment carries both
# — that RBAC split IS the access boundary (ADR-0005) — so the check is per file, never per pod.
expected_role_for() {
  case "$1" in
    *dab-config.dev-all.vo.*.json) echo "appdb-data-api-voi-reader" ;;
    *)                             echo "appdb-data-api-msg-reader" ;;
  esac
}

# A base's MERGED permissions span its children, so the CLI cross-check below must allow the union
# of their expected roles — not the base's own single value.
expected_roles_merged() {   # expected_roles_merged <config.json> -> sorted unique role list
  local f
  while IFS= read -r f; do expected_role_for "$f"; done < <(configs_for_base "$1") | sort -u
}
require_jq
require_files "$@"

rc=0
for f in "$@"; do
  # The dev-all BASE declares no entities of its own (they live in its data-source-files), so this
  # walk enforces nothing on it — ci/gate-dev-all-tree.sh covers the base invariant.
  n=$(jq -r '(.entities // {}) | length' "$f") || { gate_fail "Gate RBAC: $f is not valid JSON"; rc=1; continue; }
  if [ "$n" -eq 0 ]; then
    gate_ok "Gate RBAC: $f (no entities — skipped; see gate-dev-all-tree.sh for the base invariant)"
    continue
  fi

  # (.permissions // []) so an entity missing the array is reported by the check below
  # instead of aborting this one with a raw jq error.
  want=$(expected_role_for "$f")
  nroles=$(jq -r '[ .entities[] | (.permissions // [])[].role ] | unique | length' "$f")
  roles=$(jq -r '[ .entities[] | (.permissions // [])[].role ] | unique | join(",")' "$f")
  if [ "$roles" = "$want" ]; then
    gate_ok "Gate RBAC: $f ($n entities, role=$roles)"
  elif [ "$nroles" -ne 1 ]; then
    gate_fail "Gate RBAC FAIL: $f — must use exactly ONE role ($want), got [$roles]"
    rc=1
  else
    gate_fail "Gate RBAC FAIL: $f — expected role [$want] for this config, got [$roles]"
    rc=1
  fi

  missing=$(jq -r '[ .entities | to_entries[] | select((.value.permissions // []) | length == 0) | .key ] | join(",")' "$f")
  if [ -n "$missing" ]; then
    gate_fail "Gate RBAC FAIL: $f — entities with no permissions[]: $missing"
    rc=1
  fi
done

# CLI cross-check: catches role INHERITANCE widening access, and sees the MERGED config
# (base + every data-source-file) — neither of which the jq walk above can do.
# Needs Docker but no database. GATE_RBAC_CLI=off skips it; the jq assertion is the real gate.
# The dummy connection string must be well-formed (a bare placeholder makes the base config
# fail to read) but points at TEST-NET-1, so no connection is ever attempted. It is supplied for
# EVERY key the config declares, derived from the config itself.
GATE_RBAC_CLI="${GATE_RBAC_CLI:-auto}"
DAB_IMAGE="${DAB_IMAGE:-mcr.microsoft.com/azure-databases/data-api-builder:2.0.9}"
DUMMY_CONN='Server=192.0.2.1,1433;Database=d;User ID=u;Password=p;Encrypt=True;TrustServerCertificate=False'
if [ "$GATE_RBAC_CLI" != "off" ] && docker info >/dev/null 2>&1; then
  for f in "$@"; do
    case "$f" in */fixtures/*) continue ;; esac
    # Fall back to the legacy trio if derivation fails (e.g. an overlay with no data-source):
    # the run then goes "inconclusive" as before rather than erroring out here.
    conn_env=()
    if keys=$("$(dirname "$0")/gate-conn-keys.sh" "$f" 2>/dev/null) && [ -n "$keys" ]; then
      while IFS= read -r k; do conn_env+=( -e "$k=$DUMMY_CONN" ); done <<<"$keys"
    else
      conn_env=( -e "CONN_DEV=$DUMMY_CONN" -e "CONN_GLOBAL_CONFIG=$DUMMY_CONN" -e "CONN_ID_MSGDATA=$DUMMY_CONN" )
    fi
    if ! out=$(docker run --rm --entrypoint dotnet -v "$PWD:/work:ro" -w /work \
                 "${conn_env[@]}" \
                 -e AUTH_JWT_ISSUER='https://placeholder.invalid' -e AUTH_JWT_AUDIENCE='placeholder' \
                 -e OTEL_EXPORTER_OTLP_ENDPOINT='http://localhost:4317' -e OTEL_EXPORTER_OTLP_HEADERS='' \
                 "$DAB_IMAGE" /App/Microsoft.DataApiBuilder.dll \
                 configure --show-effective-permissions -c "$f" 2>&1); then
      # Not fatal (Gate VALIDATE catches an unloadable config) but say so — a silent skip
      # is indistinguishable from a pass.
      gate_ok "Gate RBAC: $f (cross-check inconclusive — CLI exited non-zero; see Gate VALIDATE)"
      continue
    fi
    # No Role lines means the parser is out of step with the CLI output; fail, don't pass.
    if ! printf '%s' "$out" | grep -q '^info:[[:space:]]*Role:'; then
      gate_fail "Gate RBAC FAIL: $f — effective-permissions output had no 'Role:' lines; parser may be stale"
      rc=1
      continue
    fi
    # info:   Role: <role> | Actions: <actions>
    mapfile -t want < <(expected_roles_merged "$f")
    bad=$(printf '%s' "$out" | sed -n 's/^info:[[:space:]]*Role:[[:space:]]*\([^|]*\)|.*/\1/p' \
            | sed 's/[[:space:]]*$//' | sort -u \
            | grep -vxF -f <(printf '%s\n' "${want[@]}") || true)
    if [ -n "$bad" ]; then
      gate_fail "Gate RBAC FAIL: $f — merged effective permissions include role(s) outside [${want[*]}]: $(printf '%s' "$bad" | tr '\n' ' ')"
      rc=1
    else
      gate_ok "Gate RBAC: $f (effective-permissions cross-check, roles ${want[*]})"
    fi
  done
else
  gate_ok "Gate RBAC: CLI cross-check skipped (GATE_RBAC_CLI=off or no Docker) — jq assertion still enforced"
fi

exit "$rc"
