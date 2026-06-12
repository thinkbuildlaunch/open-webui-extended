# Documentation Index — Open WebUI Extended

> **Purpose:** route a task to the right document. For humans and AI agents.
> **Verification:** this is a navigation doc — it is **link-verified, not symbol-verified**
> (`DOCUMENTATION_STANDARD.md`, I.8). It carries no code anchors of its own; the docs it
> points to do. It carries no volatile counts; those live in `FILE_TREE.md` (Standard III.4).

There are three bands of documentation. Keep them straight:

1. **Verified internals** — the anchored component docs and architecture overview. Reverse-engineered
   against the code, each pinned to a commit with a verification recipe. Authoritative for *how the
   backend actually works*.
2. **Overarching / operational** — this index, the standard, `CLAUDE.md`, the glossary, the data model,
   directives, and the drift-automation spec. The scaffolding that makes the internals navigable and
   keeps them honest.
3. **Upstream product docs** — the official Open WebUI documentation (in project knowledge). Upstream-
   maintained, feature- and user-facing. Authoritative for *what features exist and how to use them* —
   **not** for internals, and may describe legacy paths (e.g. Pipelines).

---

## Quick Reference — "I want to…"

| I want to… | Start here | Band |
|---|---|---|
| See the whole-system map | `ARCHITECTURE.md` | internals |
| Trace one chat request end-to-end | `end-to-end-query.md` | internals |
| Understand a confusing/overloaded term | `DOMAIN_GLOSSARY.md` | overarching |
| Understand entity relationships & lifecycle | `DATA_MODEL.md` | overarching |
| Add or change a database table/migration | `DIRECTIVE_database_migration.md` → `sqlalchemy.md` | overarching → internals |
| Know how docs are written/verified | `DOCUMENTATION_STANDARD.md` | overarching |
| Bootstrap an agent session | `CLAUDE.md` | overarching |
| Reduce or detect doc drift | `DOCUMENTATION_DRIFT_AUTOMATION.md` | overarching |
| Find file sizes / what's safe to read in full | `FILE_TREE.md` *(pending — blocked on repo metrics)* | overarching |
| Learn what the product does (features) | Upstream product docs (Functions, Knowledge, Tools, …) | product |
| Use Functions / Filters / Tools / MCP as a user | the matching upstream product doc | product |

---

## AI Agent Task → Documents

| Task | Primary | Secondary |
|---|---|---|
| Bug fix in the chat pipeline | `end-to-end-query.md` | `payload-transformation.md`, `middleware`/`chat` via `routers.md` |
| Bug fix in streaming / real-time | `socket-realtime.md`, `websockets.md` | `heartbeats.md`, `redis.md` |
| RAG / retrieval change | `retrieval-utils.md` | `vector-pgvector.md`, `routers.md` |
| Database / model change | `DIRECTIVE_database_migration.md`, `sqlalchemy.md` | `database-infrastructure.md`, `DATA_MODEL.md` |
| Redis / multi-instance / HA | `redis.md` | `redis-sentinels.md`, `task-management.md` |
| Concurrency / blocking work | `threadpooling.md` | `sqlalchemy.md` |
| Config / env / settings | `env-configuration.md` | `main-entrypoint.md`, `redis.md` (AppConfig) |
| Startup / app assembly / middleware | `main-entrypoint.md` | `cli-entrypoint.md` |
| Frontend rendering / artifacts | `frontend-rendering.md` | `websockets.md` |
| Provider payloads (OpenAI/Ollama/Azure) | `payload-transformation.md` | `task-templates.md` |
| Automated task prompts (title/tags/RAG templates) | `task-templates.md` | `task-management.md` (distinct file!) |
| Any new doc / editing a doc | `DOCUMENTATION_STANDARD.md` | `CLAUDE.md` |

---

## Layer Map

```
Orientation        ARCHITECTURE.md · DOCUMENTATION_INDEX.md · CLAUDE.md · FILE_TREE.md(pending) · PRODUCT_OVERVIEW.md(pending)
Semantic           DOMAIN_GLOSSARY.md · DATA_MODEL.md
Procedural         DIRECTIVE_database_migration.md  (+ future directives for extended patterns)
Standard/Tooling   DOCUMENTATION_STANDARD.md · DOCUMENTATION_DRIFT_AUTOMATION.md
Operational/       ── component docs (verified internals) ──
 component          bootstrap:   main-entrypoint · cli-entrypoint · env-configuration
                    pipeline:    end-to-end-query · payload-transformation · task-templates · routers
                    retrieval:   retrieval-utils · vector-pgvector
                    real-time:   websockets · socket-realtime · heartbeats
                    persistence: sqlalchemy · database-infrastructure
                    shared state: redis · redis-sentinels · task-management · threadpooling
                    frontend:    frontend-rendering
```

---

## Component Docs (verified internals)

Each carries its own anchor block, "what changed since the original guide" corrections, and a
verification recipe. Authoritative over this index.

**Bootstrap & configuration** — `main-entrypoint.md`, `cli-entrypoint.md`, `env-configuration.md`
**API / routing** — `routers.md`
**Chat / request pipeline** — `end-to-end-query.md`, `payload-transformation.md`, `task-templates.md`
**Retrieval / RAG** — `retrieval-utils.md`, `vector-pgvector.md`
**Real-time** — `websockets.md`, `socket-realtime.md`, `heartbeats.md`
**Persistence** — `sqlalchemy.md`, `database-infrastructure.md`
**Shared state & coordination** — `redis.md`, `redis-sentinels.md`, `task-management.md`, `threadpooling.md`
**Frontend** — `frontend-rendering.md`

---

## Upstream Product Docs (external, upstream-maintained)

Use these for feature/usage questions; do **not** treat them as internals, and note that some describe
legacy paths. They are upstream's to maintain — link, don't restate (Standard III.4 spirit).

- Extensibility overview; Functions (Pipe / Filter / Action); Filters; Tools; Tools & Functions (Plugins)
- Knowledge; Prompts; Skills
- Model Context Protocol (MCP) Support; OpenAPI Tool Servers; Open WebUI Integration
- Pipelines *(legacy — prefer Functions)*; Tutorials; FAQ

---

## Pending / Blocked

These are planned but not yet produced because they require repository inputs (see the roadmap):

- `FILE_TREE.md` — needs real file sizes / LOC / token tiers from the repo.
- `PRODUCT_OVERVIEW.md` — needs the list of Extended-vs-upstream features to right-size scope.
- `tools/check_doc_staleness.sh` validated against the tree — needs repo access (Standard III.6).

---

## Maintaining This Index

- New component doc → add it to "Component Docs" and the relevant Task → Documents row.
- New directive → add to "Procedural" and the matching task row.
- Moved/renamed doc → fix every link here (this index is link-verified; broken links are its staleness).
- Directory layout for the docs is still TBD; once decided, confirm all relative links and the
  `docs/**/*.md` glob in the staleness tool (Standard III.5).
