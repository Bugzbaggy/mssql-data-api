---
status: implemented
---

# appdb-data-api — documentation

**Status:** Implemented

Solution-local documentation for the governed read-only app-data API. Repo-wide governance lives in
`../../docs/`; the binding decisions are
ADR-002 (why this API exists) and
ADR-003 (how it is built and
deployed).

The repo ships **two MCP endpoints**: `dab-mcp` (this API — curated stored
procedures, zero table entities, port 5000) and `dba-mcp` (SQL Server
diagnostics via dbatools, port 3000). They're kept separate so each can be
exposed to a different audience without the other's data or blast radius
coming along. `services/dba-mcp/` is a **vendored copy** of a separate
upstream server, pinned by commit sha and policed by `ci/gate-vendor-drift.sh`
— see the design doc below before touching anything under it.

| Doc | What's there |
|---|---|
| [`ci-cd-dev.md`](ci-cd-dev.md) | The DEV EKS pipeline: validation gates, Helm chart, Istio exposure, identity, rollback |
| [`identity-and-audit.md`](identity-and-audit.md) | OIDC bearer JWT → DAB roles, and `SESSION_CONTEXT()` for per-person auditing |
| [`microsoft-sql-mcp-conformance.md`](microsoft-sql-mcp-conformance.md) | Why the RBAC gate is blocking rather than advisory |
| [`superpowers/specs/2026-09-16-dba-mcp-stack-design.md`](superpowers/specs/2026-09-16-dba-mcp-stack-design.md) | Why `dba-mcp` is vendored rather than rewritten, the two-endpoint architecture, and the dbatools migration plan (including which tools stay on DMVs permanently) |

Deployment artifacts and per-environment steps: [`../deploy/README.md`](../deploy/README.md).
The CI gate scripts are runnable locally — see [`../ci/`](../ci/) and `deploy/README.md` §0.
Running the stack locally, including the `dab-mcp` + `dba-mcp` demo and the
fleet overlay: see the root [`README.md`](../README.md).
