---
# Anchored per I.8 — each entry below makes a falsifiable code claim. The block lists
# representative anchors; the per-entry citations are the individual falsifiable references.
covers_files:
  - backend/open_webui/socket/main.py
  - backend/open_webui/socket/utils.py
  - backend/open_webui/env.py
  - backend/open_webui/config.py
  - backend/open_webui/internal/config.py
  - backend/open_webui/internal/db.py
  - backend/open_webui/tasks.py
  - backend/open_webui/utils/task.py
  - backend/open_webui/retrieval/utils.py
  - backend/open_webui/retrieval/vector/async_client.py
covers_symbols:
  - { symbol: SESSION_POOL_TIMEOUT, file: backend/open_webui/socket/main.py }
  - { symbol: get_event_emitter, file: backend/open_webui/socket/main.py }
  - { symbol: RedisDict, file: backend/open_webui/socket/utils.py }
  - { symbol: AppConfig, file: backend/open_webui/internal/config.py }
  - { symbol: JSONField, file: backend/open_webui/internal/db.py }
  - { symbol: redis_task_command_listener, file: backend/open_webui/tasks.py }
  - { symbol: prompt_template, file: backend/open_webui/utils/task.py }
  - { symbol: get_sources_from_items, file: backend/open_webui/retrieval/utils.py }
verified_against_commit: <PLACEHOLDER — fill at first in-repo reconciliation>
---

# Domain Glossary — Open WebUI Extended

A disambiguation reference for the terms most often confused in this codebase. Unlike a business
glossary, the "domain" here is the platform's own infrastructure vocabulary, and the most valuable
entries say **what a term is, where it lives, and what it is *not*.** Each entry cites the file and
symbol so the claim is checkable (I.9); see the named component doc for depth.

---

## Shared-state pools and Redis primitives

**`SESSION_POOL`** — per-session presence/connection state (heartbeat `last_seen_at`, etc.). Lives in
`socket/main.py`; backed by a Redis hash (`RedisDict`) in multi-instance, a plain dict otherwise.
*Not* `USAGE_POOL`, *not* `MODELS`, and *not* a `USER_POOL` (which does not exist). See `heartbeats.md`,
`socket-realtime.md`.

**`USAGE_POOL`** — model-usage tracking state. `socket/main.py`; reaped by `periodic_usage_pool_cleanup`.
See `socket-realtime.md`.

**`MODELS`** — the model registry. Exists both as a cross-instance pool and as `app.state.MODELS` (read
in `chat_completion`). `socket/main.py` / `main.py`. See `main-entrypoint.md`.

**`USER_POOL` — DOES NOT EXIST.** Per-user fan-out is done with a Socket.IO **room** named `user:{id}`,
not a dict. Any doc or code referencing `USER_POOL` is describing a previous/fictional version. See
`socket-realtime.md`.

**`RedisDict`** — a Redis-hash-backed dict that makes the pools visible across instances. `socket/utils.py`.
**Deliberately never `DELETE`s the hash** on bulk set — it `HSET`s new values then `HDEL`s stale keys so
concurrent readers never see an empty dict. Do not "optimize" to atomic `DELETE`+`HSET`. See `redis.md`,
Standard I.6.

**`RedisLock`** — distributed lock for cleanup coordination (only one instance runs a reaper loop).
`socket/utils.py`. See `heartbeats.md`, `redis.md`.

**`YdocManager`** — CRDT (Yjs) collaborative-document state, with update compaction. `socket/utils.py`.
See `redis.md`, `socket-realtime.md`.

---

## Configuration

**`env.py`** — startup/infra settings read **once at import** (paths, device, logging, DB/Redis/WebSocket
wiring, secrets). *Not* user-editable at runtime. Do not look here for RAG/OAuth/feature settings. See
`env-configuration.md`.

**`config.py` / `ConfigVar`** — the large catalog of **user-facing** settings (AI providers, RAG, OAuth,
web search, most feature flags), persisted in the DB and editable from the Admin UI. This is where
`THREAD_POOL_SIZE`, `CORS_ALLOW_ORIGIN`, and the RAG/OAuth vars live — *not* `env.py`. See
`env-configuration.md`.

**`AppConfig`** — bridges live config values to Redis so they are runtime-mutable and centrally
discoverable. `internal/config.py`. See `redis.md`.

**`SRC_LOG_LEVELS`** — a retained-but-empty legacy dict (`{} # do not remove`). There is no per-component
log-level loop anymore; logging is `GLOBAL_LOG_LEVEL` plus an optional `JSONFormatter` (`LOG_FORMAT=json`).
Some modules still import the symbol; it resolves to `{}`. See `env-configuration.md`.

---

## The two "task" files (most common mix-up)

**`tasks.py`** — the runtime **`asyncio` task registry**: tracks and cancels long-running operations
(chat completions, background jobs), with optional Redis pub/sub so a task started on one instance can be
cancelled from any instance (`redis_task_command_listener`, `stop_task`). See `task-management.md`.

**`utils/task.py`** — prompt **templates** for automated features (title generation, tags, follow-ups,
query/RAG, autocomplete, MOA, tool calling). Does variable/temporal/user-context substitution
(`prompt_template`, `rag_template`). Nothing to do with `asyncio` tasks. See `task-templates.md`.

---

## Retrieval / RAG

**`ASYNC_VECTOR_DB_CLIENT`** — the **async** vector client used for runtime reads; an async wrapper over
the sync client. `retrieval/vector/async_client.py`. See `retrieval-utils.md`.

**`VECTOR_DB_CLIENT`** — the **sync** vector client, used only by a few blocking helpers (offloaded with
`asyncio.to_thread`). Not the runtime read path. See `retrieval-utils.md`.

**`VectorDBBase`** — the pluggable vector-backend interface. pgvector (`PgvectorClient`) is the documented
backend; chroma/milvus/qdrant/pinecone/weaviate/etc. are alternates behind the same interface. See
`vector-pgvector.md`.

**Hybrid search** — BM25 + vector retrieval combined in an `EnsembleRetriever` with RRF dedup, gated by
`ENABLE_RAG_HYBRID_SEARCH`; weights/top-k from `HYBRID_BM25_WEIGHT`/`TOP_K`/`TOP_K_RERANKER`. See
`retrieval-utils.md`, `end-to-end-query.md`.

**`RerankCompressor`** — neural reranking of candidates. The real work is in **`acompress_documents`**
(async); the sync `compress_documents` is a no-op. `retrieval/utils.py`. See `retrieval-utils.md`.

**`EMBEDDING_FUNCTION` / `RERANKING_FUNCTION` / `ef` / `rf`** — the embedding and reranking models on
`app.state`, built via `get_ef`/`get_rf`. Note the name is `RERANKING_FUNCTION`, **not**
`RERANKER_FUNCTION`. See `main-entrypoint.md`, `retrieval-utils.md`.

**`get_sources_from_items`** — the source collector that gathers content per item type (file, collection,
note, chat, url, text). The name `get_sources_from_files` does **not** exist. `retrieval/utils.py`. See
`end-to-end-query.md`.

**Vector collection names** — RAG chunks are stored in collections named `file-{id}`, knowledge-base ids,
and `web-search-{sha}`. See `end-to-end-query.md`, `vector-pgvector.md`.

**`filter_accessible_collections`** — enforces per-collection access before retrieval. `retrieval/utils.py`.
See `retrieval-utils.md`.

---

## Extensibility cluster (pipe / filter / function / tool / action / pipeline)

**Function** — an in-process plugin; the **current** extensibility mechanism. Three forms: Pipe, Filter,
Action. (Upstream product docs: Functions.)

**Pipe Function** — implements a custom provider/model or a custom request flow. Replaces a Pipelines
*pipe*. (Upstream: Pipe Function.)

**Filter Function** — message pre/post-processing via `inlet` (incoming) and `outlet` (outgoing). Replaces
a Pipelines *filter*. (Upstream: Filter Function.)

**Action Function** — adds a button/action under a message in the UI. (Upstream: Action Function.)

**Tool** — a callable the model can invoke during generation (function-calling). Distinct from a Function:
a Tool extends the *model's* capabilities; a Function extends the *pipeline*. (Upstream: Tools.)

**Pipelines** — **legacy**: an external worker container. Both its pipe and filter forms now have built-in
Function replacements. Do not build new features on Pipelines. (Upstream: Pipelines, marked legacy.)

---

## Real-time event names

**`events`** — the Socket.IO event carrying chat-completion streaming chunks. **Not** `chat-events`. See
`socket-realtime.md`, `end-to-end-query.md`.

**`events:channel` / `events:chat`** — the channel-mode listeners. **Not** `channel-events`. See
`socket-realtime.md`.

**`get_event_emitter`** — builds the per-request async emitter that does
`sio.emit("events", …, room="user:{id}")` per chunk. `socket/main.py`. See `socket-realtime.md`.

**Room `user:{id}`** — the per-user Socket.IO room; emitting once to it fans out to all of a user's
sessions. This is the mechanism that replaces the nonexistent `USER_POOL`. See `socket-realtime.md`.

---

## Persistence & access control

**Async engine / `AsyncSession`** — the runtime database path; all request/socket/model queries are
awaited against it. `internal/db.py`. See `sqlalchemy.md`.

**Sync engine / `ScopedSession`** — startup-only (Alembic migrations, import-time config, health checks,
some DDL). Not the runtime path. `internal/db.py`. See `database-infrastructure.md`.

**`JSONField`** — a SQLAlchemy `TypeDecorator` storing arbitrary Python objects as JSON text
(`UnicodeText`-backed). No Peewee `db_value`/`python_value` methods. `internal/db.py`. See
`database-infrastructure.md`.

**`run_migrations`** — runs Alembic `command.upgrade(cfg, "head")`, gated by `ENABLE_DB_MIGRATIONS`. Lives
in `config.py`, **not** `db.py`; Peewee is fully removed. See `DIRECTIVE_database_migration.md`,
`sqlalchemy.md`.

**`AccessGrants` / `has_access_to_file`** — the access-control model for chats/files/resources
(`AccessGrants.has_access(...)`, `has_access_to_file(...)`, `Knowledges.check_access_by_user_id`). Use these,
not ad-hoc checks. `models/access_grants.py`, `utils/access_control/files.py`. See `routers.md`,
`socket-realtime.md`.

---

## Concurrency

**`THREAD_POOL_SIZE`** — the AnyIO thread-limiter token count (a `config.py` `ConfigVar`). Bounds concurrent
**blocking, non-DB** work (LDAP, audio, reranking). See `threadpooling.md`.

**`DATABASE_POOL_SIZE`** — the async DB connection-pool size. **Independent** of `THREAD_POOL_SIZE`; runtime
DB access does not consume thread-limiter tokens. The old "keep `THREAD_POOL_SIZE ≥ DATABASE_POOL_SIZE`"
rule no longer applies. See `threadpooling.md`, `sqlalchemy.md`.

---

## Verification Recipe

```bash
# Pools and emitter (no USER_POOL; event is 'events')
grep -rn "SESSION_POOL\|USAGE_POOL\|def get_event_emitter\|sio.emit('events'" backend/open_webui/socket/main.py
grep -rn "USER_POOL\|chat-events\|channel-events" backend/open_webui/socket/main.py || echo "absent (expected)"
# RedisDict and the two task files
grep -rn "class RedisDict" backend/open_webui/socket/utils.py
grep -rn "def redis_task_command_listener" backend/open_webui/tasks.py
grep -rn "def prompt_template" backend/open_webui/utils/task.py
# Retrieval names
grep -rn "ASYNC_VECTOR_DB_CLIENT\|def get_sources_from_items" backend/open_webui/retrieval/utils.py
grep -rn "def get_sources_from_files" backend/open_webui/retrieval/utils.py || echo "no get_sources_from_files (expected)"
# Config/persistence
grep -rn "class AppConfig" backend/open_webui/internal/config.py
grep -rn "class JSONField" backend/open_webui/internal/db.py
grep -rn "def run_migrations" backend/open_webui/config.py
```
