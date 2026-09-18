# EC2 deploy (Docker) — appdb-data-api-msg

A fast path: instead of Kubernetes, run the DAB container
on an **EC2 instance next to the existing SQL-MCP EC2** in the messaging **DEV** account (`111111111111`),
so AgentCore has a real URL to call for testing/PoC. Kubernetes (`deploy/chart` + `chart/values/dev.yaml`, `deploy/staging`) or
ECS come later. This tool is **messaging-only** (`appdb-data-api-msg`); voice/other domains get their own tool.

```
AgentCore ──(OIDC bearer JWT, aud=appdb-data-api-msg)──▶ http://<ec2-ip>:5000/mcp
                                                     appdb-data-api-msg (Docker on EC2)
                                                     └─ EXECUTE-only ──▶ AppDb_dev (192.0.2.22:1433)
```

## Files
| File | Purpose |
|---|---|
| `docker-compose.yml` | Builds the image from `../../Dockerfile` (config baked in) and runs it; DEV by default, staging variant in the footer. |
| `.env.ec2-dev.example` | Env template — copy to `.env` on the box and fill `CONN_DEV` + `AUTH_JWT_ISSUER`. Never commit the real one. |
| `appdb-data-api.service` | Optional systemd unit to start the container on boot. |

## Prerequisites
1. **DBA (you):** run [`../02-dev-create-login-and-grants.sql`](../02-dev-create-login-and-grants.sql) on `AppDb_dev` so `svc_dataapi` can EXECUTE the 6 SPs.
2. **EC2 host:** Docker + the Compose plugin installed (`docker --version`, `docker compose version`).
3. **Security groups:**
   - Inbound **TCP 5000** to this EC2 **only from AgentCore's** source SG/CIDR.
   - Outbound **TCP 1433** to the DB (`192.0.2.22`). If the API EC2 sits in the same subnet as the SQL-MCP EC2, this is already open.
4. **OIDC provider registration:** register audience `appdb-data-api-msg` with your OIDC provider, and confirm it
   emits role `appdb-data-api-msg-reader` in the token's `roles` claim (some provider consoles show a shorter alias
   in a group/claim-mapping UI — confirm the exact string; DAB matches it verbatim).

## Deploy (dev)
```bash
# on the EC2, in a checkout of the repo
cd appdb-data-api/deploy/ec2
cp .env.ec2-dev.example .env
vim .env                                  # set the real dev password in CONN_DEV; confirm AUTH_JWT_ISSUER

docker compose -f docker-compose.yml up -d --build
docker compose logs -f --tail=50          # watch it start
```

## Verify
```bash
# 200 only means the process is up — the DB verdict is in the body, never in the status code.
curl -s http://localhost:5000/health | jq '.status, (.checks[] | {name, status, data})'
# from a DEV-environment bearer token issued by your OIDC provider:
TOKEN=<paste DEV bearer token>
curl -H "Authorization: Bearer $TOKEN" -H "X-MS-API-ROLE: appdb-data-api-msg-reader" \
  "http://localhost:5000/api/get_account_balance?AccountUid=<test-account-uid>"
```
Then give DevOps the **tool URL** to register with AgentCore / the OIDC provider: `http://<ec2-private-ip>:5000/mcp`
(or the ingress/ALB hostname once one is fronted).

## Secrets note
For this dev PoC, a root-readable `.env` on the box holding the **dev** (non-prod) password is acceptable
(`chmod 600 .env`). For staging/prod, do **not** keep the password in a file — pull it from **AWS Secrets
Manager** at container start (instance IAM role + a small entrypoint fetch, or migrate to the k8s/ECS
chart in `deploy/chart` and the manifests in `deploy/staging`, which use External Secrets). Issuer/audience are public — keep
them as plain env either way.

## Staging on EC2 (if needed before k8s)
See the footer of `docker-compose.yml`: drop **both** the `entrypoint:` and `command:` lines (staging uses
the baked base `dab-config.json`, which the image ENTRYPOINT loads by default), and in `.env` set
`DAB_ENVIRONMENT=Staging` + `CONN_GLOBAL_CONFIG` + `CONN_ID_MSGDATA`
pointing at `ag-staging-listener`. Staging SMS is **masked** (`_v2` proc); dev is **unmasked** (`_v5`) — test data only.

## Auto-start on boot (optional)
```bash
sudo cp appdb-data-api.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now appdb-data-api
```
