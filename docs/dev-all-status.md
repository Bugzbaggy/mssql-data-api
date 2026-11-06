# The `dev-all` config tree

## What it is

A DAB **base** config that fans out to one **child** config per database. One pod,
one process, many data sources: the base carries the runtime block (REST, GraphQL,
MCP, auth) and lists its children under `data-source-files`; each child carries its
own `data-source` and its own entities.

```
dab-config.dev-all.json                        base: runtime + data-source-files
└── config/dev-all/
    ├── dab-config.dev-all.mno.json            messaging host   @env('CONN_DEV_…')
    └── dab-config.dev-all.vo.mno.json         voice host       @env('CONN_DEVVO_…')
```

The split is the access boundary. Gate RBAC pins the reader role **by filename** —
`*.vo.*.json` gets `appdb-data-api-voi-reader`, everything else
`appdb-data-api-msg-reader` — so a child's filename, its connection key and its
role must agree. `ci/gate-dev-all-tree.sh` is what enforces that.

## What is published here

The tree above is a **sanitised example**, not the deployed one. The real tree
carries eleven live connection strings across two hosts and is not publishable. The
example keeps the structure, the naming convention and the messaging/voice split
intact, with placeholder `@env()` keys and two reference-data stored procedures, so
the gates and the test suite run end to end against something real in shape.

`tools/generate-dev-all-entities.mjs`, which generates the real tree from a live
schema, is not published. Add children by hand, following the two examples.

## What `ci/gate-dev-all-tree.sh` checks

`dab validate` is satisfied by each file on its own: a base that lists nothing, a
child nothing serves, and a child wired to the wrong host's credential are all
individually well-formed. The damage only appears at runtime. The gate checks the
tree as a whole:

| # | Check | Why it matters |
|---|---|---|
| 1 | base lists at least one child | a base that lists nothing serves nothing, and validates green |
| 2 | every listed file exists | a missing child is a silently absent set of entities |
| 3 | no file listed twice | the count looks right while a file is absent from disk |
| 4 | no orphan file in `config/dev-all/` | a generated config nothing serves is invisible until someone asks for that data |
| 5 | every child serves ≥ 1 entity | an empty child is a data source nothing reaches |
| 6 | connection key matches the filename's domain | **the credential-crossing case** — a voice-named child on a messaging key serves messaging data under a voice role |
| 7 | the base declares no entities of its own | DAB would serve them on the base's data source, outside every child and outside the protected list |
| 8 | no `autoentities` anywhere, no `data-source-files` in a child | DAB serves both, and no `.entities` walk — no gate — sees what they serve. Even an empty `autoentities: {}` in the base switches the children's on |
| 9 | connection string is exactly `@env('<KEY>')`, and the file name is the one the naming rule derives from that key | DAB's `@env()` match is lazy, so trailing text rides along unseen; and a renamed or decoy file would point a protected-list line at another database |

Check 6 is the reason the gate exists. `CONN_DEV_` and `CONN_DEVVO_` are kept
distinct by the underscore after `DEV`.

### The naming rule

A child's file name follows from its connection key: drop the `CONN_DEV_` /
`CONN_DEVVO_` prefix, the `_DEV` suffix and a leading `AppDb_`, then the
underscores, and lower-case the rest; voice keys add a `vo.` segment.

| Key | File |
|---|---|
| `CONN_DEV_AppDb_MNO_DEV` | `config/dev-all/dab-config.dev-all.mno.json` |
| `CONN_DEVVO_AppDb_MNO_DEV` | `config/dev-all/dab-config.dev-all.vo.mno.json` |
| `CONN_DEV_AppDb_MSG_DATA_DEV` | `config/dev-all/dab-config.dev-all.msgdata.json` |

## Protected data: `ci/gate-dev-all-protected.sh`

A broad-read tree serves every table and view it is given, so what it must NOT serve
is written down: `config/dev-all/protected-excluded.txt`, one line per object,
`<config file> TAB <schema.object> TAB <reason>`.

| Reason | Meaning |
|---|---|
| `secret-columns:<a,b>` / `pii-columns:<a,b>` | the object may be served, but no role may read those columns |
| `canonical:<entity>` | the object may be served only under that one entity name, on any database — for a table a client pins by entity name (one account per call, say): the same rows under any other name are an unpinned read |
| anything else | the object must not be served at all (aliases, ETL copies, parked production snapshots) |

The config file names the database: a line is checked against every config on the
same connection key, and against the base, because a copy in another file is the
same exposure. Permissions are evaluated the way DAB 2.0.9 resolves them
(`ci/dab-perms.jq`): `Read`, `all` and `*` are reads, every read action of a role
counts (GraphQL unions them), include lists match columns ignoring case while
exclude names compare exactly, and `"*"` means "every column" only when it is alone.

Column-name rules miss two shapes, so list them by hand:

- **Credentials kept as rows.** A key/value settings table (`Name`, `Value`) holds
  passwords and API keys in its *value* column, under a name no pattern flags. List
  the value column as `secret-columns:Value`.
- **Personal data under generic names.** A custom-field table (`FieldName`,
  `FieldValue`) holds names, e-mails and phone numbers. List it as `pii-columns`.

The published list is an example in the shape the gate reads: none of its objects is
served by the example tree, so every line holds today, and the gate self-tests serve
each one and show the line failing.

## Adding a database

1. Add `config/dev-all/dab-config.dev-all.<db>.json` — voice databases take a
   `.vo.` segment in the filename and a `CONN_DEVVO_` key; everything else takes a
   `CONN_DEV_` key. The file name must follow from the key (the naming rule above).
2. Give it a `data-source`, its entities, and the matching reader role. No
   `runtime` block: children inherit it from the base.
3. List it in the base's `data-source-files`.
4. Add its credential, contact and billing objects to
   `config/dev-all/protected-excluded.txt`.
5. Run `ci/gate-dev-all-tree.sh`, `ci/gate-dev-all-protected.sh` and
   `ci/gate-conn-keys.sh` — or all of them at once, `ci/gate-protection.sh`.

Steps 1 and 3 are separately checkable, which is exactly why the gate checks both
directions — a child added to disk but not to the base, or listed in the base but
never written, both pass every other gate.
