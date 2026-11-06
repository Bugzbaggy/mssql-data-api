---
status: implemented
---

# Adding a table safely

**Status:** Implemented (the pattern and its gates); the example entities are staged, not loaded.

The curated API serves stored procedures. When a team needs rows from a table instead, serve the table through a
**projection view** that leaves out every credential, personal-data, content and free-text column, and let the gates
prove it. This page is the exact procedure. The worked example, with five entities over the sample tables in
[`seed/02-ops-sample-schema.sql`](../seed/02-ops-sample-schema.sql), is
[`deploy/ops-expansion/`](../deploy/ops-expansion/README.md); read its README for why each layer exists.

Never point a DAB entity at the base table, and never hide columns with a column-level `DENY`: DAB 2.0.9 reads every
table and view entity at startup with `SET FMTONLY ON; SELECT *`, SQL Server checks column permissions even then, and
one denied column (Msg 230) stops the whole engine.

## 1. Classify every column

List the table's columns from the catalog, in the database the API will read:

```sql
SELECT c.column_id, c.name, TYPE_NAME(c.user_type_id) AS type_name, c.max_length, c.is_nullable
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID(N'svc.Webhook')
ORDER BY c.column_id;
```

Put every column in exactly one place:

| Category (`ops-columns.json` `categories`) | Examples | Served? |
|---|---|---|
| `credential` | password hashes, API keys, tokens, client secrets, an `Authorization` header, a URL (its login, path or query can carry one) | never; a flag (`HasApiKey`) or a cut (`UrlHost`) at most |
| `personal` | e-mail addresses, names, phone numbers, postal addresses, logins | never |
| `content` | message bodies, template bodies | never; a length or a flag at most |
| `free-text` | names, descriptions or comments a customer or staff member typed | never: free text can hold anything |
| `commercial` | prices, costs, margins | not without the owner's sign-off |
| `not-needed` | anything no question needs | no |
| served | keys, states, types, timestamps, codes | yes |

If a value can carry a secret, cut the value rather than dropping a useful column: `dataapi.fnUrlParts` reduces a URL
to `scheme://host[:port]`, or NULL when it does not parse cleanly.

## 2. Add the entity to the contract

Add an entry to [`deploy/ops-expansion/ops-columns.json`](../deploy/ops-expansion/ops-columns.json):

| Field | What to put there |
|---|---|
| `entity` | `Ops_<Name>`: the DAB entity name |
| `view` | `dataapi.vw_<Name>` |
| `source` | the base `schema.object` (a table, view or table-valued function) |
| `script` | `03` for a view the generator writes (plain columns, optional `expr`); `01`/`02` for a hand-written view (value cuts, functions) |
| `envs` | `["prod", "dev"]`, or `["prod"]` when the dev copy lacks the table |
| `key-fields` | the key DAB pages on; every key column must be served |
| `served` | the view's columns, in order |
| `blocked` | every left-out column, with its category (`"credential: served only as HasApiKey"` is fine) |
| `reviewed` | a reason for every served column whose name matches `sensitive-name-pattern` (`LastLoginAt`, `ContentType`, `HasApiKey`) |
| `cuts`, `expr` | how a derived column is computed; `expr` is the SQL for a generated view (`"CAST(LEN(s.[Body]) AS int)"`) |
| `dev-null` | a served column the dev copy lacks, with its prod type: the dev view returns NULL of that type |
| `required-filters` | the filters the gateway must require, as alternatives (`[["AccountUid"], ["UserId"]]`); empty only for a small lookup |
| `exact-match-only` | columns the gateway accepts only with `eq` on one literal |
| `description` | what a caller sees in `describe-entities` |

If another object exposes the same columns (a reporting view over the table, say), add it to `deny-also`: no entity
may serve it, and 04 denies it too.

## 3. Write or generate the view

- **Generated (`script: "03"`).** Nothing to write.
- **Hand-written (`01`/`02`).** Add the view to the script, after the target guard, with an explicit column list (never
  `SELECT *`), `OUTER APPLY dataapi.fnUrlParts(<url>)` for a URL, and `CAST(CASE WHEN NULLIF(<secret>, '') IS NULL THEN 0
  ELSE 1 END AS bit)` for a credential flag. Add the view to the script's grant list. No `SCHEMABINDING` if another
  team's schema project owns the base table: its deploys would fail on any change to a bound column (Msg 4922).

## 4. Regenerate

```bash
python3 -I deploy/ops-expansion/build_ops_views.py
```

It validates the contract (fails on a column both served and blocked, a key that is not served, a sensitive-looking
name without a reason, an unknown category) and rewrites `03-dataapi-generated-views.sql`,
`04-prod-deny-base-objects.sql`, `dab-entities.ops.json` and `ops-gateway-policy.json`.

To prove that every live column is either served or blocked, export the columns and pass them in:

```sql
SELECT OBJECT_SCHEMA_NAME(c.object_id) + N'.' + OBJECT_NAME(c.object_id) AS [object], c.name AS [column]
FROM sys.columns AS c
WHERE c.object_id IN (OBJECT_ID(N'core.AppUser'), OBJECT_ID(N'svc.Webhook'), OBJECT_ID(N'ref.MessageTemplate'))
ORDER BY [object], c.column_id
FOR JSON PATH;
```

```bash
jq 'group_by(.object) | map({key: .[0].object, value: map({name: .column})}) | from_entries' cols.json > live-cols.json
python3 -I deploy/ops-expansion/build_ops_views.py --live-cols live-cols.json
```

## 5. Extend the container test

In [`ci/sql-views/fixtures/prod-schema.sql`](../ci/sql-views/fixtures/prod-schema.sql) (and `dev-schema.sql` if the
dev copy differs), add rows for the new table with the marker `CANARY` in **every** blocked value, and in the login,
path and query of every URL. The harness reads every `dataapi` view as the DAB user and fails on any `CANARY` in the
output, so a view that serves a blocked column, or cuts a URL in the wrong place, is caught. Add an expected value to
`ci/sql-views/assert-prod-values.sql` for every cut, and the base table to the refusal list in
`assert-prod-deny.sql`.

## 6. Run the gates

```bash
./ci/gate-ops-entities.sh                                   # the entities against the contract, and every config
python3 -I deploy/ops-expansion/build_ops_views.py --check  # the generated files are current
./ci/sql-views/run.sh                                       # the views, the DENYs and the API, in containers
./ci/gate-protection.sh                                     # every config-protection gate, as CI and Gate ARTIFACT run it
```

All four run in CI on every push and pull request.

## 7. Deploy

1. **Dev views.** Run 01, 02 and 03 in `AppDb_dev`; each verify query returns 0 rows.
2. **Dev DAB.** Copy the entity from `dab-entities.ops.json` into the dev config **unchanged** (Gate OPS-ENTITIES fails on
   any edit), leaving out `_dev-excludes`. Check that DAB starts and `/health` is healthy.
3. **Prod views.** Run 01, 02 and 03 in `AppCatalog` on the primary.
4. **Prod DAB.** Copy the entity into the prod config unchanged, have the gateway enforce its entry in
   `ops-gateway-policy.json`, roll out, check health.
5. **Prod DENYs, last.** Run `04-prod-deny-base-objects.sql` as it is (a dry run that prints the list), then with
   `@apply = 1`. Its verify sections return 0 rows.
6. **Access smoke.** After each deploy, with one short-lived token per role:
   - dev: `ci/access-smoke.sh --base <dev API root> --mode jwt --env dev --expect-rest open`;
   - prod: `ci/access-smoke.sh --base <prod API root> --mode jwt --expect-rest closed` (only `/mcp` is open to JWT
     callers there, so the test is that `/api` and `/graphql` are refused at the mesh).

The order matters: views and grants, then entities, then DENYs. A DENY before DAB has moved to the view stops DAB at
its next start.

## Rollback

- An entity: remove it from the config and roll out. The view can stay; nothing else reads it.
- A DENY: `REVOKE SELECT ON <object> FROM svc_dataapi;` (only needed if something must read the base table directly as
  that login again).
- A view: `DROP VIEW dataapi.vw_<Name>;` after its entity is gone.
