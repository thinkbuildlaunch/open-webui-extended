# ThreadPooling

Open WebUI Extended is an async-first application built on FastAPI and asyncio. Since many operations (database queries, LDAP authentication, image generation, vector search) use synchronous libraries, the application bridges async and sync worlds through thread pools. This document covers all thread pool mechanisms, their configuration, and how they interact with other components.

---

## Relevant Files

| File | Purpose |
|---|---|
| `backend/open_webui/config.py` (lines 1786-1795) | `THREAD_POOL_SIZE` environment variable definition |
| `backend/open_webui/main.py` (lines 23, 644-646) | AnyIO thread limiter configuration at startup |
| `backend/open_webui/socket/main.py` (lines 804-860) | `asyncio.to_thread()` usage in event emitter for DB operations |
| `backend/open_webui/routers/auths.py` | `asyncio.to_thread()` for LDAP authentication |
| `backend/open_webui/routers/images.py` | `asyncio.to_thread()` for image generation API calls |
| `backend/open_webui/routers/chats.py` | `asyncio.to_thread()` for chat export processing |
| `backend/open_webui/retrieval/utils.py` | `ThreadPoolExecutor` for parallel vector DB queries and reranking |
| `backend/open_webui/retrieval/vector/dbs/pinecone.py` | `ThreadPoolExecutor(max_workers=5)` for batch upsert |
| `backend/open_webui/routers/audio.py` | `ThreadPoolExecutor` for parallel audio transcription |
| `backend/open_webui/retrieval/loaders/youtube.py` | `loop.run_in_executor()` for YouTube content loading |

---

## Thread Pool Architecture

```
                    FastAPI / asyncio Event Loop
                              |
         +--------------------+--------------------+
         |                    |                    |
   AnyIO Thread Limiter  Dedicated Executors   Event Loop Tasks
   (global, configurable)  (task-specific)     (pure async)
         |                    |
         v                    v
   asyncio.to_thread()   ThreadPoolExecutor
   - DB queries           - Pinecone (5 workers)
   - LDAP auth            - Audio transcription
   - Image gen            - Vector DB queries
   - Chat export          - Ollama port check (2 workers)
   - Reranking
```

---

## 1. AnyIO Thread Limiter (Global)

### Configuration

```python
# config.py
THREAD_POOL_SIZE = os.getenv("THREAD_POOL_SIZE", None)

# main.py (during lifespan startup)
if THREAD_POOL_SIZE and THREAD_POOL_SIZE > 0:
    limiter = anyio.to_thread.current_default_thread_limiter()
    limiter.total_tokens = THREAD_POOL_SIZE
```

### How It Works

AnyIO provides a **capacity limiter** (token-based semaphore) that governs how many threads can be active concurrently for `asyncio.to_thread()` calls. Each call consumes one "token"; when all tokens are in use, subsequent calls wait.

| Setting | Behavior |
|---|---|
| `THREAD_POOL_SIZE=None` | AnyIO default (~40 threads) |
| `THREAD_POOL_SIZE=0` | Not applied (stays at default) |
| `THREAD_POOL_SIZE=N` | Maximum N concurrent `to_thread()` calls |

### Environment Variable

| Variable | Default | Description |
|---|---|---|
| `THREAD_POOL_SIZE` | `None` | Maximum concurrent threads for `asyncio.to_thread()`. When `None`, AnyIO uses its default limit (typically 40). |

---

## 2. `asyncio.to_thread()` Usage

This is the primary mechanism for running synchronous code from async handlers. All calls go through the AnyIO thread limiter.

### In Socket Event Emitter (`socket/main.py`)

The `get_event_emitter()` function creates an async emitter that persists chat data to the database during streaming:

```python
async def __event_emitter__(event_data):
    # Emit to WebSocket (async, immediate)
    await sio.emit("events", {...}, room=f"user:{user_id}")

    # Persist to database (sync, via thread pool)
    if event_type == "status":
        await asyncio.to_thread(
            Chats.add_message_status_to_chat_by_id_and_message_id,
            chat_id, message_id, event_data.get("data", {})
        )
    elif event_type == "message":
        message = await asyncio.to_thread(
            Chats.get_message_by_id_and_message_id, chat_id, message_id
        )
        content = message.get("content", "") + event_data.get("data", {}).get("content", "")
        await asyncio.to_thread(
            Chats.upsert_message_to_chat_by_id_and_message_id,
            chat_id, message_id, {"content": content}
        )
    # ... similar patterns for "replace", "embeds", "files", "source", "citation"
```

### In Authentication (`routers/auths.py`)

LDAP authentication uses blocking `ldap3` library calls:

```python
# LDAP bind and search are blocking operations
result = await asyncio.to_thread(ldap_connection_function, ...)
```

### In Image Generation (`routers/images.py`)

HTTP requests to external image generation APIs (DALL-E, Stable Diffusion) are blocking:

```python
response = await asyncio.to_thread(requests.post, url, json=payload, headers=headers)
```

### In Chat Export (`routers/chats.py`)

Chat data export processing:

```python
result = await asyncio.to_thread(export_function, ...)
```

### In Retrieval (`retrieval/utils.py`)

Reranking operations:

```python
result = await asyncio.to_thread(rerank_function, query, documents)
```

---

## 3. Dedicated `ThreadPoolExecutor` Instances

Some subsystems create their own `ThreadPoolExecutor` for task-specific parallelism. These are **independent** of the AnyIO thread limiter.

### Pinecone Vector DB (`retrieval/vector/dbs/pinecone.py`)

```python
self._executor = concurrent.futures.ThreadPoolExecutor(max_workers=5)
```

**Used for**:
- Batch upsert operations: `executor.submit(upsert_batch, ...)`
- Async wrappers: `loop.run_in_executor(self._executor, sync_function)`

**Why dedicated**: Pinecone gRPC client also uses `pool_threads=20` internally. The 5-worker executor serializes batch submissions to avoid overwhelming the Pinecone API.

### Audio Transcription (`routers/audio.py`)

```python
with ThreadPoolExecutor() as executor:
    futures = [executor.submit(transcribe_chunk, chunk) for chunk in audio_chunks]
    results = [f.result() for f in futures]
```

**Why dedicated**: Audio chunks are CPU-intensive and independent. Default worker count (CPU count * 5) allows maximum parallelism.

### Vector DB Queries (`retrieval/utils.py`)

```python
with ThreadPoolExecutor() as executor:
    futures = [executor.submit(query_collection, collection) for collection in collections]
    results = [f.result() for f in futures]
```

**Why dedicated**: Multiple vector collections are queried in parallel. Each query is independent and may hit different backends.

### Ollama Port Check (`config.py`)

```python
executor = ThreadPoolExecutor(max_workers=2)
# Check if Ollama ports are reachable
```

**Why dedicated**: Small, bounded check with minimal workers needed.

---

## 4. `loop.run_in_executor()` Usage

An older pattern that's equivalent to `asyncio.to_thread()` but allows specifying a custom executor:

### Pinecone Async Operations

```python
loop = asyncio.get_event_loop()
result = await loop.run_in_executor(self._executor, sync_insert_function, data)
```

### YouTube Content Loading

```python
loop = asyncio.get_event_loop()
result = await loop.run_in_executor(None, youtube_loader.load)  # None = default executor
```

When `None` is passed as the executor, it uses the default `ThreadPoolExecutor` (same pool governed by AnyIO in modern Python, but separate from the AnyIO limiter for explicit executor usage).

---

## Thread Pool Sizing Guidelines

### Relationship to Database Pool

The thread pool and database connection pool are tightly coupled:

```
Request arrives (async)
  -> asyncio.to_thread(db_operation)     # Consumes 1 AnyIO thread token
    -> SessionLocal()                     # Checks out 1 DB connection from QueuePool
    -> execute query
    -> session.close()                    # Returns DB connection to pool
  -> Thread token released
```

**Key constraint**: If `THREAD_POOL_SIZE > DATABASE_POOL_SIZE + DATABASE_POOL_MAX_OVERFLOW`, some threads will block waiting for a database connection. Conversely, if `THREAD_POOL_SIZE < DATABASE_POOL_SIZE`, the database pool is underutilized.

**Recommendation**:
```
THREAD_POOL_SIZE >= DATABASE_POOL_SIZE + DATABASE_POOL_MAX_OVERFLOW
```

### Sizing Examples

| Deployment | THREAD_POOL_SIZE | DATABASE_POOL_SIZE | DATABASE_POOL_MAX_OVERFLOW | Notes |
|---|---|---|---|---|
| Development | `None` (default ~40) | `None` (default) | `0` | Works out of the box |
| Small production | `20` | `10` | `5` | Allows headroom for non-DB threads |
| Large production | `100` | `50` | `20` | High concurrency, PostgreSQL recommended |
| SQLite | `None` | N/A (NullPool) | N/A | No pooling for SQLite; threads create/close connections |

---

## Interaction with Other Components

### ThreadPooling + SQLAlchemy

Every synchronous SQLAlchemy call from an async handler uses `asyncio.to_thread()`. The `SessionLocal` factory creates a new session per call, and `scoped_session` ensures thread-local isolation:

```python
# Async handler
async def handle_event():
    result = await asyncio.to_thread(Users.get_user_by_id, user_id)
    # Users.get_user_by_id internally:
    #   with get_db() as db:
    #       return db.get(User, id)
```

### ThreadPooling + WebSockets

The event emitter is the highest-throughput consumer of thread pool tokens. During active chat streaming, each message chunk may trigger multiple `to_thread()` calls for database persistence:

```
Chat stream chunk arrives
  -> emit to WebSocket (async, no thread)
  -> asyncio.to_thread(Chats.get_message_by_id_and_message_id)  # Thread 1
  -> asyncio.to_thread(Chats.upsert_message_to_chat_by_id_and_message_id)  # Thread 2
```

With many concurrent chat sessions, thread pool exhaustion is the primary bottleneck.

### ThreadPooling + Heartbeats

Each heartbeat triggers a database update:

```python
# In heartbeat handler
Users.update_last_active_by_id(user["id"])  # Synchronous DB call
```

This runs on the calling thread (the Socket.IO event handler thread), not via `asyncio.to_thread()`. The `DATABASE_USER_ACTIVE_STATUS_UPDATE_INTERVAL` env variable can throttle this to reduce DB load.

### ThreadPooling + Redis

Redis operations are inherently async (using `redis.asyncio`) and do **not** consume thread pool tokens. Only synchronous Redis operations (via `RedisLock` and sync `RedisDict`) use the sync Redis client, which manages its own connection pool.

---

## Debugging Thread Pool Issues

### Symptoms of Thread Pool Exhaustion

- Requests hang or timeout without error
- Database queries that normally take milliseconds take seconds
- `asyncio` warnings about slow callbacks
- Health check endpoints stop responding (if they use `to_thread()`)

### Diagnosis

1. **Check current pool size**: Log `anyio.to_thread.current_default_thread_limiter().total_tokens`
2. **Monitor active threads**: `threading.active_count()` in a health endpoint
3. **Database pool stats**: `engine.pool.status()` shows checked-out vs. available connections
4. **Increase logging**: Set `GLOBAL_LOG_LEVEL=DEBUG` to see thread pool contention

### Mitigation

1. **Increase `THREAD_POOL_SIZE`**: Most direct solution
2. **Increase `DATABASE_POOL_SIZE`**: If threads are blocking on DB connections
3. **Reduce DB calls**: Enable `DATABASE_ENABLE_SESSION_SHARING` to reuse sessions
4. **Throttle heartbeat DB updates**: Set `DATABASE_USER_ACTIVE_STATUS_UPDATE_INTERVAL`
5. **Use dedicated executors**: For CPU-intensive work (audio, vector queries) so they don't compete with DB threads
