---
# Machine-readable anchor block — see the documentation standard, I.8.
# This is the top-level INDEX / OVERVIEW. It is deliberately broad and shallow:
# per-component facts, symbol-level detail, and the falsifiable verification recipes
# live in the linked component docs below, each of which carries its own anchor block
# and its own `verified_against_commit`. The pin here reflects the infrastructure
# cluster this index was last reconciled against; linked docs span a range of commits
# (their anchor blocks are the source of truth). The "Codebase Map" section is derived
# from a provided directory snapshot plus the linked docs — see "Coverage & Verification".
covers_files:
  - backend/open_webui/__init__.py
  - backend/open_webui/main.py
  - backend/open_webui/env.py
  - backend/open_webui/config.py
  - backend/open_webui/internal/db.py
  - backend/open_webui/internal/config.py
  - backend/open_webui/tasks.py
  - backend/open_webui/socket/main.py
  - backend/open_webui/retrieval/utils.py
  - backend/open_webui/utils/redis.py
covers_symbols:
  - { symbol: lifespan, file: backend/open_webui/main.py }
  - { symbol: get_async_db_context, file: backend/open_webui/internal/db.py }
  - { symbol: THREAD_POOL_SIZE, file: backend/open_webui/config.py }
  - { symbol: SESSION_POOL_TIMEOUT, file: backend/open_webui/socket/main.py }
verified_against_commit: 304d2d673749691abad905b96230b30ddb77e145
---

# Open WebUI Extended — Backend Architecture Overview

This is the **map** for the Open WebUI Extended backend: a single place to see how the
codebase is organized, which subsystem owns what, and which component doc to open next.
It is the index that the per-component docs hang off of. Each component named here links to
a dedicated doc that carries the symbol-level facts and a `grep`-based verification recipe.

The backend is an **async-first** FastAPI + Socket.IO application. It runs as a single
instance with no external dependencies, or as a horizontally scaled multi-instance
deployment backed by Redis and PostgreSQL. The same code paths serve both; the difference is
*where shared state lives*, not *what the code does*.

## How to use this document

- **Orienting in the codebase?** Read "Architectural Layers" then "Codebase Map".
- **Tracing one request end-to-end?** Jump to [end-to-end-query.md](./end-to-end-query.md);
  the call path is summarized in "Request Lifecycle" below.
- **Touching a specific subsystem?** Find it in "Components at a Glance", open its doc, and
  trust that doc's anchor block + verification recipe over this overview.
- **Before assuming anything subtle**, read "Cross-Cutting Invariants" — the handful of
  load-bearing facts (async DB, no `USER_POOL`, `env.py` vs `config.py`, …) that every
  component doc reasserts and that older guides got wrong.

---

## Architectural Layers

The backend divides cleanly into eight layers. Most live under `backend/open_webui/`; the
rendering layer lives in the SvelteKit frontend under `src/`.

| # | Layer | What it does | Component docs |
|---|---|---|---|
| 1 | **Process & app bootstrap** | Launch the process, configure env/secrets, assemble the FastAPI app, run startup/shutdown | [cli-entrypoint](./cli-entrypoint.md), [main-entrypoint](./main-entrypoint.md), [env-configuration](./env-configuration.md) |
| 2 | **API / routing surface** | REST endpoints for chats, files, retrieval, and the feature domains | [routers](./routers.md), [main-entrypoint](./main-entrypoint.md) |
| 3 | **Chat / request pipeline** | Build context, inject prompts, route to a provider, stream the reply | [end-to-end-query](./end-to-end-query.md), [payload-transformation](./payload-transformation.md), [task-templates](./task-templates.md) |
| 4 | **Retrieval / RAG** | Hybrid vector + BM25 search, embeddings, reranking, access-filtered sources | [retrieval-utils](./retrieval-utils.md), [vector-pgvector](./vector-pgvector.md) |
| 5 | **Real-time layer** | Socket.IO streaming, presence/heartbeats, channels, collaborative editing | [websockets](./websockets.md), [socket-realtime](./socket-realtime.md), [heartbeats](./heartbeats.md) |
| 6 | **Persistence** | SQLAlchemy ORM, dual sync/async engines, Alembic migrations, the model layer | [sqlalchemy](./sqlalchemy.md), [database-infrastructure](./database-infrastructure.md) |
| 7 | **Shared state & coordination** | Redis-backed pools/locks/pub-sub, HA failover, task cancellation, the thread limiter | [redis](./redis.md), [redis-sentinels](./redis-sentinels.md), [task-management](./task-management.md), [threadpooling](./threadpooling.md) |
| 8 | **Frontend rendering** | Markdown, code, math, diagrams, and sandboxed artifacts in the browser | [frontend-rendering](./frontend-rendering.md) |

---

## Components at a Glance

Every component doc, grouped by layer. "Key files" lists the primary anchors; each doc's own
anchor block is exhaustive.

### Bootstrap & configuration
| Component | Purpose | Key files |
|---|---|---|
| [CLI Entry Point](./cli-entrypoint.md) | The `open-webui` Typer CLI (`serve`/`dev`): secret-key generation, optional CUDA wiring, uvicorn launch | `backend/open_webui/__init__.py` |
| [Application Entrypoint](./main-entrypoint.md) | FastAPI app assembly: `app.state`, ASGI middleware stack, the feature routers, `/ws` mount, `lifespan`, the model/chat/config/health endpoints | `backend/open_webui/main.py`, `backend/open_webui/utils/asgi_middleware.py` |
| [Environment Configuration](./env-configuration.md) | `env.py` startup/infra settings (paths, device, logging, DB/Redis/WebSocket wiring, secrets) — read once at import; distinct from `config.py` user-facing `ConfigVar`s | `backend/open_webui/env.py`, `backend/open_webui/config.py`, `backend/open_webui/internal/config.py` |

### API / routing
| Component | Purpose | Key files |
|---|---|---|
| [Routers](./routers.md) | The REST surface for chats, files, retrieval/RAG, and utility ops; shared access control, real-time events, and the async vector client | `backend/open_webui/routers/chats.py`, `…/files.py`, `…/retrieval.py`, `…/utils.py` |

### Chat / request pipeline
| Component | Purpose | Key files |
|---|---|---|
| [End-to-End Query](./end-to-end-query.md) | The synthesis/integration trace — one chat request from browser → RAG → orchestration → provider → streamed reply | `backend/open_webui/utils/chat.py`, `…/utils/middleware.py` |
| [Payload Transformation](./payload-transformation.md) | Adapts internal OpenAI-shaped bodies to each provider (system-prompt injection, param casting, OpenAI⇄Ollama conversion) | `backend/open_webui/utils/payload.py` |
| [Task Templates](./task-templates.md) | Prompt builders for automated "task" features (title, tags, follow-ups, RAG, autocomplete, MOA, tool calling); variable + temporal + user-context substitution | `backend/open_webui/utils/task.py` |

### Retrieval / RAG
| Component | Purpose | Key files |
|---|---|---|
| [Retrieval Utilities](./retrieval-utils.md) | The RAG core: gather sources by item type, vector/BM25/hybrid search, embeddings, neural reranking, per-collection access control | `backend/open_webui/retrieval/utils.py`, `…/retrieval/vector/async_client.py` |
| [Vector DB: pgvector](./vector-pgvector.md) | The pgvector backend behind the pluggable `VectorDBBase` interface: cosine search, IVFFLAT/HNSW indexing, optional pgcrypto encryption | `backend/open_webui/retrieval/vector/main.py`, `…/vector/dbs/pgvector.py` |

### Real-time
| Component | Purpose | Key files |
|---|---|---|
| [WebSockets](./websockets.md) | Socket.IO server/client, event/room model, channels, collaborative editing, the upgrade guard | `backend/open_webui/socket/main.py`, `src/routes/+layout.svelte` |
| [Real-Time Communication](./socket-realtime.md) | Socket internals: session/presence state, the `events` emitter, channel emitters, CRDT (Yjs) handlers (merge candidate with WebSockets) | `backend/open_webui/socket/main.py`, `…/socket/utils.py` |
| [Heartbeats](./heartbeats.md) | Three-layer liveness: Engine.IO ping/pong, app heartbeat, server-side session reaping with distributed locks | `backend/open_webui/socket/main.py`, `…/models/users.py` |

### Persistence
| Component | Purpose | Key files |
|---|---|---|
| [SQLAlchemy](./sqlalchemy.md) | ORM + dual-engine architecture, pooling, session lifecycle, Alembic migrations, the declarative model layer | `backend/open_webui/internal/db.py`, `…/migrations/`, `…/models/` |
| [Database Infrastructure](./database-infrastructure.md) | `internal/db.py` engine construction: `Base`, `JSONField`, sync + async engines, SSL/URL handling (merge candidate with SQLAlchemy) | `backend/open_webui/internal/db.py` |

### Shared state & coordination
| Component | Purpose | Key files |
|---|---|---|
| [Redis](./redis.md) | Central shared-state/messaging backbone: connection factory + cache, `RedisDict`/`RedisLock`/`YdocManager`, pub/sub, rate limiting, token revocation | `backend/open_webui/utils/redis.py`, `…/socket/utils.py`, `…/tasks.py` |
| [Redis Sentinels](./redis-sentinels.md) | High availability: `SentinelRedisProxy` transparently re-resolves the master and retries on failover | `backend/open_webui/utils/redis.py` |
| [Task Management](./task-management.md) | `tasks.py` runtime registry that tracks/cancels long-running `asyncio` operations, with optional Redis pub/sub for cross-instance cancellation | `backend/open_webui/tasks.py` |
| [Thread Pooling](./threadpooling.md) | The AnyIO thread limiter / `ThreadPoolExecutor` for genuinely blocking **non-DB** work (LDAP, audio, reranking) | `backend/open_webui/main.py`, `…/config.py` |

### Frontend
| Component | Purpose | Key files |
|---|---|---|
| [Frontend Rendering](./frontend-rendering.md) | How the browser renders model output: markdown, runnable code, KaTeX, Mermaid/Vega, and CSP-sandboxed artifacts | `src/lib/components/chat/Artifacts.svelte`, `…/Messages/CodeBlock.svelte`, `src/lib/utils/csp.ts` |

---

## Codebase Map

Directory structure of `backend/open_webui/`, grouped by concern and annotated with the
doc that owns each area. Large fan-outs (migration revisions, vector backends, web-search
providers) are summarized by count rather than transcribed. See "Coverage & Verification"
for the snapshot caveat.

```
backend/open_webui/
├── __init__.py            # Typer CLI: serve / dev          -> cli-entrypoint
├── main.py                # FastAPI app assembly + lifespan  -> main-entrypoint
├── env.py                 # startup/infra env (read-at-import)-> env-configuration
├── config.py              # user-facing ConfigVars (DB-backed)-> env-configuration / redis
├── internal/config.py     # AppConfig (live values ↔ Redis)  -> redis / env-configuration
├── tasks.py               # asyncio task registry + pub/sub   -> task-management
├── constants.py  functions.py
│
├── internal/db.py         # Base, JSONField, sync+async engines -> database-infrastructure / sqlalchemy
├── migrations/            # Alembic env + revision history       -> sqlalchemy
│   ├── env.py  util.py
│   └── versions/...
├── models/                # declarative ORM modules, one per     -> sqlalchemy / DATA_MODEL.md
│   │                      #   domain entity (identity, chat,
│   │                      #   knowledge, files, access_grants,
│   │                      #   notes, channels, + Extended features)
│
├── retrieval/
│   ├── utils.py           # RAG core: sources, hybrid search   -> retrieval-utils
│   ├── vector/
│   │   ├── async_client.py# ASYNC_VECTOR_DB_CLIENT wrapper      -> retrieval-utils
│   │   ├── main.py        # VectorDBBase, SearchResult          -> vector-pgvector
│   │   ├── factory.py  type.py  utils.py
│   │   └── dbs/           # 15 backends (pgvector documented;    -> vector-pgvector (pgvector)
│   │                      #   chroma, milvus, qdrant, pinecone, weaviate, …)   [others: see Coverage]
│   ├── loaders/           # 9 document loaders (mineru, mistral, youtube, …)   [see Coverage]
│   ├── models/            # rerankers (base_reranker, colbert, external)       [see Coverage]
│   └── web/               # ~33 web-search providers (brave, exa, searxng, …)  [see Coverage]
│
├── routers/               # ~22 feature routers                -> routers (chats/files/retrieval/utils)
│   │                      #   documented: chats, files, retrieval, utils
│   └── (configs, models, groups, users, prompts, tools, functions, images,
│        notes, folders, memories, tasks, terminals, pipelines, scim,
│        analytics, evaluations, automations, calendar, skills — mostly undocumented)
│
├── socket/
│   ├── main.py            # Socket.IO server, emitters, pools   -> websockets / socket-realtime / heartbeats
│   └── utils.py           # RedisDict, RedisLock, YdocManager   -> redis
│
├── utils/
│   ├── chat.py            # generate_chat_completion (orchestrator) -> end-to-end-query
│   ├── middleware.py      # process_chat_payload / _response        -> end-to-end-query
│   ├── payload.py         # provider payload adaptation             -> payload-transformation
│   ├── task.py            # prompt templates                        -> task-templates
│   ├── redis.py           # connection factory + Sentinel proxy     -> redis / redis-sentinels
│   ├── asgi_middleware.py # Auth/CommitSession/Redirect/WS-guard    -> main-entrypoint / websockets
│   ├── auth.py  rate_limit.py                                       -> redis
│   ├── access_control/    # has_access_to_file, AccessGrants checks -> routers / socket-realtime
│   ├── telemetry/         # OpenTelemetry setup + instrumentors     [see Coverage]
│   ├── mcp/client.py      # MCP client                              [see Coverage]
│   ├── images/comfyui.py  code_interpreter.py  embeddings.py  …     [see Coverage]
│   └── (misc, headers, response, sanitize, security_headers, webhook, …)
│
├── storage/provider.py    # file storage backends                   [see Coverage]
└── tools/                 # built-in tools (knowledge_fs)            [see Coverage]
```

---

## System Architecture Diagram

```
 Browser (SvelteKit + TypeScript frontend)        -> frontend-rendering
    |  REST: POST /api/chat/completions            Socket.IO: /ws (JWT in handshake)
    |  Heartbeat every ~30s                        events / events:channel / events:chat
    v                                              ^
 ============================ FastAPI + Socket.IO ASGI app =============================
   ASGI middleware (outer→inner): CORS · WS-upgrade guard · AuthToken · CommitSession ·
                                  SecurityHeaders · Redirect · Compress      -> main-entrypoint
    |
    |  POST /api/chat/completions  ->  chat_completion (main.py)
    |        |
    |        +-- process_chat_payload  ----------------------------+         -> end-to-end-query
    |        |     build context, features, RAG                    |
    |        |        +-- get_sources_from_items                   |         -> retrieval-utils
    |        |              filter_accessible_collections          |
    |        |              query_collection/doc_with_hybrid_search|
    |        |                 (BM25 + vector, RRF, RerankCompressor)
    |        |                    |                                |
    |        |                    v  ASYNC_VECTOR_DB_CLIENT        |         -> vector-pgvector
    |        |              pgvector / chroma / qdrant / …  (pluggable)
    |        |
    |        +-- generate_chat_completion (utils/chat.py)  -- route by model
    |        |     apply_system_prompt_to_body / param casting     |         -> payload-transformation
    |        |     -> ollama | openai-compatible | pipeline | direct          -> task-templates
    |        |
    |        +-- process_chat_response  -- stream                  |
    |              get_event_emitter -> sio.emit("events", room="user:{id}") -> websockets / socket-realtime
    |
    +-- async SQLAlchemy engine (PostgreSQL / SQLite)  (awaited directly — NOT thread-pooled)  -> sqlalchemy
    |        +-- QueuePool / NullPool                                                          -> database-infrastructure
    |
    +-- ThreadPoolExecutor / AnyIO thread limiter   (blocking NON-DB work: LDAP, audio, rerank) -> threadpooling
    |
    +-- Redis (standalone / Sentinel / Cluster)                                                 -> redis / redis-sentinels
             +-- SESSION_POOL · USAGE_POOL · MODELS         (RedisDict hashes)
             +-- Pub/Sub: task commands · Socket.IO cross-instance fan-out
             +-- Distributed locks (cleanup coordination)  · Yjs doc updates
             +-- Rate-limit buckets · token revocation · session persistence · AppConfig
```

---

## Request Lifecycle

The canonical, verified trace lives in [end-to-end-query.md](./end-to-end-query.md). Condensed
call path for a successful RAG-grounded chat (real function names; routes simplified):

```
POST /api/chat/completions                # main.chat_completion
  process_chat_payload                    # utils/middleware: build context
    get_sources_from_items                # retrieval/utils
      filter_accessible_collections
      query_collection_with_hybrid_search -> query_doc_with_hybrid_search
        RerankCompressor.acompress_documents     # score / sort / threshold / top_n
  generate_chat_completion                # utils/chat: route by model
    routers.openai.generate_chat_completion
      apply_system_prompt_to_body / payload transform / (Azure) convert_to_azure_payload
  process_chat_response                   # utils/middleware: stream
    get_event_emitter -> sio.emit("events", ..., room="user:{id}")   # per chunk
```

---

## Cross-Cutting Invariants

These hold across the whole backend and are the facts older guides most often got wrong. If
code or a description seems to contradict one of these, re-verify before trusting it.

- **Async-first runtime.** The request and socket paths are `async` end-to-end. Genuinely
  blocking, synchronous work (LDAP, audio, reranking, a few vector clients) is offloaded with
  `asyncio.to_thread` / `ThreadPoolExecutor` under the AnyIO limiter. See
  [threadpooling.md](./threadpooling.md).
- **Database access is NOT thread-pooled.** Runtime queries use the **async** SQLAlchemy
  engine + `AsyncSession`, awaited directly. DB concurrency is bounded by the engine's own
  pool (`DATABASE_POOL_SIZE`/overflow), independently of `THREAD_POOL_SIZE`. The sync engine
  is startup-only (migrations, import-time config). See [sqlalchemy.md](./sqlalchemy.md).
- **`env.py` ≠ `config.py`.** `env.py` holds plain, read-at-import infra settings (paths,
  DB/Redis/WebSocket wiring, secrets, logging). The much larger catalog of user-facing
  settings (AI providers, RAG, OAuth, web search, most feature flags) lives in `config.py` as
  DB-backed `ConfigVar`s, editable from the Admin UI via `AppConfig`. See
  [env-configuration.md](./env-configuration.md).
- **There is no `USER_POOL`.** The pools are `SESSION_POOL`, `USAGE_POOL`, and `MODELS`.
  Per-user fan-out uses a Socket.IO **room** (`user:{id}`); the streaming event is **`events`**
  (channels use `events:channel` / `events:chat`). See [socket-realtime.md](./socket-realtime.md).
- **Vector reads go through `ASYNC_VECTOR_DB_CLIENT`**, an async wrapper over the sync
  `VECTOR_DB_CLIENT`. The store is pluggable behind `VectorDBBase`; pgvector is the documented
  backend. See [retrieval-utils.md](./retrieval-utils.md) / [vector-pgvector.md](./vector-pgvector.md).
- **State location is the single/multi-instance difference.** The same code runs both ways;
  with Redis configured, the pools/locks/task-registry move from in-process Python objects to
  Redis hashes and pub/sub.

---

## Single-Instance vs. Multi-Instance Deployment

### Single-Instance (default)
- No Redis required.
- `SESSION_POOL`, `USAGE_POOL`, `MODELS` are plain Python dicts.
- Task management uses local `asyncio.Task` tracking.
- Cleanup locks are no-ops (`lambda: True`).
- SQLite works fine with `NullPool`.

### Multi-Instance (production)
- **Required**: `REDIS_URL` set, `WEBSOCKET_MANAGER=redis`.
- All shared state moves to Redis hashes.
- Socket.IO events broadcast via Redis pub/sub.
- Distributed locks coordinate cleanup across instances.
- Task cancellation propagates via pub/sub.
- PostgreSQL recommended with `QueuePool`.
- `THREAD_POOL_SIZE` and `DATABASE_POOL_SIZE` tuned per instance, against their own workloads.

---

## How the Components Interact

#### 0. The chat pipeline ties layers 2–7 together

A chat request flows API → pipeline → retrieval → provider → real-time, touching persistence
and Redis throughout: `chat_completion` calls `process_chat_payload` (which invokes RAG via
`get_sources_from_items` over `ASYNC_VECTOR_DB_CLIENT`), then `generate_chat_completion`
(payload transform + provider routing), then `process_chat_response`, which streams each chunk
out through the socket emitter to the `user:{id}` room. DB writes along the way are awaited
async `Chats.*` calls. Full trace: [end-to-end-query.md](./end-to-end-query.md).

#### 1. WebSockets + Redis (distributed real-time)

When `WEBSOCKET_MANAGER=redis`, Socket.IO uses `AsyncRedisManager` for cross-instance event
broadcasting. All connected clients across all server instances receive events through Redis
pub/sub. `SESSION_POOL`, `USAGE_POOL`, and `MODELS` are backed by Redis hashes (`RedisDict`),
visible to every instance.

```
Instance A receives WebSocket event
  -> Socket.IO AsyncRedisManager publishes to Redis
  -> Redis fans out to all subscribers
  -> Instance B receives and delivers to its local clients
```

#### 2. Heartbeats + WebSockets + Redis (liveness detection)

Three layers:
1. **Engine.IO ping/pong** (transport): server pings every ~25s; client must answer within
   ~20s. Detects dead TCP connections.
2. **Application heartbeat** (client-initiated): client emits a `heartbeat` event every ~30s;
   server refreshes `SESSION_POOL[sid].last_seen_at`.
3. **Session reaping** (server-side cleanup): a background task scans `SESSION_POOL` (~120s);
   sessions without a heartbeat past the timeout are reaped, under a `RedisLock` so only one
   instance performs cleanup.

#### 3. WebSockets + SQLAlchemy (async DB writes from socket events)

Socket handlers that write to the DB use the **async** engine and `await` async model methods
directly — there is no `asyncio.to_thread()` bridge:

```python
# In get_event_emitter (socket/main.py)
await Chats.upsert_message_to_chat_by_id_and_message_id(
    chat_id, message_id, {"content": content}
)
```

DB concurrency is bounded by the async engine's pool, independently of the AnyIO thread
limiter. See [threadpooling.md](./threadpooling.md) and [sqlalchemy.md](./sqlalchemy.md).

#### 4. Redis + SQLAlchemy (complementary persistence)

| Concern | Redis | SQLAlchemy |
|---|---|---|
| Session state (who is online) | `SESSION_POOL` hash | `Users.last_active_at` column |
| Chat messages | Streaming via pub/sub | Permanent storage |
| Configuration | `AppConfig` live values | Migration-managed schema |
| Rate limiting | Rolling window buckets | N/A |
| Token revocation | TTL-based keys | N/A |
| Collaborative docs | Yjs update lists | Note content on save |

#### 5. Redis Sentinels + all Redis consumers

With Sentinel configured, every Redis consumer (Socket.IO manager, `RedisDict`, `RedisLock`,
`YdocManager`, rate limiter, task system) transparently benefits from automatic failover via
`SentinelRedisProxy`, which intercepts each command and retries on `ConnectionError` /
`ReadOnlyError`. See [redis-sentinels.md](./redis-sentinels.md).

#### 6. ThreadPooling vs. SQLAlchemy (two independent pools)

```
THREAD_POOL_SIZE    -->  max concurrent BLOCKING non-DB calls (LDAP, audio, reranking)
DATABASE_POOL_SIZE  -->  max concurrent async DB connections
```

The older rule "keep `THREAD_POOL_SIZE >= DATABASE_POOL_SIZE + overflow`" no longer applies:
DB calls do not flow through the thread limiter. Tune each pool against its own workload.

---

## Environment Variable Quick Reference

Infrastructure variables parsed in `env.py`. This is **not** the full settings catalog —
most user-facing options (AI providers, RAG, OAuth, web search, audio/image, feature flags)
are `config.py` `ConfigVar`s, DB-backed and Admin-UI editable; see
[env-configuration.md](./env-configuration.md) and the official
[Environment Variable reference](https://docs.openwebui.com/reference/env-configuration/).

### Redis
| Variable | Default | Description |
|---|---|---|
| `REDIS_URL` | `""` | Redis connection string (e.g., `redis://localhost:6379/0`) |
| `REDIS_CLUSTER` | `False` | Enable Redis Cluster mode |
| `REDIS_KEY_PREFIX` | `open-webui` | Namespace prefix for all Redis keys |

### Redis Sentinel
| Variable | Default | Description |
|---|---|---|
| `REDIS_SENTINEL_HOSTS` | `""` | Comma-separated sentinel hostnames |
| `REDIS_SENTINEL_PORT` | `26379` | Sentinel port |
| `REDIS_SENTINEL_MAX_RETRY_COUNT` | `2` | Failover retry attempts |
| `REDIS_RECONNECT_DELAY` | `None` | Delay between retries (ms) |
| `REDIS_SOCKET_CONNECT_TIMEOUT` | `None` | Connection timeout (seconds) |

### WebSocket
| Variable | Default | Description |
|---|---|---|
| `ENABLE_WEBSOCKET_SUPPORT` | `True` | Enable WebSocket transport |
| `WEBSOCKET_MANAGER` | `""` | Set to `redis` for multi-instance |
| `WEBSOCKET_REDIS_URL` | `REDIS_URL` | Separate Redis for WebSocket layer |
| `WEBSOCKET_SERVER_PING_INTERVAL` | `25` | Engine.IO ping interval (seconds) |
| `WEBSOCKET_SERVER_PING_TIMEOUT` | `20` | Engine.IO ping timeout (seconds) |
| `WEBSOCKET_REDIS_LOCK_TIMEOUT` | `60` | Distributed lock TTL (seconds) |

### Database
| Variable | Default | Description |
|---|---|---|
| `DATABASE_URL` | `sqlite:///data/webui.db` | SQLAlchemy connection string |
| `DATABASE_POOL_SIZE` | `None` | Connection pool size (`>0` QueuePool, `0` NullPool, unset library default) |
| `DATABASE_POOL_MAX_OVERFLOW` | `0` | Extra connections above pool_size |
| `DATABASE_POOL_TIMEOUT` | `30` | Wait time for connection (seconds) |
| `DATABASE_POOL_RECYCLE` | `3600` | Connection lifetime (seconds) |

### Thread Pool
| Variable | Default | Description |
|---|---|---|
| `THREAD_POOL_SIZE` | `None` | AnyIO thread limiter token count (unset → AnyIO default, ~40) |

> Defaults shown are the fallbacks at time of writing; treat the symbols in `env.py` /
> `config.py` as the source of truth.

---

## Graceful Degradation

The system degrades gracefully when components are unavailable:

- **No Redis** — falls back to in-memory dicts for session/usage pools, local task tracking,
  in-memory rate limiting. Single-instance only.
- **No PostgreSQL** — SQLite with `NullPool` is the default. No connection pooling, but
  functional.
- **No WebSocket support** — falls back to HTTP long-polling transport via Socket.IO.
- **No thread pool configured** — AnyIO uses its default thread limiter (typically ~40
  threads).

---

## Coverage & Verification

What this map does and does not assert.

- **Aggregate counts are intentionally omitted.** Per `DOCUMENTATION_STANDARD.md` III.4, volatile
  quantities (router/model/migration counts, LOC, token tiers) live only in the dated `FILE_TREE.md`,
  not in prose. This map names subsystems qualitatively and defers the numbers there.
- **Per-component facts are deferred.** Symbol-level claims, "what changed since the original
  guide" corrections, and `grep`-based verification recipes live in the linked component docs.
  Each carries its own `verified_against_commit`; those pins span a range of commits and are
  the source of truth. This index's own pin (`304d2d67…`) reflects the infrastructure cluster
  it was last reconciled against, not a fresh whole-repo verification.
- **The Codebase Map is derived from a provided directory snapshot.** That snapshot is
  faithful for the directories and files it lists, but it is **partial**: several modules the
  component docs cover and pin — notably `routers/chats.py`, `routers/retrieval.py`,
  `routers/openai.py`, `routers/ollama.py`, `routers/audio.py`, `routers/auths.py`, and
  `routers/channels.py` — are referenced by their docs but do not appear in the snapshot's
  `routers/` listing. They are treated as authoritative from the docs. Before relying on the
  map as exhaustive, regenerate it from the repo root.
- **Documented vs. undocumented areas.** The 19 component docs cover the bootstrap, request
  pipeline, RAG core + pgvector, real-time layer, persistence, shared-state/coordination, and
  rendering. Areas present in the tree but **not yet given a dedicated doc** include: the
  non-core feature routers (`configs`, `models`, `groups`, `users`, `prompts`, `tools`,
  `functions`, `images`, `notes`, `folders`, `memories`, `tasks`, `terminals`, `pipelines`,
  `scim`, plus the Extended `analytics`, `evaluations`, `automations`, `calendar`, `skills`);
  the non-pgvector vector backends (chroma, milvus, qdrant, pinecone, weaviate, opensearch,
  elasticsearch, oracle23ai, opengauss, mariadb_vector, s3vector, valkey); the document
  `loaders/` and ~33 web-search providers under `retrieval/web/`; `utils/telemetry/`,
  `utils/mcp/`, `utils/code_interpreter.py`, `storage/provider.py`, and `tools/`. These are
  candidates for future component docs.

---

## Further Reading

Grouped by layer; each doc carries its own anchor block and verification recipe.

**Bootstrap & configuration**
- [cli-entrypoint.md](./cli-entrypoint.md) — `open-webui` CLI: `serve`/`dev`, secret key, CUDA, uvicorn launch.
- [main-entrypoint.md](./main-entrypoint.md) — FastAPI assembly: `app.state`, middleware, routers, `lifespan`.
- [env-configuration.md](./env-configuration.md) — `env.py` infra settings, logging; `env.py` vs `config.py`.

**API / routing**
- [routers.md](./routers.md) — chats, files, retrieval, utils routers; access control + async vector ops.

**Chat / request pipeline**
- [end-to-end-query.md](./end-to-end-query.md) — the full browser→provider→stream synthesis trace.
- [payload-transformation.md](./payload-transformation.md) — provider payload adaptation (OpenAI/Ollama).
- [task-templates.md](./task-templates.md) — prompt builders for automated task features.

**Retrieval / RAG**
- [retrieval-utils.md](./retrieval-utils.md) — RAG core: sources, hybrid search, embeddings, reranking, access.
- [vector-pgvector.md](./vector-pgvector.md) — pgvector backend + the `VectorDBBase` interface.

**Real-time**
- [websockets.md](./websockets.md) — Socket.IO setup, events, rooms, collaborative editing.
- [socket-realtime.md](./socket-realtime.md) — socket internals: emitters, channels, Yjs handlers.
- [heartbeats.md](./heartbeats.md) — liveness detection, session reaping, cleanup coordination.

**Persistence**
- [sqlalchemy.md](./sqlalchemy.md) — engines, models, migrations, connection pooling.
- [database-infrastructure.md](./database-infrastructure.md) — `internal/db.py` engine construction.

**Shared state & coordination**
- [redis.md](./redis.md) — connection management, key patterns, pub/sub, caching.
- [redis-sentinels.md](./redis-sentinels.md) — high availability, failover proxy, configuration.
- [task-management.md](./task-management.md) — the `asyncio` task registry + cross-instance cancellation.
- [threadpooling.md](./threadpooling.md) — AnyIO limiter, `ThreadPoolExecutor`, async bridging.

**Frontend**
- [frontend-rendering.md](./frontend-rendering.md) — markdown, code, math, diagrams, sandboxed artifacts.
