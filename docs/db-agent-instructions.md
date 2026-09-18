# DB Agent — knowledge & routing instructions (appdb-data-api MCP)

**Status:** accepted — one agent, one RBAC read-only API (agreed with DBA, 2026-08-27)

Operating manual for the **DB agent** that fronts the `appdb-data-api` MCP, plus the
**routing context** the master agent needs to know *when* to hand a turn to it.

---

## 1. What this MCP is (routing context for the master agent)

`appdb-data-api` is a **strict read-only** app-data API over the AppDb SQL estate,
exposed as MCP tools at **`/mcp`** (also REST/GraphQL). It opens **all user databases
and their objects** (tables + views across AppDb, AppDb_Data, AppDb_Voice, AppDb_Routing,
AppDb_Video, AppDb_Analytics, AppDb_Connect) for reading — **not** a curated stored-procedure
allowlist. Governance is **role-based access control (RBAC)**: auth is Microsoft Entra
(EntraId JWT) → a per-team DAB role → a least-privilege SQL login whose **grants decide
which objects/schemas that caller can read**. Read-only is enforced at every layer:
`ApplicationIntent=ReadOnly`, SELECT-only, and MCP tools limited to **discover + read**
(`describe-entities`, read) — no create/update/delete/execute-write, no DDL.

**Route to the DB agent when** the user wants to look up or trace *application/customer
data* in any of those DBs — accounts, sub-accounts, balance, channel/the messaging channel config,
SMS/message history, voice CDRs, MNO/HLR, etc. **Do not route here for**: any
write/change or message send; DBA/health/performance/incident work (that's the separate
`appdb-sql-mcp` DBA server); or objects the caller's role isn't granted (it'll be denied
by SQL — expected).

---

## 2. Agreed shape: one agent, one API, RBAC per object/schema

Decided (agreed with DBA, 2026-08-27): **one DB agent** across all domains, over **one
API**. Domain separation (Msg vs Voice vs …) is handled by **RBAC on objects/schemas**,
not by standing up separate agents or separate APIs. So:

- **One agent** loads the full schema corpus (§3b) and routes by intent.
- **One API** exposes every user DB read-only; each team gets a **role** (in dev today:
  `appdb-data-api-msg-reader`, `appdb-data-api-voi-reader`) granting SELECT only on the
  objects/schemas it may see. A caller simply gets "object not permitted" for anything
  outside its role.
- No per-domain agents, no per-domain APIs, no curated-SP surface to maintain.

`master agent → one DB agent → one read-only MCP (RBAC-scoped) → all user DBs`

---

## 3. The read surface

The agent reads objects directly (strict read-only); there is no fixed tool list to
memorize and no SP allowlist. Two moves:

- **Discover** with `describe-entities` — see which objects/columns the caller's role
  actually exposes (the surface is RBAC-scoped, so it differs per team/login).
- **Read** the object with a tight, indexed/partition-aligned filter.

What a given agent can touch is exactly what its **SQL role grants** — trust that
boundary rather than a hardcoded allowlist. Access denied = the role doesn't grant it
(expected), not a bug.

> **Sensitive & very large objects are RBAC-gated, not code-blocked.** e.g.
> `AppDb_Data.msg.MessageLog` is PII (Body, MSISDN) and very large, monthly-partitioned.
> If your role grants it, still **never scan it unbounded** — filter on
> `CreatedDate`/`CreatedTime` (the partition key) + account, and prefer the
> `AppDb_Analytics` aggregates for volume/trend questions.

---

## 3b. Knowledge base — full schema corpus (all user DBs)

The agent is grounded in the **sql-documenter corpus** bundled in `appdb-sql-mcp`
(`server/schema-docs/`), the same one that server serves — so knowledge never drifts
between the two MCPs. It covers **every** user DB: `AppDb`, `AppDb_Analytics`, `AppDb_Routing`,
`AppDb_Voice`, `AppDb_Video`, `AppDb_Connect`.

- **AppDb + AppDb_Data are in one `AppDb` corpus**, not separate trees: config and
  transactional DBs **share schema names** (`msg, core, ipm, tc, svc, …`), so each object
  carries a **`project`** tag — `AppDb_MSG` (config), `AppDb_MSG_data` (transactional), or
  `both`. Core high-volume tables (MessageLog, StatMessageLog, MessageTrack, AccountBalance,
  ProtectionAlertLog, the cloud data warehouseCommandLog, …) are documented in full; the long tail is in
  per-schema `inventory` groups.

Use the corpus to decode coded columns, know which DB/table a fact lives in (read the
`project` tag — config → AppDb_MSG, delivery/history/stats → AppDb_MSG_data), and choose the
right object + filter before reading.

---

## 4. Operating rules for the DB agent

- **Read-only, always.** No write path exists. Change/send/suspend requests are out of
  scope — say so and point to the owning system.
- **Discover before reading** an unfamiliar object (`describe-entities`), and **filter
  on an indexed/partition key with a bound** — especially on the huge `AppDb_Data`
  tables. Never issue an unbounded scan; use the `AppDb_Analytics` aggregates for
  volume/trend.
- **Decode coded columns** using §5 (or the corpus) before answering; never surface raw
  numeric codes without their meaning.
- **You usually need an `AccountUid` (GUID)** to scope a customer lookup. If given a
  name/email/number you can't resolve here, ask for the identifier — don't fabricate one.
- **Respect RBAC.** If the role can't read an object, report that plainly; don't try to
  route around it.
- **State source & freshness:** config (AppDb) is global/cross-region; balances and
  transactional data are near-real-time.

---

## 5. Common enum decodings (reference; corpus is authoritative)

- **Product families:** `CA`=Chat Apps, `SM`=SMS, `VI`=Video, `VO`=Voice, `V8`=Verify.
- **Active:** `0`=inactive, `1`=active.
- **ProtectionStatusId:** `0`=Disabled, `1`=Monitoring, `2`=Alerts Enabled.
- **MsgProcessingFlags** (bitmask): `1`=DrReceived, `2`=DrSent, `4`=DrDeliveredToCarrier, `8`=FinalDr, `16`=OptOutMo.
- **ChannelTypeId:** `0/13`=SMS, `1`=the messaging channel, `2`=Facebook, `3`=RCS, `4`=AppleBusinessChat, `5`=Viber, `6`=Line, `7`=WeChat, `8`=Zalo, `9`=Kakao, `10`=ZaloNotification, `11`=Instagram, `12`=LineNotification, `14`=Call, `15`=Mock.
- **Channel status:** `A`=Active, `D`=Deployment, `F`=Failed, `M`=Migration, `P`=Pending, `R`=Rejected, `S`=Stopped, `V`=Validation.
- **the messaging channel template status:** `1`=Approved, `2`=Pending, `3`=Rejected, `4`=Pending deletion, `5`=Deleted, `6`=In appeal, `7`=Disabled, `8`=Paused.
- **the messaging channel template category (current):** `14`=UTILITY, `15`=AUTHENTICATION, `16`=MARKETING (1–13 deprecated).

---

## 6. One corpus, both MCPs (keep it fresh)

Single canonical semantic layer: `appdb-sql-mcp/server/schema-docs/<DB>/<schema>/*.json`,
fed from each `appdb-*-db` repo's **default branch** by
`appdb-sql-mcp/server/scripts/sync-schema-docs.mjs` (manifest `schema-docs.sources.json`;
additive). `appdb-sql-mcp` serves it via its `list_/search_/describe_` schema-doc tools;
this agent loads the same files as knowledge, and `scripts/import-schema-docs.mjs` reads
the same tree for any grounding text. To refresh: merge a repo's `docs/schemas` to its
default branch, then run `node appdb-sql-mcp/server/scripts/sync-schema-docs.mjs` — one
command updates the corpus for both MCPs.
