"""Generate the Ops entity artifacts from ops-columns.json, the reviewed column contract.

    python3 -I build_ops_views.py [--check] [--live-cols <file.json>]

Writes, next to this file:
  03-dataapi-generated-views.sql  the views of the entities whose contract entry says "script": "03"
  04-prod-deny-base-objects.sql   the prod-only DENY step: every object a dataapi view reads, with a dry run and a verify
  dab-entities.ops.json           every Ops_* entity, fields.include = the contract's served list exactly
  ops-gateway-policy.json         what the gateway in front of /mcp must enforce per entity (required filters, no aggregates)

--check writes nothing and exits 1 when any of the four files differs from what the contract generates (CI runs it).
--live-cols takes {"schema.object": [{"name": ...}, ...]} (each source object's real column list, read from the catalog)
and fails unless every live column is either served or blocked with a reason, so a column added to a base table is
reviewed before anyone can serve it. Standard library only; nothing here touches a database.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = json.load(open(os.path.join(HERE, "ops-columns.json"), encoding="utf-8"))
ROLE = SPEC["role"]
PROD = SPEC["dab-login"]["prod"]
DEV = SPEC["dab-login"]["dev"]
PAT = re.compile(SPEC["sensitive-name-pattern"].replace("(?i)", ""), re.I)
PLAIN = re.compile(r"[A-Za-z0-9_]+")
OBJ = re.compile(r"[A-Za-z0-9_]+\.[A-Za-z0-9_]+")
SCRIPTS = {"01", "02", "03"}
errors = []


def q(name):
    return "[" + name.replace("]", "]]") + "]"


def obj_sql(dotted):
    s, o = dotted.split(".", 1)
    return f"{q(s)}.{q(o)}"


def lit(s):
    return "N'" + s.replace("'", "''") + "'"


# ------------------------------------------------------------------ checks on the contract itself
names = [e["entity"] for e in SPEC["entities"]]
if len(set(names)) != len(names):
    errors.append("duplicate entity names")
for x in (PROD, DEV):
    for k in ("database", "user", "role"):
        if not PLAIN.fullmatch(x.get(k, "")):
            errors.append(f"dab-login: {k} {x.get(k)!r} is not a plain name")
for e in SPEC["entities"]:
    n, served, blocked = e["entity"], e["served"], e["blocked"]
    if not n.startswith("Ops_") or not PLAIN.fullmatch(n):
        errors.append(f"{n}: entity names are Ops_<plain name>")
    if not re.fullmatch(r"dataapi\.vw_[A-Za-z0-9_]+", e["view"]):
        errors.append(f"{n}: the view must be dataapi.vw_<plain name>")
    if not OBJ.fullmatch(e["source"]) or e["source"].startswith("dataapi."):
        errors.append(f"{n}: source {e['source']!r} is not a plain schema.object outside dataapi")
    if e["script"] not in SCRIPTS:
        errors.append(f"{n}: script {e['script']!r} is not one of {sorted(SCRIPTS)}")
    if not e["envs"] or not set(e["envs"]) <= {"prod", "dev"} or "prod" not in e["envs"]:
        errors.append(f"{n}: envs must be [prod] or [prod, dev]")
    for c in list(served) + list(blocked):
        if not PLAIN.fullmatch(c):
            errors.append(f"{n}: column {c!r} is not a plain name")
    if len(set(served)) != len(served):
        errors.append(f"{n}: duplicate served column")
    if set(served) & set(blocked):
        errors.append(f"{n}: served and blocked overlap: {sorted(set(served) & set(blocked))}")
    if not e["key-fields"] or not set(e["key-fields"]) <= set(served):
        errors.append(f"{n}: key-fields {e['key-fields']} must be served columns")
    for alt in e["required-filters"]:
        if not alt or not set(alt) <= set(served):
            errors.append(f"{n}: required filter {alt} names a column that is not served")
    for c in e["exact-match-only"]:
        if c not in served:
            errors.append(f"{n}: exact-match-only column {c} is not served")
    for c in served:
        if PAT.search(c) and c not in e["reviewed"]:
            errors.append(f"{n}: served column {c} matches the sensitive-name pattern but has no 'reviewed' reason")
    for c in e["reviewed"]:
        if c not in served:
            errors.append(f"{n}: 'reviewed' names {c}, which is not served")
    for c in list(e["expr"]) + list(e["dev-null"]):
        if c not in served:
            errors.append(f"{n}: expr/dev-null names {c}, which is not served")
    if e["script"] != "03" and (e["expr"] or e["dev-null"]):
        errors.append(f"{n}: expr and dev-null apply to generated (script 03) views only")
    if e["dev-null"] and "dev" not in e["envs"]:
        errors.append(f"{n}: dev-null on a prod-only entity")
    cats = set(SPEC["categories"])
    for c, why in blocked.items():
        if why.split(":")[0] not in cats:
            errors.append(f"{n}: blocked {c} has unknown category {why!r}")
for d in SPEC["deny-also"]:
    if not OBJ.fullmatch(d["object"]):
        errors.append(f"deny-also: {d['object']!r} is not a plain schema.object")
for o in SPEC["already-served"]:
    if not OBJ.fullmatch(o):
        errors.append(f"already-served: {o!r} is not a plain schema.object")

if "--live-cols" in sys.argv:
    live = json.load(open(sys.argv[sys.argv.index("--live-cols") + 1], encoding="utf-8"))
    for e in SPEC["entities"]:
        cols = live.get(e["source"])
        if cols is None:
            continue  # a function (its columns are its outputs) or an object the file does not list
        live_names = [x["name"] for x in cols]
        for c in live_names:  # every live column is either served (possibly cut) or blocked with a reason
            if c not in e["served"] and c not in e["blocked"]:
                errors.append(f"{e['entity']}: live column {c} of {e['source']} is neither served nor blocked")
        if e["script"] == "03":  # generated views select base columns by name: only expr columns are computed
            for c in e["served"]:
                if c not in live_names and c not in e["expr"]:
                    errors.append(f"{e['entity']}: served {c} is not a live column of {e['source']}")

if errors:
    print("ops-columns.json is not consistent:", *errors, sep="\n  ", file=sys.stderr)
    sys.exit(1)

GUARD = f"""/* Target guard: the same as 01 and 02. Run in {PROD['database']} (prod primary) or {DEV['database']} (dev), in the database
   itself (no USE). Anywhere else, or on a read-only copy, it raises an error and SET NOEXEC ON stops every later batch.
   In the wrong database the stop message is followed by Msg 208 compile errors; that is expected, and nothing has run. */
DECLARE @db sysname = DB_NAME(), @srv sysname = @@SERVERNAME;
IF @db NOT IN ({lit(PROD['database'])}, {lit(DEV['database'])})
   OR CAST(DATABASEPROPERTYEX(@db, 'Updateability') AS varchar(20)) <> 'READ_WRITE'
BEGIN
    RAISERROR(N'Stopped: run this in {PROD['database']} (prod primary) or {DEV['database']} (dev), on a writable copy. Current: %s on %s.', 16, 1, @db, @srv);
    SET NOEXEC ON;
END;
GO
IF SCHEMA_ID(N'dataapi') IS NULL EXEC (N'CREATE SCHEMA dataapi AUTHORIZATION dbo;');
GO"""


# ------------------------------------------------------------------ 03: generated views
def select_list(e, null_cols=None):
    out = []
    for c in e["served"]:
        if null_cols and c in null_cols:
            out.append(f"CAST(NULL AS {null_cols[c]}) AS {q(c)}")
        elif c in e["expr"]:
            out.append(f"{e['expr'][c]} AS {q(c)}")
        else:
            out.append(f"s.{q(c)}")
    return out


def view_ddl(e, null_cols=None):
    body = ",\n       ".join(select_list(e, null_cols))
    return f"CREATE OR ALTER VIEW {obj_sql(e['view'])}\nAS\nSELECT {body}\nFROM {obj_sql(e['source'])} AS s;"


def by_cat(e):
    groups = {}
    for c, why in e["blocked"].items():
        groups.setdefault(why.split(":")[0], []).append(c)
    return groups


def gen_03():
    gen = [e for e in SPEC["entities"] if e["script"] == "03"]
    L = [f"""/*
  appdb-data-api - Operations entities: the {len(gen)} views generated from the column contract.

  GENERATED by build_ops_views.py from ops-columns.json. Edit the JSON and regenerate; do not edit this file by hand
  (CI runs build_ops_views.py --check and fails on any difference).

  Where and when: as 01 and 02 ({DEV['database']} first, then {PROD['database']} on the prod primary), after 01. Safe to run
  twice. Grants SELECT on each view to the DAB login's role only ({PROD['role']} in prod, {DEV['role']} in dev). The
  base-object DENYs are 04, prod only, last.

  A contract entry can say how dev differs: "envs": ["prod"] skips the view where its source does not exist in
  {DEV['database']}, and "dev-null" serves a column the dev copy lacks as NULL of the prod type. In {PROD['database']}
  either case stops the script instead.
*/""", GUARD]
    for e in gen:
        g = by_cat(e)
        blocked_txt = "; ".join(f"{k}: {', '.join(v)}" for k, v in g.items()) or "nothing"
        total = len([c for c in e["served"] if c not in e["expr"]]) + len(e["blocked"])
        comment = [f"/* {e['source']} -> {e['view']} ({e['entity']}): {len(e['served'])} served, {total} base columns reviewed.",
                   f"   Left out: {blocked_txt}."]
        for c, why in e["cuts"].items():
            comment.append(f"   {c}: {why}.")
        for note in e["notes"]:
            comment.append(f"   {note}")
        L.append("\n".join(comment) + " */")
        if e["dev-null"]:
            prod = view_ddl(e).replace("'", "''")
            dev = view_ddl(e, e["dev-null"]).replace("'", "''")
            conds = " AND ".join(f"COL_LENGTH({lit(e['source'])}, {lit(c)}) IS NOT NULL" for c in e["dev-null"])
            L.append(f"IF {conds}\n    EXEC (N'{prod}');\nELSE IF DB_NAME() = {lit(DEV['database'])}\n    EXEC (N'{dev}');\n"
                     f"ELSE\n    RAISERROR(N'{e['source']} lacks a column the view serves: {', '.join(e['dev-null'])}.', 16, 1);\nGO")
        elif e["envs"] == ["prod"]:
            prod = view_ddl(e).replace("'", "''")
            L.append(f"IF OBJECT_ID({lit(e['source'])}) IS NOT NULL\n    EXEC (N'{prod}');\nELSE IF DB_NAME() = {lit(DEV['database'])}\n"
                     f"    PRINT N'Skipped {e['view']}: {e['source']} does not exist in {DEV['database']} (prod-only entity {e['entity']}).';\n"
                     f"ELSE\n    RAISERROR(N'{e['source']} does not exist.', 16, 1);\nGO")
        else:
            L.append(view_ddl(e) + "\nGO")
    views_values = ",\n          ".join(f"({lit(e['view'])})" for e in gen)
    L.append(f"""/* Grants: SELECT on each view this script created, and nothing else, to the DAB login's role. Undo one with
   REVOKE SELECT ON <view> FROM <that role>. */
DECLARE @dab sysname = CASE DB_NAME() WHEN {lit(PROD['database'])} THEN {lit(PROD['role'])} WHEN {lit(DEV['database'])} THEN {lit(DEV['role'])} END;
IF DATABASE_PRINCIPAL_ID(@dab) IS NULL
BEGIN
    DECLARE @db sysname = DB_NAME();
    RAISERROR(N'%s does not exist in %s: create the DAB user and role first.', 16, 1, @dab, @db);
END
ELSE
BEGIN
    DECLARE @sql nvarchar(max) = N'';
    SELECT @sql += N'GRANT SELECT ON ' + v + N' TO ' + QUOTENAME(@dab) + N'; '
    FROM (VALUES {views_values}) AS t(v)
    WHERE OBJECT_ID(v) IS NOT NULL;
    EXEC sys.sp_executesql @sql;
END
GO""")
    exp_rows = []
    for e in gen:
        for i, c in enumerate(e["served"], 1):
            exp_rows.append(f"({lit(e['view'])}, {i}, {lit(c)})")
    exp_values = ",\n        ".join(exp_rows)
    L.append(f"""/* Verify (read-only): each view's columns are exactly the contract's served list, in order. Expect 0 rows. A skipped
   prod-only view in dev shows nothing here. */
WITH expected AS (SELECT v, ord, col FROM (VALUES
        {exp_values}) AS x(v, ord, col)),
actual AS (SELECT OBJECT_SCHEMA_NAME(c.object_id) + N'.' + OBJECT_NAME(c.object_id) AS v, c.column_id AS ord, c.name AS col
           FROM sys.columns AS c WHERE c.object_id IN (SELECT OBJECT_ID(v) FROM expected))
SELECT COALESCE(e.v, a.v) AS view_name, COALESCE(e.ord, a.ord) AS ordinal, e.col AS expected_column, a.col AS actual_column
FROM (SELECT * FROM expected WHERE OBJECT_ID(v) IS NOT NULL) AS e
FULL JOIN actual AS a ON a.v = e.v AND a.ord = e.ord
WHERE e.col IS NULL OR a.col IS NULL OR e.col <> a.col COLLATE Latin1_General_BIN2;
GO
SET NOEXEC OFF;
GO""")
    return "\n\n".join(L) + "\n"


# ------------------------------------------------------------------ 04: prod-only DENYs, computed from the catalog
def gen_04():
    served = ", ".join(f"({lit(o)})" for o in SPEC["already-served"]) or "(CAST(NULL AS nvarchar(300)))"
    deny_also = ", ".join(f"({lit(d['object'])})" for d in SPEC["deny-also"]) or "(CAST(NULL AS nvarchar(300)))"
    user = PROD["user"]
    walk = """WITH deps AS (
    SELECT d.referenced_id AS object_id
    FROM sys.sql_expression_dependencies AS d
    JOIN sys.objects AS o ON o.object_id = d.referencing_id
    WHERE o.schema_id = SCHEMA_ID(N'dataapi') AND d.referenced_id IS NOT NULL
    UNION ALL
    -- Walk down only through views and table-valued functions: a table's CHECK constraints and computed columns make it
    -- reference itself, which would loop forever.
    SELECT d.referenced_id
    FROM deps JOIN sys.objects AS ro ON ro.object_id = deps.object_id AND ro.type IN ('V', 'IF', 'TF')
    JOIN sys.sql_expression_dependencies AS d ON d.referencing_id = deps.object_id
    WHERE d.referenced_id IS NOT NULL AND d.referenced_id <> d.referencing_id)"""
    not_served = (f"NOT EXISTS (SELECT 1 FROM (VALUES {served}) AS s(n) WHERE OBJECT_ID(s.n) = o.object_id)"
                  "   -- not NOT IN: one missing object would make it NULL and drop every row")
    listed = ", ".join(SPEC["already-served"]) or "none in this contract"
    return f"""/*
  appdb-data-api - Operations entities: the base-object DENYs, as a required last step.

  GENERATED by build_ops_views.py from ops-columns.json. PROD ONLY: {PROD['database']} on the primary, after 01, 02 and 03,
  and only once the DAB pods are healthy on the views. Never in dev; the guard refuses {DEV['database']}.

  What it does: every object a dataapi view reads, directly or through another view or function, gets
  DENY SELECT TO {user}, except the objects DAB already serves by grant ("already-served": {listed}), plus the
  objects in "deny-also" (no view reads them, but they expose the same columns). The list comes from
  sys.sql_expression_dependencies at run time, so a view added later is covered by running this script again.

  Why a DENY on the user and not the role: a later GRANT ... TO <role> replaces a DENY the role holds, and re-running a
  table-level GRANT erases column DENYs; a DENY on the user survives both and beats db_datareader. A DAB config that
  regresses to a base object then fails closed (Msg 229) instead of serving its columns. The views keep working
  through ownership chaining (everything is dbo-owned), and so do stored procedures that read the same tables; the
  verify below proves the views.

  Run it twice: first as it is (@apply = 0) to print the DENY list, then with @apply = 1. Undo one with
  REVOKE SELECT ON <object> FROM {user}.
*/
DECLARE @db sysname = DB_NAME(), @srv sysname = @@SERVERNAME;
IF @db <> {lit(PROD['database'])} OR CAST(DATABASEPROPERTYEX(@db, 'Updateability') AS varchar(20)) <> 'READ_WRITE'
   OR DATABASE_PRINCIPAL_ID({lit(user)}) IS NULL
BEGIN
    RAISERROR(N'Stopped: run this in {PROD['database']} on the prod primary, where {user} exists. Current: %s on %s.', 16, 1, @db, @srv);
    SET NOEXEC ON;
END;
GO
DECLARE @apply bit = 0;   -- 0: print the list only. 1: apply the DENYs.
DECLARE @targets TABLE (object_id int PRIMARY KEY, name nvarchar(300), type_desc nvarchar(60));
{walk}
INSERT @targets (object_id, name, type_desc)
SELECT DISTINCT o.object_id, QUOTENAME(OBJECT_SCHEMA_NAME(o.object_id)) + N'.' + QUOTENAME(o.name), o.type_desc
FROM deps JOIN sys.objects AS o ON o.object_id = deps.object_id
WHERE o.schema_id <> SCHEMA_ID(N'dataapi')
  AND o.type IN ('U', 'V', 'IF', 'TF')          -- tables, views, table-valued functions (scalar functions are not read with SELECT)
  AND {not_served}
OPTION (MAXRECURSION 20);
-- Also denied, though no dataapi view reads them ("deny-also"):
INSERT @targets (object_id, name, type_desc)
SELECT o.object_id, QUOTENAME(OBJECT_SCHEMA_NAME(o.object_id)) + N'.' + QUOTENAME(o.name), o.type_desc
FROM (VALUES {deny_also}) AS x(n) JOIN sys.objects AS o ON o.object_id = OBJECT_ID(x.n)
WHERE NOT EXISTS (SELECT 1 FROM @targets AS t WHERE t.object_id = o.object_id);
DECLARE @sql nvarchar(max) = N'';
SELECT @sql += N'DENY SELECT ON ' + name + N' TO {q(user)};' + NCHAR(10) FROM @targets ORDER BY name;
DECLARE @n int = (SELECT COUNT(*) FROM @targets);
PRINT CONCAT(N'-- ', @n, N' objects:');
PRINT @sql;
IF @apply = 1 EXEC sys.sp_executesql @sql;
ELSE PRINT N'-- Dry run: nothing applied. Set @apply = 1 to apply.';
GO
/* Verify (read-only). 1: every object a dataapi view reads has the DENY (expect 0 rows once applied). */
{walk}
SELECT DISTINCT OBJECT_SCHEMA_NAME(o.object_id) + N'.' + o.name AS object_without_deny
FROM deps JOIN sys.objects AS o ON o.object_id = deps.object_id
WHERE o.schema_id <> SCHEMA_ID(N'dataapi') AND o.type IN ('U', 'V', 'IF', 'TF')
  AND {not_served}
  AND NOT EXISTS (SELECT 1 FROM sys.database_permissions AS p
                  WHERE p.major_id = o.object_id AND p.minor_id = 0 AND p.permission_name = N'SELECT' AND p.state = 'D'
                    AND p.grantee_principal_id = DATABASE_PRINCIPAL_ID({lit(user)}))
OPTION (MAXRECURSION 20);
/* 2: as {user}, every dataapi view still reads (expect 0 rows). */
DECLARE @fail TABLE (view_name nvarchar(300), error nvarchar(2000));
DECLARE @v nvarchar(300), @s nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + N'.' + QUOTENAME(name) FROM sys.views WHERE schema_id = SCHEMA_ID(N'dataapi');
OPEN c; FETCH NEXT FROM c INTO @v;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @s = N'SELECT TOP (0) * FROM ' + @v + N';';
    BEGIN TRY
        EXECUTE AS USER = {lit(user)};
        EXEC sys.sp_executesql @s;
        REVERT;
    END TRY
    BEGIN CATCH
        IF USER_NAME() = {lit(user)} REVERT;
        INSERT @fail VALUES (@v, CONCAT(N'Msg ', ERROR_NUMBER(), N': ', ERROR_MESSAGE()));
    END CATCH;
    FETCH NEXT FROM c INTO @v;
END;
CLOSE c; DEALLOCATE c;
SELECT view_name, error FROM @fail;
/* 3: the objects DAB serves by grant are not denied (expect 0 rows). */
SELECT OBJECT_SCHEMA_NAME(p.major_id) + N'.' + OBJECT_NAME(p.major_id) AS served_object_denied
FROM sys.database_permissions AS p
JOIN (VALUES {served}) AS s(n) ON OBJECT_ID(s.n) = p.major_id
WHERE p.grantee_principal_id = DATABASE_PRINCIPAL_ID({lit(user)}) AND p.state = 'D';
GO
SET NOEXEC OFF;
GO
"""


# ------------------------------------------------------------------ dab-entities.ops.json
def gen_entities():
    prod_only = [e["entity"] for e in SPEC["entities"] if "dev" not in e["envs"]]
    ents = {}
    for e in SPEC["entities"]:
        ents[e["entity"]] = {
            "description": e["description"],
            "source": {"object": e["view"], "type": "view", "key-fields": e["key-fields"]},
            "health": {"enabled": False},
            "rest": {"enabled": True, "methods": ["get"]},
            "graphql": {"enabled": True, "operation": "query"},
            "permissions": [{"role": ROLE, "actions": [{"action": "read", "fields": {"include": e["served"]}}]}],
        }
    out = {
        "_README": (
            "STAGED, NOT LOADED BY DAB: no config lists this file. GENERATED by build_ops_views.py from ops-columns.json; edit that "
            f"file and regenerate. {len(ents)} entities over the dataapi views that 01, 02 and 03 create. To serve them, copy the "
            "entities unchanged into a config (dev first, leaving out _dev-excludes); Gate OPS-ENTITIES fails on any change made "
            "on the way. Never add an entity before its view exists: DAB stops at startup on a missing object."),
        "_dev-excludes": prod_only,
        "entities": ents,
    }
    return json.dumps(out, indent=2, ensure_ascii=True) + "\n"


# ------------------------------------------------------------------ ops-gateway-policy.json
def gen_policy():
    pol = {}
    for e in SPEC["entities"]:
        pol[e["entity"]] = {
            "source": e["view"],
            "require-one-of": e["required-filters"],
            "unfiltered-allowed": not e["required-filters"],
            "exact-match-only": e["exact-match-only"],
            "aggregates": False,
            "max-page-size": 100,
            "envs": e["envs"],
        }
    return json.dumps({
        "_README": (
            "GENERATED by build_ops_views.py. What the gateway in front of /mcp must enforce for the Ops_* entities, because DAB "
            "itself applies no filter: an entity not listed is refused; every read of a listed entity must satisfy one "
            "alternative of require-one-of, where every column of that alternative appears in the $filter with eq; "
            "exact-match-only columns accept eq on one literal only (no ranges, startswith, in or lists); unfiltered-allowed is "
            "true only for small lookups; aggregates are refused; page size is capped at max-page-size. A required filter must "
            "be a top-level conjunct of the $filter, so refuse or, not, in, brackets and functions: otherwise "
            "'AccountUid eq X or CountryCode eq Y' would pass as filtered."),
        "role": ROLE,
        "entities": pol}, indent=2, ensure_ascii=True) + "\n"


outputs = {
    "03-dataapi-generated-views.sql": gen_03(),
    "04-prod-deny-base-objects.sql": gen_04(),
    "dab-entities.ops.json": gen_entities(),
    "ops-gateway-policy.json": gen_policy(),
}

if "--check" in sys.argv:
    stale = []
    for name, text in outputs.items():
        path = os.path.join(HERE, name)
        try:
            with open(path, encoding="utf-8", newline="") as f:
                have = f.read().replace("\r\n", "\n")
        except FileNotFoundError:
            have = None
        if have != text:
            stale.append(name)
    if stale:
        print("stale (run python3 -I build_ops_views.py and commit the result):", *stale, sep="\n  ", file=sys.stderr)
        sys.exit(1)
    print(f"OK: {len(outputs)} generated files match ops-columns.json ({len(SPEC['entities'])} entities)")
    sys.exit(0)

for name, text in outputs.items():
    with open(os.path.join(HERE, name), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
prod_only = [e["entity"] for e in SPEC["entities"] if "dev" not in e["envs"]]
print(f"OK: {len(SPEC['entities'])} entities (prod-only: {', '.join(prod_only) or 'none'}); wrote {', '.join(outputs)}")
