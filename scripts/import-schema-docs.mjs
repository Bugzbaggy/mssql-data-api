// Build DAB MCP grounding text from sql-documenter output, so entity/parameter descriptions
// carry real column meanings + ENUM decodings instead of agents guessing.
//
// Source shape = the sql-documenter skill's output in the appdb-msg-db repo:
//   docs/schemas/<schema>/tables.json      -> { tables:      [ { name, description, columns:[{name,type,description}], enums:{Col:{"0":"x"}} } ] }
//   docs/schemas/<schema>/procedures.json  -> { procedures:  [ { name, description, parameters:[{name,type,description,required,default}] } ] }
//   docs/schemas/<schema>/views.json       -> { views:       [ { name, description, columns:[...] } ] }
//
// Default source = the SHARED canonical corpus that both MCPs use:
//   ../../appdb-sql-mcp/server/schema-docs/AppDb   (AppDb_MSG config + AppDb_MSG_data,
//   project-tagged) — kept current by appdb-sql-mcp/server/scripts/sync-schema-docs.mjs
//   (which pulls each repo's default branch). So appdb-data-api grounding is generated
//   from the same knowledge appdb-sql-mcp serves — no separate/​drifting doc copy.
//
// Usage (override to any DB's corpus dir, or another repo's docs/schemas):
//   node scripts/import-schema-docs.mjs                        # default: shared AppDb corpus
//   node scripts/import-schema-docs.mjs "<...>/schema-docs/AppDb_Voice"
// Emits generated/descriptions.json = { "<schema>.<object>": { description, params? } }.
// Paste the relevant text into each entity's `description` / `source.parameters[].description`
// in dab-config.json / config/*.json (map each SP to the table(s) it reads). Re-run when docs regenerate.
import { readdirSync, readFileSync, writeFileSync, mkdirSync, existsSync, statSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const DOCS = resolve(process.argv[2] || join(here, "..", "..", "appdb-sql-mcp", "server", "schema-docs", "AppDb"));
const OUT = join(here, "..", "generated");

if (!existsSync(DOCS)) {
  console.error(`schema-docs not found at ${DOCS}
Pass the path to the sql-documenter output, e.g. the appdb-msg-db repo's docs/schemas dir:
  node scripts/import-schema-docs.mjs "<repo>/docs/schemas"`);
  process.exit(1);
}

const out = {};
const readJson = (p) => { try { return JSON.parse(readFileSync(p, "utf8")); } catch { return null; } };

// Render a table-level enums block ({ Col: {"0":"x","1":"y"} }) into compact decode text.
function enumsText(enums) {
  if (!enums || typeof enums !== "object") return "";
  const parts = Object.entries(enums)
    .filter(([, m]) => m && typeof m === "object")
    .map(([col, m]) => `${col}: ${Object.entries(m).map(([k, v]) => `${k}=${v}`).join(", ")}`);
  return parts.length ? ` Codes — ${parts.join("; ")}.` : "";
}

function tableDesc(t) {
  const base = t.description || t.purpose || "";
  return (base + enumsText(t.enums)).trim() || null;
}

function procParams(p) {
  const ps = p.parameters || p.params;
  if (!Array.isArray(ps)) return undefined;
  return ps
    .filter((x) => x && x.name)
    .map((x) => ({ name: x.name, description: x.description || "", required: !!x.required, default: x.default ?? "" }));
}

for (const schema of readdirSync(DOCS)) {
  const schemaPath = join(DOCS, schema);
  if (!statSync(schemaPath).isDirectory()) continue;
  for (const f of readdirSync(schemaPath).filter((f) => f.endsWith(".json"))) {
    const doc = readJson(join(schemaPath, f));
    if (!doc) continue;
    for (const t of doc.tables || []) {
      const d = tableDesc(t);
      if (t.name && d) out[`${schema}.${t.name}`] = { description: d };
    }
    for (const v of doc.views || []) {
      if (v.name && (v.description || v.purpose)) out[`${schema}.${v.name}`] = { description: v.description || v.purpose };
    }
    for (const p of doc.procedures || []) {
      if (!p.name) continue;
      const entry = { description: p.description || p.purpose || "" };
      const params = procParams(p);
      if (params) entry.params = params;
      out[`${schema}.${p.name}`] = entry;
    }
  }
}

mkdirSync(OUT, { recursive: true });
writeFileSync(join(OUT, "descriptions.json"), JSON.stringify(out, null, 2));
console.log(`Wrote ${Object.keys(out).length} object descriptions -> generated/descriptions.json (from ${DOCS})`);
