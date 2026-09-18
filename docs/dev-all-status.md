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

Check 6 is the reason the gate exists. `CONN_DEV_` and `CONN_DEVVO_` are kept
distinct by the underscore after `DEV`.

## Adding a database

1. Add `config/dev-all/dab-config.dev-all.<db>.json` — voice databases take a
   `.vo.` segment in the filename and a `CONN_DEVVO_` key; everything else takes a
   `CONN_DEV_` key.
2. Give it a `data-source`, its entities, and the matching reader role. No
   `runtime` block: children inherit it from the base.
3. List it in the base's `data-source-files`.
4. Run `ci/gate-dev-all-tree.sh` and `ci/gate-conn-keys.sh`.

Steps 1 and 3 are separately checkable, which is exactly why the gate checks both
directions — a child added to disk but not to the base, or listed in the base but
never written, both pass every other gate.
