# Program for ci/sql-views/run.sh. Renders the column contract (deploy/ops-expansion/ops-columns.json) or the staged
# entities (dab-entities.ops.json) for the container test, so every check follows those files, not a hand-kept copy.
#   --arg what expected-columns --arg env prod|dev   (input: ops-columns.json)    T-SQL: each view's columns vs the contract
#   --arg what contract-lists                         (input: ops-columns.json)    T-SQL: #already_served, #deny_also, #entity_sources
#   --arg what dab-config                             (input: dab-entities.ops.json) a DAB config: Simulator auth, every entity
def lit: "N'" + (split("'") | join("''")) + "'";
def values_of(rows): if (rows | length) == 0 then "" else "INSERT \(.) VALUES " + (rows | join(", ")) + ";" end;

# --arg env is passed for expected-columns only; jq compiles the whole program, so read it where it may be absent.
($ARGS.named.env // "") as $env
| if $what == "expected-columns" then
  [ .entities[] | select(.envs | index($env)) | .view as $v | .served | to_entries[]
    | "(\($v | lit), \(.key + 1), \(.value | lit))" ] as $rows
  | "SET NOCOUNT ON;",
    "DECLARE @e TABLE (v sysname, ord int, col sysname);",
    ("@e" | values_of($rows)),
    "DECLARE @r TABLE (line nvarchar(1000));",
    "INSERT @r SELECT CONCAT(N'FAIL columns of ', COALESCE(e.v, a.v), N' #', COALESCE(e.ord, a.ord), N': expected ', ISNULL(e.col, N'-'), N', got ', ISNULL(a.col, N'-'))",
    "FROM @e AS e FULL JOIN (SELECT N'dataapi.' + v.name AS v, c.column_id AS ord, c.name AS col",
    "                        FROM sys.views AS v JOIN sys.columns AS c ON c.object_id = v.object_id",
    "                        WHERE v.schema_id = SCHEMA_ID(N'dataapi')) AS a ON a.v = e.v AND a.ord = e.ord",
    "WHERE e.col IS NULL OR a.col IS NULL OR e.col <> a.col COLLATE Latin1_General_BIN2;",
    "INSERT @r SELECT CONCAT(N'FAIL view not in ops-columns.json: dataapi.', name) FROM sys.views",
    "WHERE schema_id = SCHEMA_ID(N'dataapi') AND N'dataapi.' + name NOT IN (SELECT v FROM @e);",
    "IF NOT EXISTS (SELECT 1 FROM @r) INSERT @r SELECT CONCAT(N'OK columns: ', COUNT(DISTINCT v), N' views match ops-columns.json exactly (', COUNT(*), N' columns, \($env))') FROM @e;",
    "SELECT line FROM @r;"
elif $what == "contract-lists" then
  [(."already-served" // [])[] | "(\(lit))"] as $served
  | [(."deny-also" // [])[] | "(\(.object | lit))"] as $deny
  | ([.entities[] | select(.envs | index("prod")) | .source] | unique | map("(\(lit))")) as $sources
  | "SET NOCOUNT ON;",
  "IF OBJECT_ID(N'tempdb..#already_served') IS NOT NULL DROP TABLE #already_served;",
  "IF OBJECT_ID(N'tempdb..#deny_also') IS NOT NULL DROP TABLE #deny_also;",
  "IF OBJECT_ID(N'tempdb..#entity_sources') IS NOT NULL DROP TABLE #entity_sources;",
  "CREATE TABLE #already_served (n nvarchar(300));",
  "CREATE TABLE #deny_also (n nvarchar(300));",
  "CREATE TABLE #entity_sources (n nvarchar(300));",
  ("#already_served" | values_of($served)),
  ("#deny_also" | values_of($deny)),
  ("#entity_sources" | values_of($sources))
elif $what == "dab-config" then
  { "data-source": {"database-type": "mssql", "connection-string": "@env('CONN_CI')"},
    "runtime": {"rest": {"enabled": true, "path": "/api"}, "graphql": {"enabled": true, "path": "/graphql"},
                "host": {"mode": "development", "authentication": {"provider": "Simulator"}}},
    "entities": .entities }
else
  error("unknown --arg what: \($what)")
end
