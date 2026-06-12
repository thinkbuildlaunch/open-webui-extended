---
# Procedural directive, anchored per Directive 8. Symbols below are drawn from sqlalchemy.md /
# database-infrastructure.md and must be re-read before the marker is advanced (11.3/11.7).
covers_files:
  - backend/open_webui/internal/db.py
  - backend/open_webui/config.py
  - backend/open_webui/migrations/env.py
  - backend/open_webui/migrations/util.py
  - backend/open_webui/env.py
covers_symbols:
  - { symbol: Base, file: backend/open_webui/internal/db.py }
  - { symbol: JSONField, file: backend/open_webui/internal/db.py }
  - { symbol: run_migrations, file: backend/open_webui/config.py }
  - { symbol: get_existing_tables, file: backend/open_webui/migrations/util.py }
  - { symbol: get_revision_id, file: backend/open_webui/migrations/util.py }
verified_against_commit: <PLACEHOLDER — fill at first in-repo reconciliation>
---

# Directive: Database Schema Migration

> **Pattern type:** Data layer
> **Complexity:** Medium
> **Files touched:** model module + Alembic revision (+ optional access/route wiring)

This directive merges two systems: the **tripartite procedural form** (Structural → Illustrative →
Transfer) and this repository's **verification standard** (anchor block above, recipe below). Unlike a
bespoke client-side migration system, Open WebUI uses **standard Alembic** — so most of the mechanics are
Alembic's, and the value here is the handful of repository-specific touchpoints an agent gets wrong.

> **Read first — this is Alembic, not Peewee, and runtime DB is async.** Migrations are pure Alembic, run
> from `config.py`'s `run_migrations()` (gated by `ENABLE_DB_MIGRATIONS`). Peewee is entirely removed
> (no `internal/wrappers.py`, no `internal/migrations/`). DDL runs on the **sync** engine; the async engine
> is the runtime path and is not used for migrations. See `database-infrastructure.md`, `sqlalchemy.md`.

---

## Structural Pattern

Schema changes to a server-side relational database (SQLite or Postgres) are versioned with Alembic. The
declarative model layer defines the desired schema; an Alembic **revision** transforms an existing database
to match; revisions form a linked chain by `down_revision`.

Properties and invariants:

- **Additive is safest.** Adding a table/column is lower-risk than altering or dropping.
- **Revisions are immutable once shipped.** Never edit a revision that has been applied in any deployment;
  add a new one.
- **The chain must stay linear and connected.** Each revision's `down_revision` points at its predecessor;
  do not create branches or orphans without an explicit merge revision.
- **Nested/complex data uses `JSONField`** (`internal/db.py`) rather than over-normalizing — decide
  per column whether a relationship is a real table or embedded JSON.
- **Dual engine.** `run_migrations()` and DDL use the sync engine; all runtime reads/writes use the async
  engine + `AsyncSession`. Don't reach for the async engine in a migration.

---

## Illustrative Application

Adding a new table follows these touchpoints. *(Exact Alembic invocation and the `env.py`/`util.py`
internals are standard Alembic plus the helpers below; **confirm command names against the repo** — see
the recipe.)*

### 1. Define the model
Add a declarative model in `backend/open_webui/models/` (one module per domain entity), using `Base` from
`internal/db.py` and `JSONField` for any nested-JSON column. This is the source of the desired schema.

### 2. Author an Alembic revision
Add a revision under `backend/open_webui/migrations/versions/` whose `down_revision` is the current head,
with `upgrade()` creating the table and `downgrade()` reversing it. The migration environment lives in
`migrations/env.py`; helper utilities in `migrations/util.py` include `get_existing_tables` (used to make
table creation idempotent/safe against partially-migrated databases) and `get_revision_id`. Use
`get_existing_tables` rather than assuming a clean database. *(Confirm whether revisions are authored by
hand or via `alembic revision --autogenerate` in this repo before relying on autogenerate.)*

### 3. How it applies at runtime
On startup, `run_migrations()` in `config.py` runs `command.upgrade(cfg, "head")` when `ENABLE_DB_MIGRATIONS`
is set. There is no separate migration step in `db.py`. So a correctly-authored revision is applied
automatically on next boot.

### 4. Wire access control and cleanup (if the table is a shareable resource)
If the new entity is user-owned or shareable, plug it into the access-control model (`AccessGrants` /
`has_access_to_file` / `check_access_by_user_id`) rather than inventing a check (`routers.md`,
`socket-realtime.md`). If it owns vector-store data, ensure deletion also clears the corresponding
collection (`ASYNC_VECTOR_DB_CLIENT.delete(...)`) — the relational↔vector link is by collection name, not FK
(`DATA_MODEL.md`).

---

## Transfer Prompt

**When you need to add or change a database table or column:**

1. **Decide the storage shape.** Real table vs. embedded `JSONField`. Index only what you query.
2. **Update the model** in `models/` using `Base` and `JSONField`.
3. **Author an Alembic revision** in `migrations/versions/` with `down_revision = <current head>`; write both
   `upgrade()` and `downgrade()`. Use `get_existing_tables` to stay safe on partially-migrated DBs.
4. **Confirm it applies** via `run_migrations()` / `ENABLE_DB_MIGRATIONS` (don't add migration logic to
   `db.py`).
5. **Use the sync engine for any DDL**, the async engine for runtime — never mix.
6. **Wire access control + vector cleanup** if the entity is shareable / owns chunks.
7. **Update docs:** if this touches the data model or schema, update `DATA_MODEL.md` (and re-read its marker
   per the standard). Put any new aggregate counts only in `FILE_TREE.md`, never in prose.

**Signals this pattern applies:**
- A feature needs new persistent storage, a new queryable field, or a structural change to existing data.

**Avoid these mistakes:**
- Editing an already-shipped revision instead of adding a new one.
- Branching/orphaning the revision chain without a merge revision.
- Assuming a clean database in `upgrade()` (use `get_existing_tables`).
- Using the async engine inside a migration, or adding migration logic to `db.py`.
- Re-introducing Peewee constructs (they were fully removed — prove absence before claiming otherwise).
- Hand-normalizing data that the codebase stores as `JSONField` (or vice versa) without checking the model.

---

## Verification Recipe

```bash
# Alembic, gated migrations, no Peewee
grep -rn "def run_migrations\|command.upgrade" backend/open_webui/config.py
grep -rn "ENABLE_DB_MIGRATIONS" backend/open_webui/env.py backend/open_webui/config.py
grep -rn "peewee\|internal/wrappers\|internal/migrations" backend/open_webui/ || echo "no peewee (expected)"
# Migration env + helpers
grep -rn "def get_existing_tables\|def get_revision_id" backend/open_webui/migrations/util.py
ls backend/open_webui/migrations/versions/ | head
# Declarative base + JSONField
grep -rn "Base = declarative_base\|class JSONField" backend/open_webui/internal/db.py
# Confirm the actual authoring command in use (hand-written vs autogenerate)
grep -rni "autogenerate\|alembic" backend/ | head
```

> **Caveat (confirm before trusting):** the exact revision-authoring workflow (manual vs `--autogenerate`)
> and any project-specific revision-id scheme were not read from the repo for this draft. Verify via the
> recipe and update this directive before advancing its marker (Standard 11.3).
