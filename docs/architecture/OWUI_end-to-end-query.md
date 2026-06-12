---
# Machine-readable anchor block — see I.8 / Part II.
covers_files:
  - backend/open_webui/retrieval/utils.py
  - backend/open_webui/utils/chat.py
  - backend/open_webui/utils/middleware.py
  - backend/open_webui/utils/payload.py
  - backend/open_webui/routers/openai.py
  - backend/open_webui/socket/main.py
covers_symbols:
  - { symbol: get_sources_from_items, file: backend/open_webui/retrieval/utils.py }
  - { symbol: query_doc_with_hybrid_search, file: backend/open_webui/retrieval/utils.py }
  - { symbol: query_collection_with_hybrid_search, file: backend/open_webui/retrieval/utils.py }
  - { symbol: RerankCompressor, file: backend/open_webui/retrieval/utils.py }
  - { symbol: generate_chat_completion, file: backend/open_webui/utils/chat.py }
  - { symbol: process_chat_payload, file: backend/open_webui/utils/middleware.py }
  - { symbol: process_chat_response, file: backend/open_webui/utils/middleware.py }
  - { symbol: apply_system_prompt_to_body, file: backend/open_webui/utils/payload.py }
  - { symbol: convert_to_azure_payload, file: backend/open_webui/routers/openai.py }
  - { symbol: get_event_emitter, file: backend/open_webui/socket/main.py }
verified_against_commit: 72729457031e86809ccc4dc469684b5014e92bbb
---

# End-to-End Query Walkthrough

A technical trace of one chat request from the browser through RAG retrieval, the chat
orchestrator, provider routing, and the streamed real-time response. This is the **integration
/ synthesis** doc; each stage links to the component doc that covers it in depth.

> **What changed since the original guide (it was very stale).** The pipeline is now
> **async end-to-end**. Key corrections:
> - The source collector is **`get_sources_from_items`** (the original's `get_sources_from_files`
>   does not exist); runtime vector reads use **`ASYNC_VECTOR_DB_CLIENT`**.
> - `RerankCompressor`'s real work is in **`acompress_documents`** (async) — `compress_documents`
>   is a no-op; reranking runs via `asyncio.to_thread`.
> - **There is no `USER_POOL`** and no `user-list`/`chat-events`/`channel-events` socket events.
>   Pools are `SESSION_POOL`/`USAGE_POOL`/`MODELS`; per-user fan-out uses the `user:{id}` room;
>   the streaming event is **`events`**. The frontend socket lives in `src/routes/+layout.svelte`
>   (not `src/lib/utils/websocket.ts`).
> - System-prompt injection is **`apply_system_prompt_to_body`** (async; renamed from
>   `apply_model_system_prompt_to_body`).
> - `app.state` holds `RERANKING_FUNCTION` (not `RERANKER_FUNCTION`), `EMBEDDING_FUNCTION`,
>   `MODELS`, `ef`/`rf`; resources are set in the **`lifespan`** context manager, not
>   `@app.on_event("startup")`.

---

## 1. Overview

A query flows: **browser → `/api/chat/completions` → `process_chat_payload` (RAG + features) →
`generate_chat_completion` (routing) → provider router → streamed back via `process_chat_response`
+ the Socket.IO `events` channel**. RAG grounds the prompt with hybrid (vector + BM25) search
over pgvector; Redis backs cross-instance state and the socket manager.

Component map:
[routers.md](./routers.md) (endpoints) · [retrieval-utils.md](./retrieval-utils.md) (RAG) ·
[payload-transformation.md](./payload-transformation.md) (provider payloads) ·
[websockets.md](./websockets.md) / [socket-realtime.md](./socket-realtime.md) (streaming) ·
[redis.md](./redis.md) · [sqlalchemy.md](./sqlalchemy.md) · [vector-pgvector.md](./vector-pgvector.md) ·
[threadpooling.md](./threadpooling.md) · [main-entrypoint.md](./main-entrypoint.md).

## 2. Hybrid Retrieval

`process_chat_payload` (`utils/middleware.py`) assembles context. For attached files/knowledge it
calls **`get_sources_from_items`** (`retrieval/utils.py`), which — per item type (file, collection,
note, chat, url, text) — gathers full content or runs chunked search, **after**
`filter_accessible_collections` enforces per-collection access. Chunked search uses:

- **`query_collection_with_hybrid_search`** — prefetches each collection concurrently
  (`asyncio.gather` over `ASYNC_VECTOR_DB_CLIENT.get`), then per (collection × query) runs:
- **`query_doc_with_hybrid_search`** — a `BM25Retriever` (optionally over enriched texts) + a
  `VectorSearchRetriever` combined in an `EnsembleRetriever` (RRF dedup by `CHUNK_HASH_KEY`),
  wrapped in `RerankCompressor` + `ContextualCompressionRetriever`, awaited via `.ainvoke`.

Hybrid vs. pure-vector is gated by `ENABLE_RAG_HYBRID_SEARCH`; weights/top-k come from
`HYBRID_BM25_WEIGHT`/`TOP_K`/`TOP_K_RERANKER`/`RELEVANCE_THRESHOLD`. See
[retrieval-utils.md](./retrieval-utils.md).

## 3. Reranking (`RerankCompressor`)

`RerankCompressor.acompress_documents` (async) scores candidates: with a reranking function it
runs `await asyncio.to_thread(self.reranking_function, query, documents)`; otherwise it falls back
to cosine similarity over query/document embeddings. It filters by `r_score`, sorts desc, keeps
`top_n`, and writes each score into `metadata["score"]`. (The sync `compress_documents` returns
`[]`; the reranking function — built by `get_reranking_function` — is what assembles the
`(query, page_content)` pairs, so the original's in-compressor `predict([...])` is obsolete.)

## 4. Chat Orchestration & Provider Routing

**`generate_chat_completion`** (`utils/chat.py`) is the central orchestrator: it validates the
model against `request.app.state.MODELS`, resolves base-model overrides, applies model params and
the system prompt, enforces access (non-admin users go through model access checks), and routes:

- direct connection → `generate_direct_chat_completion`
- pipeline/function model → `generate_function_chat_completion`
- Ollama → `generate_ollama_chat_completion`
- OpenAI-compatible → the `routers/openai.py` `generate_chat_completion`

The **OpenAI router** resolves the endpoint index (`urlIdx`) and per-endpoint
`OPENAI_API_CONFIGS` (prefix stripping, custom headers, multi-key), awaits
**`apply_system_prompt_to_body(system, payload, metadata, user)`**, transforms the payload (o-series
handling, `max_completion_tokens` vs `max_tokens`, logit_bias), and for Azure rewrites the request
via **`convert_to_azure_payload`** (adds `api-key`/`api-version`). Provider-payload shaping (OpenAI
casts, Ollama options, system-prompt expansion) is in [payload-transformation.md](./payload-transformation.md)
and [task-templates.md](./task-templates.md).

## 5. Streaming Response & Real-Time Delivery

**`process_chat_response`** (`utils/middleware.py`) drives the streamed reply. It launches a
background task (`create_task`) whose handler iterates `async for chunk in response.body_iterator`,
emitting incremental updates through the async emitter from **`get_event_emitter`**
(`socket/main.py`): `await sio.emit("events", {chat_id, message_id, data}, room=f"user:{user_id}")`
— one emit to the user's room (Socket.IO fans out to all their sessions), **not** a manual loop
over a `USER_POOL`. DB writes (`status`/`message`/`replace`/…) are awaited async `Chats.*` calls.

On the client, `setupSocket` in `src/routes/+layout.svelte` connects to `/ws/socket.io` (JWT in the
handshake) and applies these `events`. See [websockets.md](./websockets.md) (handlers, channel-mode
emitter) and [heartbeats.md](./heartbeats.md) (presence). Tool/code-interpreter steps and feature
handlers (`chat_web_search_handler`, `chat_completion_files_handler`) run as awaited sub-routines.

## 6. System Integration

- **Database** — runtime queries use the **async** SQLAlchemy engine + `AsyncSession`; the sync
  engine is startup-only. Pooling is `QueuePool`/`NullPool`/library-default by `DATABASE_POOL_SIZE`
  (no "PgBouncer mode"). `JSONField` stores nested JSON. See [sqlalchemy.md](./sqlalchemy.md) /
  [database-infrastructure.md](./database-infrastructure.md).
- **Vector store** — pgvector via `ASYNC_VECTOR_DB_CLIENT` (an async wrapper over the sync
  `VECTOR_DB_CLIENT`); collections `file-{id}`, knowledge-base ids, `web-search-{sha}`. See
  [vector-pgvector.md](./vector-pgvector.md).
- **Redis & real-time** — `SESSION_POOL`/`USAGE_POOL`/`MODELS` (`RedisDict` in multi-instance),
  pub/sub task control, the `AsyncRedisManager` socket fan-out, and distributed cleanup locks. See
  [redis.md](./redis.md) / [socket-realtime.md](./socket-realtime.md).
- **AsyncIO & threads** — the pipeline is `async`; genuinely blocking work (reranking, audio, LDAP,
  some collection reads) is offloaded with `asyncio.to_thread` / `ThreadPoolExecutor` under the
  AnyIO limiter. See [threadpooling.md](./threadpooling.md).
- **`request.app.state`** — the shared resource hub initialized in the `lifespan` context manager:
  `config` (`AppConfig`), `MODELS`/`BASE_MODELS`, `EMBEDDING_FUNCTION`/`RERANKING_FUNCTION`/`ef`/`rf`,
  `redis`, OAuth managers, tool/terminal servers. See [main-entrypoint.md](./main-entrypoint.md).

## 7. Illustrative Trace (function-level)

A successful RAG query touches, in order (real function names; log strings vary):

```
POST /api/chat/completions        # routers... -> main.chat_completion
  process_chat_payload            # middleware: build context
    get_sources_from_items        # retrieval/utils
      filter_accessible_collections
      query_collection_with_hybrid_search -> query_doc_with_hybrid_search
        RerankCompressor.acompress_documents   # score/sort/threshold/top_n
  generate_chat_completion        # utils/chat: route by model
    routers.openai.generate_chat_completion
      apply_system_prompt_to_body / payload transform / convert_to_azure_payload (Azure)
  process_chat_response           # middleware: stream
    get_event_emitter -> sio.emit("events", ..., room="user:{id}")  # per chunk
```

---

## Verification Recipe

Run from the repo root. Symbol resolution for manual `git log -L` uses the overrides in
`docs/DOCUMENTATION_STANDARD.md`.

```bash
# Retrieval is async; the collector is get_sources_from_items (not _files)
grep -rn "async def get_sources_from_items\|async def query_doc_with_hybrid_search\|async def query_collection_with_hybrid_search\|ASYNC_VECTOR_DB_CLIENT" backend/open_webui/retrieval/utils.py | head
grep -rn "def get_sources_from_files" backend/open_webui/retrieval/utils.py || echo "no get_sources_from_files (expected)"

# RerankCompressor: real logic in acompress_documents
grep -rn "class RerankCompressor\|async def acompress_documents" backend/open_webui/retrieval/utils.py

# Orchestrator + middleware + provider router
grep -rn "async def generate_chat_completion" backend/open_webui/utils/chat.py
grep -rn "async def process_chat_payload\|async def process_chat_response" backend/open_webui/utils/middleware.py
grep -rn "def convert_to_azure_payload\|await apply_system_prompt_to_body" backend/open_webui/routers/openai.py

# Streaming via 'events' to the user room (no USER_POOL); system prompt renamed
grep -rn "def get_event_emitter\|sio.emit('events'" backend/open_webui/socket/main.py
grep -rn "USER_POOL\|chat-events\|user-list" backend/open_webui/socket/main.py || echo "no USER_POOL/chat-events/user-list (expected)"
grep -rn "async def apply_system_prompt_to_body" backend/open_webui/utils/payload.py

# app.state names + lifespan
grep -rn "app.state.RERANKING_FUNCTION\|app.state.EMBEDDING_FUNCTION\|async def lifespan" backend/open_webui/main.py | head
```
