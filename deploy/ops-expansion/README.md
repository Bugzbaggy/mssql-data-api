# Ops entities: tables served through projection views

The curated API serves stored procedures. Sometimes a team needs rows from a table instead, and that table holds
columns nobody should read through an API: a password hash, an API key, a webhook URL with a token in its query
string, an e-mail address, the text of a message. This folder is the pattern for serving such tables **without**
those columns, with the gates that keep it that way. It is built on the sample tables in
[`seed/02-ops-sample-schema.sql`](../../seed/02-ops-sample-schema.sql); the step-by-step guide for adding your own
table is [`docs/adding-tables-safely.md`](../../docs/adding-tables-safely.md).

**Status:** staged. No config in this repository loads these entities; the container test
(`ci/sql-views/run.sh`) proves them end to end on every change.

## The rule

An entity serves no **credential**, no **personal data** and no **message content**. Text that a customer or a
member of staff typed counts as content, because it can hold anything. Commercial columns (prices, costs) are held
back as well. And the cut applies to values, not only to columns: a URL can carry a credential in its login, path or
query, so it is served as `scheme://host[:port]` or not at all.

Four layers enforce it, and each one fails closed:

1. **A projection view per table** (`dataapi.vw_<Table>`) lists only the approved columns. DAB serves the view, never
   the base table.
2. **The DAB entity** reads the view with `fields.include` set to exactly the served list, one `read` action, one JWT
   role (`appdb-data-api-ops-reader`), GET only.
3. **A DENY on the base objects** for the DAB login's user, in prod: a config that regresses to a base table fails at
   startup (Msg 229) instead of serving its columns.
4. **The gateway in front of `/mcp`** enforces the per-entity filters (`ops-gateway-policy.json`), because DAB applies
   none of its own.

### Why views, not DAB's field rules alone

At startup DAB 2.0.9 reads every table and view entity with `SET FMTONLY ON; SELECT * FROM <object>`. SQL Server
checks column permissions even under `FMTONLY`, so a column-level `DENY` (or a `GRANT` on only some columns) on a
served table raises Msg 230 and stops the whole engine, not just that entity. A view that lists only the approved
columns avoids that: its owner (`dbo`) reads the table through ownership chaining, so the DAB login needs no grant on
the table at all, and a column added to the base table later stays out of the API.

### Why the DENY goes on the user, last

A later `GRANT ... TO <role>` replaces a DENY the role holds, and re-running a table-level `GRANT` erases column
DENYs. A DENY on the **user** survives both and beats `db_datareader`. It must come **last**: views and grants first,
then the DAB entities pointed at the views, and only then the DENYs. The other order stops DAB at its next start.

## What the example serves

| Entity | View | Source | Left out | Value cuts |
|---|---|---|---|---|
| `Ops_AppUser` | `dataapi.vw_AppUser` | `core.AppUser` | `Email`, `DisplayName` (personal); `PasswordHash`, `ApiKey` (credential) | `HasApiKey`: 1 when a key is set, never the key |
| `Ops_Webhook` | `dataapi.vw_Webhook` | `svc.Webhook` | `AuthHeader` (credential); `Url` (it can carry one) | `UrlHost`: `scheme://host[:port]` by `dataapi.fnUrlParts`, or NULL; `HasAuthHeader` |
| `Ops_AccountRoute` | `dataapi.vw_AccountRoute` | `ref.fnAccountRoute` per account | `CostPerMessage` (commercial) | none; the gateway must require `AccountUid eq <uuid>` |
| `Ops_MessageTemplate` | `dataapi.vw_MessageTemplate` | `ref.MessageTemplate` | `Body` (content); `TemplateName`, `Description` (free text) | `BodyLength`: the body's length, never the body |
| `Ops_Country` | `dataapi.vw_Country` | `ref.Country` | nothing | none; a small lookup, readable unfiltered; prod only |

`dataapi.fnUrlParts` gives NULL rather than guess: when the value has no scheme at its very start, when the host is
not a plain hostname or IPv4 address with an all-digit port, or when an `@` follows the host (a password holding `/`,
`?`, `#` or a backslash). The host is what follows the **last** `@` of the authority, so `user:pass@` is dropped.

## Files

| File | What it is | Where it goes |
|---|---|---|
| `ops-columns.json` | The reviewed column contract: per entity, the view, the served columns, every left-out column with its reason, the value cuts, the key and the gateway filters. **Edit this file**, then regenerate | this repo |
| `build_ops_views.py` | Generates 03, 04, `dab-entities.ops.json` and `ops-gateway-policy.json` from the contract; `--check` (CI) fails when they are stale; `--live-cols` fails when a live column is neither served nor blocked | run locally; standard library only |
| `01-dataapi-credential-table-views.sql` | `dataapi.fnUrlParts` and the views of the two tables that hold credentials and personal data (hand-written, because they cut values) | `AppDb_dev`, then `AppCatalog` on the prod primary |
| `02-dataapi-routing-views.sql` | The function-backed view: `ref.fnAccountRoute` applied per account | same, after 01 |
| `03-dataapi-generated-views.sql` | The views that need no hand-written cut (generated) | same, after 01 |
| `04-prod-deny-base-objects.sql` | `DENY SELECT` to `svc_dataapi` on every object behind the views, computed from `sys.sql_expression_dependencies`, with a dry run and a verify (generated) | **prod only, last** |
| `dab-entities.ops.json` | The DAB entities (generated); `_dev-excludes` lists the prod-only ones | copied unchanged into a config |
| `ops-gateway-policy.json` | What the gateway in front of `/mcp` must enforce per entity (generated) | the gateway |

## Who reads the views

DAB keeps its one SQL login: `svc_dataapi` in prod (role `role_svc_dataapi`) and `dev_svc_dataapi` in dev (role
`role_dev_svc_dataapi`). 01, 02 and 03 grant `SELECT` on each view to that role and to nothing else; the URL function
and the `dataapi` schema are granted to no one. There is no second login for these entities: the JWT role
(`appdb-data-api-ops-reader`) in each entity's `permissions` keeps these callers apart from the curated ones.

## Order

1. **Dev.** Connect to the dev instance, database `AppDb_dev`, and run 01, 02 and 03. Each ends with a verify query
   that must return 0 rows, and each is safe to run twice. 03 skips `vw_Country` there (no `ref.Country` in dev) and
   returns `Category` as NULL on `vw_MessageTemplate` (no such column in dev yet).
2. **Dev DAB.** Copy the entities from `dab-entities.ops.json` into the dev config unchanged, leaving out
   `_dev-excludes`. Confirm DAB starts and `/health` is healthy. Never add an entity before its view exists: DAB stops
   at startup on a missing object.
3. **Prod.** On the primary (`DATABASEPROPERTYEX('AppCatalog', 'Updateability') = 'READ_WRITE'`), database
   `AppCatalog`, run 01, 02 and 03 once. The availability group carries them to every readable secondary.
4. **Prod DAB.** Copy the entities into the prod config unchanged (Gate OPS-ENTITIES fails on any change), have the
   gateway enforce `ops-gateway-policy.json`, roll out and check health.
5. **Prod DENYs, last.** Once the pods are healthy on the views, run 04 as it is (`@apply = 0`), which prints the DENY
   list; then run it with `@apply = 1`. Its verify sections must return 0 rows. It refuses `AppDb_dev`.

Every script refuses to run anywhere else: outside `AppCatalog` / `AppDb_dev`, or on a read-only copy, it stops with
an error and `SET NOEXEC ON`. In the wrong database the stop message is followed by Msg 208 compile errors; nothing
has run.

## Gates and tests

| Gate | Runs | Proves |
|---|---|---|
| **OPS-ENTITIES** (`ci/gate-ops-entities.sh`) | every push and PR; also inside Gate PROTECTION and Gate ARTIFACT | each staged entity is exactly its contract entry (its view, read-only, one role, exact `fields.include`, GET only, health off); no served column whose name looks sensitive goes without a recorded reason; no config serves an Ops entity or a `dataapi` view any other way; no config serves a contract base object (an entity's source, or a deny-also object) directly, under any name |
| **Ops files are current** (`build_ops_views.py --check`) | every push and PR | 03, 04, the staged entities and the gateway policy are what the contract generates |
| **SQL-VIEWS + API-ACCESS** (`ci/sql-views/run.sh`) | every push and PR | see below |
| **Access smoke** (`ci/access-smoke.sh --mode jwt`) | after a deploy, in your pipeline | dev (`--expect-rest open`): the same API checks on what the deployed pods serve, with real tokens through the mesh; prod (`--expect-rest closed`): `/api` and `/graphql` are refused at the mesh for every token, because only `/mcp` is open there |

SQL-VIEWS + API-ACCESS is the negative security test, in throwaway containers and with no credentials. It runs 01 to
04 in SQL Server 2022 in a prod shape and a dev shape, then DAB (from the `Dockerfile`'s `FROM`, Simulator auth,
connected as `svc_dataapi` after 04's DENYs) in front of the views with every Ops entity. It fails if:

- a view drifts from the contract, or a `dataapi` view exists that the contract does not list;
- a `CANARY` fixture value reaches a view or the API (a credential, personal or free-text value, message content, or
  the login, path, query or fragment of a URL);
- a URL cut, a credential flag or a computed column returns the wrong value;
- the function-backed view's call counts move (1 call with an `AccountUid` filter, one per account without it);
- a blocked column can be selected or filtered on, or another role reads an Ops entity;
- 04 leaves an object behind a view undenied, breaks a view or the curated stored procedure, or changes anything on a
  second run;
- a script runs in `master` or on a read-only database.

Run them locally from the repo root:

```bash
./ci/gate-ops-entities.sh
python3 -I deploy/ops-expansion/build_ops_views.py --check
./ci/sql-views/run.sh                     # Docker and jq; a few minutes, most of it SQL Server startup
SQL_VIEWS_API=0 ./ci/sql-views/run.sh     # the SQL half only
./ci/tests/run-access-smoke-tests.sh      # the smoke's own logic, against a fake DAB and mesh
```

The post-deploy access smoke needs one short-lived token per role, minted per run, in `ACCESS_SMOKE_TOKEN_OPS` (and
`ACCESS_SMOKE_TOKEN_OTHER` for the cross-role checks). Without one it skips with a warning; set
`ACCESS_SMOKE_REQUIRED=true` once your pipeline can mint them, so a missing token fails the deploy. In prod the smoke
cannot test the field rules, since callers reach the entities only through `/mcp` behind the gateway; there the field
rules rest on the same entities the container test and the dev run prove.

## The gateway rules

`ops-gateway-policy.json` lists, per entity: the filters a read must carry (`require-one-of`), the exact-match-only
columns, `aggregates: false` and a page cap. An entity that is not listed is refused. A required filter must be a
top-level conjunct of the `$filter`, so the gateway must refuse `or`, `not`, `in`, brackets and functions; otherwise
`AccountUid eq X or CountryCode eq 'FR'` would pass as filtered. The critical one here is `Ops_AccountRoute`: without
an `AccountUid` filter the view runs its function once per account.

## Changing a column decision

1. Edit `ops-columns.json`: move the column between `served` and `blocked`, and give the reason. If its name matches
   `sensitive-name-pattern`, add a `reviewed` reason.
2. Run `python3 -I build_ops_views.py`. Add `--live-cols <file>` to check that every live column is still either served
   or blocked.
3. If the view is hand-written (01, 02), change it to match; Gate SQL-VIEWS compares every view with the contract.
4. Commit the JSON and the regenerated files together.
5. Rerun the changed script in dev, then prod.
