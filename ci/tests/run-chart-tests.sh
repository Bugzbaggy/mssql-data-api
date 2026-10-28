#!/usr/bin/env bash
# Chart tests: lint, closed-defaults (a missing required value must FAIL the render),
# and rendered-output assertions. See docs/ci-cd-dev.md §6a.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1   # -> appdb-data-api/

. ci/tests/harness.sh

CHART=deploy/chart
DEV=deploy/chart/values/dev.yaml

check() {  # check <description> <expected:pass|fail> <command...>
  local desc="$1" want="$2"; shift 2
  expect "$want" "$desc" "$@"
}

assert_render() {  # assert_render <description> <grep-pattern>
  if printf '%s' "$RENDERED" | grep -Eq -e "$2"; then ok "$1"
  else bad "$1 (pattern: $2)"; fi
}

assert_absent() {  # assert_absent <description> <grep-pattern>
  if printf '%s' "$RENDERED" | grep -Eq -e "$2"; then bad "$1 (should not contain: $2)"
  else ok "$1"; fi
}

# The lines nested under <key>: — everything more indented than the key itself. Needed because a
# whole-render grep cannot tell which probe a match belongs to: one probe carrying timeoutSeconds
# would satisfy the assertion for both.
block() {  # block <yaml-key>
  printf '%s' "$RENDERED" | awk -v k="$1:" '
    $1 == k        { ind = match($0, /[^ ]/); inblk = 1; next }
    inblk          { if (match($0, /[^ ]/) <= ind) inblk = 0; else print }
  '
}

assert_in_block() {  # assert_in_block <description> <yaml-key> <grep-pattern>
  if block "$2" | grep -Eq -e "$3"; then ok "$1"
  else bad "$1 (pattern: $3 not found under $2:)"; fi
}

check "helm lint (dev values)" pass helm lint "$CHART" --values "$DEV" --set image.tag=abc1234

# Closed defaults: each of these MUST fail to render.
check "missing image.tag fails"              fail helm template t "$CHART" --values "$DEV"
check "missing auth.jwtIssuer fails"         fail helm template t "$CHART" --values "$DEV" --set image.tag=abc1234 --set auth.jwtIssuer=""
check "bare defaults fail (no host, no tag)" fail helm template t "$CHART"
# A store that cannot authenticate reports Ready-ish then silently never syncs — worse than a render error.
check "secretStore without roleArn fails"    fail helm template t "$CHART" --values "$DEV" --set image.tag=abc1234 --set serviceAccount.roleArn=""
# An empty runAsUser renders `runAsNonRoot: true` with no uid — the exact combination the kubelet
# rejects at container-create, long after every dry-run has gone green.
check "blank runAsUser fails"                fail helm template t "$CHART" --values "$DEV" --set image.tag=abc1234 --set podSecurityContext.runAsUser=""
# istio.requireJwt is on by default; without the JWKS URL the mesh cannot validate tokens, so the
# render must fail rather than deploy an endpoint that accepts anonymous /mcp.
check "requireJwt without jwksUri fails"      fail helm template t "$CHART" --values "$DEV" --set image.tag=abc1234 --set auth.jwksUri=""

RENDERED="$(helm template appdb-data-api "$CHART" --namespace appdb-data-api \
  --values "$DEV" --set image.tag=abc1234 2>/dev/null)"

# --- workload ---
assert_render "image is pinned to the short SHA"     'image: +"?appdbsg/appdb-data-api:abc1234"?'
assert_absent "no :latest anywhere"                  ':latest'
assert_render "regcred pull secret present"          'name: +regcred'
# The gates read dab-config.dev-all.json by name, so dev must serve exactly that file, with no
# DAB_ENVIRONMENT overlay merged onto it (an overlay would change what the pod serves unseen).
assert_render "dev-all config via CLI command"       'command: \["dotnet", "/App/Microsoft\.DataApiBuilder\.dll", "start", "-c", "/App/dab-config\.dev-all\.json"\]'
assert_absent "dev: no DAB_ENVIRONMENT overlay"      'name: +"?DAB_ENVIRONMENT"?'
assert_render "uses command+CLI, not args"           'command:.*Microsoft\.DataApiBuilder\.dll.*start'
# The flag itself is named in a template comment (explaining why we do NOT use it), so
# match only its use in a command/args list.
assert_absent "never the ignored --config-file flag"  "(command|args):.*--config-file"
assert_render "startupProbe gates liveness"          'startupProbe:'
# The kubelet default is 1s and /health is slower than that whenever DAB's cache has expired.
# Asserted per probe, not across the render: either probe left at the default reinstates the flap.
# >= 2 accepts two-digit values, so raising the timeout does not fail the test.
assert_in_block "startupProbe overrides the 1s timeout"   startupProbe   'timeoutSeconds: +([2-9]|[1-9][0-9]+)'
assert_in_block "readinessProbe overrides the 1s timeout" readinessProbe 'timeoutSeconds: +([2-9]|[1-9][0-9]+)'
assert_render "envFrom the ESO-managed secret"       'name: +appdb-data-api-conn'
assert_render "JWT audience is the registered OIDC audience"   'value: +"?appdb-data-api"?$'
assert_render "readOnlyRootFilesystem"               'readOnlyRootFilesystem: +true'
assert_render "runAsNonRoot"                         'runAsNonRoot: +true'
assert_render "runAsUser pins a non-root uid"        'runAsUser: +1654'
assert_render "runAsGroup pins the same gid"         'runAsGroup: +1654'
assert_render "fsGroup makes the emptyDir writable"  'fsGroup: +1654'
assert_render "writable /tmp under read-only rootfs" 'mountPath: +/tmp'
assert_render "no SA token mounted in the pod"       'automountServiceAccountToken: +false'
assert_render "service targets 5000"                 'targetPort: +5000'

# --- SecretStore (namespaced, chart-owned) ---
assert_render "namespaced SecretStore rendered"      '^kind: +SecretStore'
assert_render "store authenticates as our own SA"    'serviceAccountRef:'
assert_render "IRSA role annotated on the SA"        'eks\.amazonaws\.com/role-arn: +"?arn:aws:iam::123456789012:role/dev-eks-appdb-data-api-eso"?'
assert_render "store region"                         'region: +ap-southeast-1'

# --- ExternalSecret ---
assert_render "ExternalSecret rendered"              '^kind: +ExternalSecret'
assert_render "ESO apiVersion pinned to v1"          '^apiVersion: +external-secrets\.io/v1$'
assert_render "ExternalSecret uses the namespaced store" ' +kind: +SecretStore'
assert_render "dev extracts the JSON conn secret"    'extract:'
assert_render "remote ref points at the dev secret"  'key: +appdb-data-api/dev/connstrings'

# --- Istio ---
assert_render "VirtualService rendered"              '^kind: +VirtualService'
assert_render "Istio apiVersion pinned to v1"        '^apiVersion: +networking\.istio\.io/v1$'
assert_render "bound to the shared private gateway"  '- +istio-system/private-gateway'
assert_render "dev host"                             'appdb-data-api-msg\.appdb\.dev'
assert_render "/mcp route present"                   'prefix: +/mcp'
# `0s` is invalid on Istio 1.29 — assert a long finite timeout, and that it is NOT the default.
assert_render "/mcp route has a long timeout"        'timeout: +"?1h"?'
assert_render "DestinationRule with mTLS"            'mode: +ISTIO_MUTUAL'

# --- Istio JWT enforcement (mesh) — no-token /mcp is rejected; only /health is open ---
assert_render "RequestAuthentication rendered"        '^kind: +RequestAuthentication'
assert_render "AuthorizationPolicy rendered"          '^kind: +AuthorizationPolicy'
assert_render "validates against the OIDC provider's JWKS"       'jwksUri:'
assert_render "/health is exempt from auth"           'paths: +\["/health"\]'
assert_render "everything else needs a JWT principal" 'requestPrincipals:'
# Dev keeps REST and GraphQL for testing: a validated caller is not path-restricted there.
assert_absent "dev: JWT callers are not path-restricted" 'paths: +\["/mcp"'

# istio.allowedPaths narrows what a validated caller may reach. An MCP-only deployment pins it to
# ["/mcp"]: REST /api and GraphQL /graphql would bypass whatever per-call bounds the MCP client
# enforces. /health stays open for the probes and the smoke.
# HA: the render shape of a production deployment — two replicas, MCP-only mesh, session affinity.
ha_with() {  # ha_with <extra helm args...> -> the HA render with those overrides
  helm template appdb-data-api "$CHART" --namespace appdb-data-api \
    --values "$DEV" --set image.tag=abc1234 \
    --set replicaCount=2 --set-json 'istio.allowedPaths=["/mcp"]' \
    --set-string istio.destinationRule.consistentHashHeader=authorization "$@" 2>/dev/null
}
HA_RENDER="$(ha_with)"
if printf '%s' "$HA_RENDER" | grep -Eq '^kind: +AuthorizationPolicy'; then ok "ha: AuthorizationPolicy rendered"
else bad "ha: AuthorizationPolicy rendered"; fi
# The rules exactly: a grep for the paths would still pass if they moved onto a rule of their own
# (anonymous callers to /mcp, JWT callers to every path).
rules_of() {  # rules_of <render> -> the AuthorizationPolicy's rules, comments dropped
  printf '%s' "$1" | awk '/^kind: +AuthorizationPolicy/{f=1} f && /^---/{exit} f' \
    | awk '/^  rules:/{r=1; next} r' | grep -v '^ *#'
}
want_dev='    - to:
        - operation:
            paths: ["/health"]
    - from:
        - source:
            requestPrincipals: ["*"]'
want_mcp="$want_dev"'
      to:
        - operation:
            paths: ["/mcp"]'
if [ "$(rules_of "$RENDERED")" = "$want_dev" ]; then ok "dev: policy rules are exactly /health open + any path for a JWT caller"
else bad "dev: policy rules differ from /health open + any path for a JWT caller"; fi
if [ "$(rules_of "$HA_RENDER")" = "$want_mcp" ]; then ok "ha: policy rules are exactly /health open + JWT callers to /mcp only"
else bad "ha: policy rules differ from /health open + JWT callers to /mcp only"; fi

# --- MCP session affinity ---
# DAB 2.0.9 keeps each MCP session in the memory of the pod that created it and answers any other
# pod's copy of that session id with 404 -32001 "Session not found". So a render that runs more
# than one replica must pin every request of a session (initialize, notifications/initialized,
# tools/call) to one pod: a DestinationRule consistentHash on a header that is the same across all
# three. mcp-session-id does not qualify: initialize has none yet.
obj_of() {  # obj_of <render> <kind> -> that object's lines, from its kind: line to the next ---
  printf '%s' "$1" | awk -v k="$2" '$1 == "kind:" && $2 == k {f=1} f && /^---/{exit} f'
}
affinity_ok() {  # affinity_ok <render> -> success unless >1 replica runs without usable affinity
  local replicas header
  replicas="$(obj_of "$1" Deployment | awk '$1 == "replicas:" {print $2; exit}')"
  [ -n "$replicas" ] || return 1     # no Deployment rendered: nothing proven, so not ok
  [ "$replicas" -le 1 ] && return 0
  header="$(obj_of "$1" DestinationRule \
    | awk '$1 == "httpHeaderName:" {gsub(/"/, "", $2); print tolower($2); exit}')"
  [ -n "$header" ] && [ "$header" != "mcp-session-id" ]
}
if affinity_ok "$HA_RENDER"; then ok "ha: two replicas with MCP session affinity"
else bad "ha: runs more than one replica WITHOUT MCP session affinity (404 Session not found)"; fi
if obj_of "$HA_RENDER" DestinationRule | grep -Eq '^ +httpHeaderName: +"authorization"$'
then ok "ha: DestinationRule hashes sessions on the authorization header"
else bad "ha: DestinationRule hashes sessions on the authorization header"; fi
if obj_of "$HA_RENDER" DestinationRule | grep -Eq 'mode: +ISTIO_MUTUAL'
then ok "ha: DestinationRule keeps mTLS beside the affinity"
else bad "ha: DestinationRule keeps mTLS beside the affinity"; fi
if affinity_ok "$RENDERED"; then ok "dev: affinity invariant holds (one replica)"
else bad "dev: affinity invariant holds (one replica)"; fi
if obj_of "$RENDERED" DestinationRule | grep -Eq 'loadBalancer:'; then bad "dev: DestinationRule keeps the default load balancing"
else ok "dev: DestinationRule keeps the default load balancing"; fi
# The invariant must bite: each way of losing affinity at two replicas fails it, and one replica
# with no affinity passes it.
if affinity_ok "$(ha_with --set-string istio.destinationRule.consistentHashHeader=)"; then
  bad "invariant misses 2 replicas with no affinity header"
else ok "invariant catches 2 replicas with no affinity header"; fi
if affinity_ok "$(ha_with --set istio.destinationRule.enabled=false)"; then
  bad "invariant misses 2 replicas with no DestinationRule"
else ok "invariant catches 2 replicas with no DestinationRule"; fi
if affinity_ok "$(ha_with --set-string istio.destinationRule.consistentHashHeader=mcp-session-id)"; then
  bad "invariant misses 2 replicas hashed on mcp-session-id"
else ok "invariant catches 2 replicas hashed on mcp-session-id"; fi
if affinity_ok "$(ha_with --set replicaCount=1 --set-string istio.destinationRule.consistentHashHeader=)"; then
  ok "invariant allows one replica without affinity"
else bad "invariant allows one replica without affinity"; fi

# Istio must be OFF by default (closed values.yaml) — dev turns it on explicitly.
BARE="$(helm template t "$CHART" --set image.tag=abc1234 \
  --set auth.jwtIssuer=https://x --set auth.jwtAudience=y \
  --set serviceAccount.roleArn=arn:aws:iam::1:role/x \
  --set externalSecret.data[0].secretKey=K --set externalSecret.data[0].remoteKey=k 2>/dev/null)"
if printf '%s' "$BARE" | grep -Eq '^kind: +VirtualService'; then
  bad "Istio should be OFF with bare defaults"
else ok "Istio is OFF with bare defaults"; fi

# externalSecret.enabled with neither data[] nor dataFrom[] must fail loudly, not render an empty secret.
check "empty externalSecret (no data/dataFrom) fails" fail helm template t "$CHART" --set image.tag=abc1234 \
  --set auth.jwtIssuer=https://x --set auth.jwtAudience=y --set serviceAccount.roleArn=arn:aws:iam::1:role/x

# Anchored to column 0 so these match a rendered OBJECT, not a `kind:` nested in another spec.
assert_absent "chart never creates a Gateway"        '^kind: +Gateway'
assert_absent "never a ClusterSecretStore"           '^kind: +ClusterSecretStore'
assert_absent "no plaintext connection string"       '(Password=|User ID=)'

# --- one release, both hosts (ADR-0005) ---
# The voi release is gone; nothing may still name it, or a stale VirtualService/ExternalSecret
# would be rendered against infrastructure that no longer exists.
assert_absent "no voi release identity"              'appdb-data-api-voi'
assert_absent "no voi SM secret"                     'connstrings-voi'
assert_absent "no voi base config"                   'dab-config\.dev-all\.voi\.json'
assert_absent "no voice-account ESO role"            '444444444444'
assert_absent "not the voice spoon gateway"          'istio-system/public-gateway'
# The mesh authpolicy must pin the merged audience, not either half's old one.
assert_render "authpolicy pins the merged audience"  '- +"?appdb-data-api"?$'

summary chart
