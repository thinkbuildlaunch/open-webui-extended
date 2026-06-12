---
# Conceptual data model. Anchored at the file level for the model modules it describes
# (whole_file) plus the few access/persistence symbols already verified in the corpus.
# FIELD-LEVEL DETAIL IS NOT YET VERIFIED against models/ — see "Scope & honesty" below.
covers_files:
  - backend/open_webui/models/users.py
  - backend/open_webui/models/groups.py
  - backend/open_webui/models/access_grants.py
  - backend/open_webui/models/knowledge.py
  - backend/open_webui/models/files.py
  - backend/open_webui/internal/db.py
covers_symbols:
  - { symbol: JSONField, file: backend/open_webui/internal/db.py }
  - { file: backend/open_webui/models/access_grants.py, whole_file: true }
  - { file: backend/open_webui/models/knowledge.py, whole_file: true }
  - { file: backend/open_webui/models/files.py, whole_file: true }
  - { file: backend/open_webui/models/users.py, whole_file: true }
  - { file: backend/open_webui/models/groups.py, whole_file: true }
verified_against_commit: <PLACEHOLDER — fill at first in-repo reconciliation>
---

# Data Model — Open WebUI Extended

> **Purpose:** explain the entity relationships conceptually — the *design* behind the schema.
> **Prerequisite:** `ARCHITECTURE.md` for system context.
> **Mechanics reference:** `sqlalchemy.md` / `database-infrastructure.md` for engines, sessions,
> `JSONField`, and migrations.

## Scope & honesty

This is a **conceptual** map of how the entities relate, derived from the component docs and the
`models/` module inventory. It deliberately does **not** assert field-level column lists, because
those have not yet been read from `models/`. Where a relationship is stated, it is at the level the
corpus supports; precise foreign keys, nullability, and column names **must be verified against the
`models/` files** before being relied on (the anchor block marks those modules `whole_file` for
exactly this reason). Treat any field name below as illustrative unless confirmed.

Two structural facts shape everything:

- **The relational store and the vector store are separate.** Relational data (users, chats, files,
  knowledge, …) lives in SQLite/Postgres via SQLAlchemy. RAG chunks + embeddings live in the pluggable
  vector store (pgvector documented), keyed by **collection name**, not by a SQL foreign key. See
  `vector-pgvector.md`.
- **Nested structures are stored as JSON.** Many columns use `JSONField` (`internal/db.py`) to hold
  nested objects rather than normalizing them into tables — so "relationships" are sometimes embedded
  JSON, not joins. Confirm per entity.

## Domains (from the `models/` inventory)

The model layer is organized one module per domain entity. Grouped by concern:

- **Identity & access** — `users`, `groups`, `access_grants`, `auths`, `oauth_sessions`
- **Chat / content** — `chats`/`chat_messages`, `messages`, `folders`, `tags`, `shared_chats`
- **Knowledge / RAG** — `knowledge`, `files`
- **Channels** — `channels`
- **Notes** — `notes`, `prompt_history`
- **Memory & feedback** — `memories`, `feedbacks`
- **Configuration & extensibility** — `models` (model configs), `prompts`, `tools`, `functions`
- **Extended features** — `calendar`, `automations`, `skills`

(Exact module-to-table mapping and columns: read `models/`. This list is the domain decomposition,
not a schema.)

## Core relationships (conceptual)

### Identity → ownership
A **User** owns and is the access subject for most resources (chats, files, knowledge, notes). **Groups**
collect users. Access to a shared resource is mediated by **access grants**, not by ownership alone —
see the access-control model below.

### Chat domain
A **User** has many **Chats**; a Chat contains **Messages** (the conversation turns). **Folders** organize
chats; **Tags** label them (many-to-many). A Chat may be shared via **shared_chats**. Message content and
chat metadata commonly live in `JSONField` columns rather than fully normalized tables — confirm shape in
`models/chats*` / `models/messages.py`.

### Knowledge / RAG domain
**Knowledge** (a collection / knowledge base) groups **Files**. When content is ingested, its chunks are
written to the **vector store** under a collection name — `file-{id}` for a single file, the knowledge-base
id for a collection, and `web-search-{sha}` for web-search results (see `end-to-end-query.md`,
`retrieval-utils.md`). The link between a SQL `File`/`Knowledge` row and its vector chunks is the
**collection-name convention**, not a SQL FK. This is the most important non-obvious relationship in the
data model.

### Access-control model (verified symbols)
Access to chats and files is checked through the **`AccessGrants`** model and helpers — `AccessGrants.has_access(...)`,
`has_access_to_file(...)` (`utils/access_control/files.py`), and `Knowledges.check_access_by_user_id`. Retrieval
additionally filters collections up front via `filter_accessible_collections`. Any new shareable resource
should plug into this model rather than inventing its own check. See `routers.md`, `socket-realtime.md`,
`retrieval-utils.md`.

### Channels domain
**Channels** carry **Messages** and have **members**; real-time delivery uses the channel emitters
(`events:channel` / `events:chat`) rather than the per-user `events` stream. Relationship detail: confirm in
`models/channels.py`. See `socket-realtime.md`.

### Notes & memory
**Notes** are comparatively standalone user-scoped content (and support collaborative editing via the Yjs
layer — see `frontend-rendering.md`, `socket-realtime.md`). **Memories** and **feedbacks** attach to a user
and feed AI features. Confirm scoping in the respective modules.

### Extended-feature domains
`calendar`, `automations`, and `skills` are part of the Extended fork's additions. Their entity relationships
are not yet documented here; they are candidates for their own component docs. Read the modules before
asserting structure.

## Lifecycle (where the data flows)

The relational entities come together in the chat request path: an incoming chat grounds its prompt on
**Files**/**Knowledge** (via vector-store collections), routes through the provider, and persists the
resulting **Messages** to the chat via awaited async `Chats.*` writes. The full trace is in
`end-to-end-query.md`; this doc is the static entity view of the same system.

## Cross-store integrity

Because IndexedDB-style FK enforcement is absent across the relational↔vector boundary (the vector store is
keyed by collection name), **referential integrity across that boundary is maintained by application code** —
e.g. deleting a File must also delete its `file-{id}` vector collection (`await ASYNC_VECTOR_DB_CLIENT.delete(...)`
in the files/retrieval routers). Confirm the exact cleanup paths in `routers.md`.

## Verification Recipe

```bash
# Model modules exist (domain inventory)
ls backend/open_webui/models/
# Access-control model + helper
grep -rn "class AccessGrants\|def has_access" backend/open_webui/models/access_grants.py
grep -rn "def has_access_to_file" backend/open_webui/utils/access_control/files.py
grep -rn "def check_access_by_user_id" backend/open_webui/models/knowledge.py
# JSONField (nested JSON storage)
grep -rn "class JSONField" backend/open_webui/internal/db.py
# Vector collection naming convention (relational↔vector link)
grep -rn "file-\|web-search-" backend/open_webui/retrieval/utils.py | head
```

> Before advancing this doc's marker, replace the `whole_file` model anchors with `{symbol, file}`
> anchors for the specific classes/relationships once `models/` has been read (Standard II.7/II.8), and
> confirm every relationship above against the actual columns. This first pass is intentionally
> conservative about field-level claims.
