#!/usr/bin/env bash
# Gate SQL-VIEWS + Gate API-ACCESS — the projection views of deploy/ops-expansion/, end to end, in throwaway containers.
#
# SQL-VIEWS: a SQL Server 2022 container gets the prod shape (AppCatalog: the sample operations tables of
# seed/02-ops-sample-schema.sql, the DAB login, synthetic rows) and runs deploy/ops-expansion 01, 02 and 03 twice each,
# then 04 as a dry run and applied twice. Then the dev shape (AppDb_dev, drifted: one table missing, one column
# missing), the guard (the scripts refuse master and a read-only database), and the demo stack's seed sequence. It
# fails on any script error and on any FAIL line:
#   - every dataapi view has exactly the columns ops-columns.json lists, in order, and no view outside it exists;
#   - each view is granted SELECT to the DAB role only, and DAB's startup read (FMTONLY SELECT *) works as the DAB user;
#   - the negative test: the fixtures put CANARY in every credential, personal, content and free-text value and in the
#     login, path, query and fragment of every URL; no CANARY may appear in any view's output, read as the DAB user;
#   - the value cuts (URL hosts, the credential flags, the computed body length);
#   - the function-backed view's call counts (1 for an AccountUid read, one per account without it);
#   - 04 denies the DAB user every object behind the views, the views and the curated stored procedure still run, and a
#     second run changes nothing.
# API-ACCESS (skip with SQL_VIEWS_API=0): DAB, from the Dockerfile's FROM, with Simulator auth, connected as the DAB
# login after 04's DENYs, serving every staged Ops entity; then ci/access-smoke.sh --mode simulator --canary: only
# approved fields come back, blocked columns cannot be selected or filtered on, other roles get 403, and no CANARY
# value crosses the API. DAB refusing to start means an entity does not match its view.
#
# Needs Docker and jq. No credentials: the SQL logins exist only inside the containers, with passwords made per run.
# Files reach the containers as a tar on stdin, so no host path is handed to docker (Git Bash, WSL and Linux alike).
# Usage: ci/sql-views/run.sh   (any working directory)
set -uo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows would rewrite the container paths below
cd "$(dirname "$0")/../.." || exit 2   # -> the repo root
# shellcheck source=ci/lib.sh
. ci/lib.sh
require_jq
command -v docker >/dev/null 2>&1 || { gate_fail "Gate SQL-VIEWS: docker is required"; exit 2; }

# The SQL Server build the demo stack pins (docker-compose.stack.yml), so the two never disagree.
SQL_IMAGE="${SQL_VIEWS_SQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-CU14-ubuntu-22.04}"
# The DAB build the pods run: the Dockerfile's FROM line, the source of truth Gate VERSION checks everything else against.
DAB_IMAGE="${DAB_IMAGE:-$(sed -n 's|^FROM \([^ ]*data-api-builder:[^ ]*\).*|\1|p' Dockerfile | head -1)}"
[ -n "$DAB_IMAGE" ] || { gate_fail "Gate API-ACCESS: no data-api-builder FROM line in Dockerfile"; exit 2; }
API="${SQL_VIEWS_API:-1}"
OPS=deploy/ops-expansion
SPEC="$OPS/ops-columns.json"
tag="sqlviews-$$-${RANDOM}"
net="$tag-net" sqlc="$tag-sql" dabc="$tag-dab"
work="$(mktemp -d)"
cleanup() { docker rm -f "$sqlc" "$dabc" >/dev/null 2>&1; docker network rm "$net" >/dev/null 2>&1; rm -rf "$work"; }
trap cleanup EXIT

rnd() { od -An -tx1 -N12 /dev/urandom | tr -d ' \n'; }
PW="Sv1!$(rnd)"      # sa, this container only
DABPW="Da1!$(rnd)"   # the DAB login, this container only

cp ci/sql-views/*.sql ci/sql-views/fixtures/*.sql seed/0[1-3]-*.sql "$OPS"/0[1-4]-*.sql "$work"/ || exit 2
sed 's/^DECLARE @apply bit = 0;/DECLARE @apply bit = 1;/' "$OPS/04-prod-deny-base-objects.sql" > "$work/04-apply.sql"
grep -q '^DECLARE @apply bit = 1;' "$work/04-apply.sql" || { gate_fail "Gate SQL-VIEWS: could not build the @apply = 1 copy of 04"; exit 2; }
R=ci/sql-views/render.jq
{ jq -r -f "$R" --arg what expected-columns --arg env prod "$SPEC" > "$work/expected-prod.sql" &&
  jq -r -f "$R" --arg what expected-columns --arg env dev "$SPEC" > "$work/expected-dev.sql" &&
  jq -r -f "$R" --arg what contract-lists "$SPEC" > "$work/contract-lists.sql" &&
  jq -f "$R" --arg what dab-config "$OPS/dab-entities.ops.json" > "$work/dab-config.json"; } \
  || { gate_fail "Gate SQL-VIEWS: could not render $SPEC"; exit 2; }

docker network create "$net" >/dev/null || exit 2
docker run -d --name "$sqlc" --network "$net" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD="$PW" "$SQL_IMAGE" >/dev/null \
  || { gate_fail "Gate SQL-VIEWS: could not start $SQL_IMAGE"; exit 2; }
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
ready=0
for _ in $(seq 1 90); do
  docker exec "$sqlc" "$SQLCMD" -C -S localhost -U sa -P "$PW" -Q "SELECT 1" >/dev/null 2>&1 && { ready=1; break; }
  sleep 2
done
[ "$ready" = 1 ] || { gate_fail "Gate SQL-VIEWS: SQL Server did not accept connections"; docker logs "$sqlc" 2>&1 | tail -20 >&2; exit 2; }
docker exec "$sqlc" mkdir -p /tmp/work && tar -C "$work" -cf - . | docker cp - "$sqlc:/tmp/work" || exit 2
Q()  { docker exec "$sqlc" "$SQLCMD" -C -b -I -S localhost -U sa -P "$PW" -W -h -1 "$@"; }   # stops on an error
QN() { docker exec "$sqlc" "$SQLCMD" -C    -I -S localhost -U sa -P "$PW" -W -h -1 "$@"; }   # as SSMS runs a script

fails=0
step() {  # step <name> <want rc> <command...>: prints the OK lines; fails on another rc or on any FAIL line
  local name="$1" want="$2" out rc; shift 2
  out=$("$@" 2>&1); rc=$?
  printf '%s\n' "$out" | grep -E '^ *(OK|FAIL)' | sed "s/^ */  [$name] /"
  if [ "$rc" -ne "$want" ]; then
    gate_fail "Gate SQL-VIEWS: step $name exited $rc (want $want)"; printf '%s\n' "$out" | tail -25 >&2; fails=$((fails + 1))
  elif printf '%s\n' "$out" | grep -qE '^ *FAIL'; then
    gate_fail "Gate SQL-VIEWS: step $name reported a FAIL"; fails=$((fails + 1))
  fi
}
expect_out() {  # expect_out <name> <regex> <command...>: the output must match (the guard's refusal)
  local name="$1" re="$2" out; shift 2
  out=$("$@" 2>&1)
  if printf '%s\n' "$out" | grep -qE "$re"; then echo "  [$name] OK refused: $(printf '%s\n' "$out" | grep -E "$re" | head -1)"
  else gate_fail "Gate SQL-VIEWS: $name did not refuse"; printf '%s\n' "$out" | tail -10 >&2; fails=$((fails + 1)); fi
}
deny_count() { Q -d AppCatalog -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.database_permissions WHERE state = 'D' AND grantee_principal_id = DATABASE_PRINCIPAL_ID(N'svc_dataapi')" | tr -d ' \r'; }

echo "== prod shape (AppCatalog)"
step fixture 0 Q -v DABPW="$DABPW" -i /tmp/work/prod-schema.sql
for s in 01-dataapi-credential-table-views 02-dataapi-routing-views 03-dataapi-generated-views; do
  step "${s:0:2} run 1" 0 Q -d AppCatalog -i "/tmp/work/$s.sql"
  step "${s:0:2} run 2" 0 Q -d AppCatalog -i "/tmp/work/$s.sql"
done
step columns 0 Q -d AppCatalog -i /tmp/work/expected-prod.sql
step views 0 Q -d AppCatalog -v DABUSER=svc_dataapi DABROLE=role_svc_dataapi -i /tmp/work/assert-common.sql
step values 0 Q -i /tmp/work/assert-prod-values.sql
step routing 0 Q -i /tmp/work/assert-routing.sql
step "04 dry run" 0 Q -d AppCatalog -i /tmp/work/04-prod-deny-base-objects.sql
step "04 dry run" 0 Q -d AppCatalog -Q "SET NOCOUNT ON; SELECT CASE WHEN COUNT(*) = 0 THEN 'OK the dry run applied nothing' ELSE 'FAIL the dry run applied DENYs' END FROM sys.database_permissions WHERE state = 'D'"
step "04 run 1" 0 Q -d AppCatalog -i /tmp/work/04-apply.sql
n1=$(deny_count)
step "04 run 2" 0 Q -d AppCatalog -i /tmp/work/04-apply.sql
n2=$(deny_count)
if [ -n "$n1" ] && [ "$n1" = "$n2" ] && [ "$n1" -gt 0 ]; then echo "  [04 rerun] OK a second run changed nothing ($n1 DENYs after each)"
else gate_fail "Gate SQL-VIEWS: DENY count after run 1 = '$n1', after run 2 = '$n2'"; fails=$((fails + 1)); fi
step denies 0 Q -i /tmp/work/assert-prod-deny.sql
step "views after 04" 0 Q -d AppCatalog -v DABUSER=svc_dataapi DABROLE=role_svc_dataapi -i /tmp/work/assert-common.sql

echo "== dev shape (AppDb_dev)"
step fixture 0 Q -i /tmp/work/dev-schema.sql
for s in 01-dataapi-credential-table-views 02-dataapi-routing-views 03-dataapi-generated-views; do
  step "${s:0:2} dev" 0 Q -d AppDb_dev -i "/tmp/work/$s.sql"
done
step columns 0 Q -d AppDb_dev -i /tmp/work/expected-dev.sql
step views 0 Q -d AppDb_dev -v DABUSER=dev_svc_dataapi DABROLE=role_dev_svc_dataapi -i /tmp/work/assert-common.sql
expect_out "04 in dev" 'Stopped: run this in AppCatalog' QN -d AppDb_dev -i /tmp/work/04-apply.sql
step dev 0 Q -i /tmp/work/assert-dev.sql

echo "== guard"
expect_out "03 in master" 'Stopped: run this in AppCatalog' QN -d master -i /tmp/work/03-dataapi-generated-views.sql
step "03 in master" 0 Q -d master -Q "SET NOCOUNT ON; SELECT CASE WHEN SCHEMA_ID('dataapi') IS NULL THEN 'OK master untouched' ELSE 'FAIL master has a dataapi schema' END"
Q -Q "ALTER DATABASE AppDb_dev SET READ_ONLY WITH ROLLBACK IMMEDIATE" >/dev/null
expect_out "01 read-only" 'Stopped: run this in AppCatalog' QN -d AppDb_dev -i /tmp/work/01-dataapi-credential-table-views.sql
Q -Q "ALTER DATABASE AppDb_dev SET READ_WRITE WITH ROLLBACK IMMEDIATE" >/dev/null

echo "== demo stack seed (seed/01, then 02 and 03 in AppDb_Demo, twice)"
step "seed 01" 0 Q -i /tmp/work/01-demo-schema.sql
step "seed 02+03" 0 Q -d AppDb_Demo -i /tmp/work/02-ops-sample-schema.sql,/tmp/work/03-ops-sample-rows.sql
step "seed 02+03 again" 0 Q -d AppDb_Demo -i /tmp/work/02-ops-sample-schema.sql,/tmp/work/03-ops-sample-rows.sql
step "seed rows" 0 Q -d AppDb_Demo -Q "SET NOCOUNT ON; SELECT CASE WHEN (SELECT COUNT(*) FROM core.AppUser) = 2 AND (SELECT COUNT(*) FROM svc.Webhook) = 2 AND (SELECT COUNT(*) FROM ref.fnAccountRoute('11111111-1111-1111-1111-111111111111')) = 2 THEN 'OK the demo seed runs twice and leaves its rows once' ELSE 'FAIL the demo seed rows' END"

if [ "$API" = 1 ]; then
  echo "== API (DAB $DAB_IMAGE, Simulator auth, connected as svc_dataapi after 04, every Ops entity)"
  docker create --name "$dabc" --network "$net" -p 127.0.0.1::5000 \
    -e CONN_CI="Server=$sqlc,1433;Database=AppCatalog;User ID=svc_dataapi;Password=$DABPW;TrustServerCertificate=true" \
    "$DAB_IMAGE" >/dev/null || { gate_fail "Gate API-ACCESS: could not create the DAB container"; exit 2; }
  tar -C "$work" -cf - dab-config.json | docker cp - "$dabc:/App/" && docker start "$dabc" >/dev/null || exit 2
  port=$(docker port "$dabc" 5000/tcp | head -1 | sed 's/.*://' | tr -d '\r')
  up=0
  for _ in $(seq 1 60); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/health" 2>/dev/null)" = 200 ]; then up=1; break; fi
    [ "$(docker inspect -f '{{.State.Running}}' "$dabc" | tr -d '\r')" = true ] || break
    sleep 2
  done
  if [ "$up" != 1 ]; then
    gate_fail "Gate API-ACCESS: DAB did not start on the staged entities (an entity that does not match its view stops it)"
    docker logs "$dabc" 2>&1 | tail -30 >&2
    fails=$((fails + 1))
  else
    echo "  [dab] OK DAB started as svc_dataapi with $(jq '.entities | length' "$OPS/dab-entities.ops.json" | tr -d '\r') Ops entities on the views, after 04's DENYs"
    env -u MSYS_NO_PATHCONV ci/access-smoke.sh --base "http://127.0.0.1:$port" --mode simulator --env prod --canary || fails=$((fails + 1))
  fi
fi

if [ "$fails" -gt 0 ]; then
  gate_fail "Gate SQL-VIEWS FAIL: $fails step(s) failed"
  exit 1
fi
gate_ok "Gate SQL-VIEWS: the Ops views match ops-columns.json in prod and dev shapes, leak no CANARY value, and 04 denies every object behind them$([ "$API" = 1 ] && echo "; Gate API-ACCESS passed")"
exit 0
