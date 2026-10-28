---
status: implemented
---

# appdb-data-api — documentation

**Status:** Implemented

Documentation for the governed read-only app-data API: why it exists and its two-endpoint shape are in
the root [`README.md`](../README.md); how it is built and deployed is below.

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
| [`dev-all-status.md`](dev-all-status.md) | The broad-read `dev-all` config tree: its naming rule, Gate DEV-ALL-TREE, Gate DEV-ALL-PROTECTED, and how to add a database |
| [`db-agent-instructions.md`](db-agent-instructions.md) | Operating and routing instructions for an agent that reads through the broad-read dev MCP |
| [`microsoft-sql-mcp-conformance.md`](microsoft-sql-mcp-conformance.md) | How the curated config maps to Microsoft's SQL MCP Server guidance, row by row |
| [`superpowers/specs/2026-09-16-dba-mcp-stack-design.md`](superpowers/specs/2026-09-16-dba-mcp-stack-design.md) | Why `dba-mcp` is vendored rather than rewritten, the two-endpoint architecture, and the dbatools migration plan. Which tools stay on DMVs permanently, and why, is in [`superpowers/plans/2026-09-17-dba-mcp-waves-2-3.md`](superpowers/plans/2026-09-17-dba-mcp-waves-2-3.md) and the root README's "Migration status" |

Deployment artifacts and per-environment steps: [`../deploy/README.md`](../deploy/README.md).
The CI gate scripts are runnable locally — see [`../ci/`](../ci/), the root README's "CI gates"
section, and `deploy/README.md` step 0.
Running the stack locally, including the `dab-mcp` + `dba-mcp` demo and the
fleet overlay: see the root [`README.md`](../README.md).
