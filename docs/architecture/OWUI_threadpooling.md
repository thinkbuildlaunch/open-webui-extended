---
# Machine-readable anchor block — see I.8.
covers_files:
  - backend/open_webui/config.py
  - backend/open_webui/main.py
  - backend/open_webui/routers/auths.py
  - backend/open_webui/routers/audio.py
  - backend/open_webui/retrieval/utils.py
  - backend/open_webui/retrieval/vector/dbs/pinecone.py
  - backend/open_webui/retrieval/loaders/youtube.py
  - backend/open_webui/models/users.py
covers_symbols:
  - { symbol: THREAD_POOL_SIZE, file: backend/open_webui/config.py }
  - { symbol: _resolve_ollama_base_url, file: backend/open_webui/config.py }
  - { symbol: lifespan, file: backend/open_webui/main.py }
  - { symbol: update_last_active_by_id, file: backend/open_webui/models/users.py }
  - { symbol: process_query_collection, file: backend/open_webui/retrieval/utils.py }
  - { symbol: PineconeClient, file: backend/open_webui/retrieval/vector/dbs/pinecone.py }
  - { symbol: aload, file: backend/open_webui/retrieval/loaders/youtube.py }
verified_against_commit: 304d2d673749691abad905b96230b30ddb77e145
---

# Thread Pooling

Open WebUI Extended is an async-first application built on FastAPI and asyncio. Thread
pools exist to run code from **genuinely blocking, synchronous libraries** off the event
loop: LDAP (`ldap3`), audio transcoding/transcription, reranking, blocking file/parsing
work, and a few vector-DB clients. This doc covers each mechanism, its configuration, and
how it interacts with other components.

> **Read this first — database access is NOT thread-pooled anymore.** Runtime DB access
> goes through the **async** SQLAlchemy engine and `AsyncSession`, awaited directly (see
> [sqlalchemy.md](./sqlalchemy.md)). It does **not** go through `asyncio.to_thread()`. A
> previous version of this doc claimed "every synchronous SQLAlchemy call from an async
> handler uses `asyncio.to_thread()`" and that the thread pool and DB pool are tightly
> coupled — **both statements are now false.** The AnyIO thread limiter bounds blocking
> non-DB work; DB concurrency is governed independently by the async engine's pool.

---

## Relevant Files

| File | Subject (grep for these symbols) |
|---|---|
| `backend/open_webui/config.py` | `THREAD_POOL_SIZE` definition/parse; `ThreadPoolExecutor(max_workers=2)` Ollama port check |
| `backend/open_webui/main.py` | `current_default_thread_limiter()` / `total_tokens` — AnyIO limiter setup in the lifespan |
| `backend/open_webui/routers/auths.py` | `asyncio.to_thread` for blocking `ldap3` bind/search |
| `backend/open_webui/routers/audio.py` | `asyncio.to_thread` for transcode/convert/compress/split + transcription pipeline |
| `backend/open_webui/retrieval/utils.py` | `ThreadPoolExecutor` (parallel collection queries) + `asyncio.to_thread` (reranking, bulk fetch) |
| `backend/open_webui/retrieval/vector/dbs/pinecone.py` | `ThreadPoolExecutor(max_workers=5)` (sync batch) + `run_in_executor` (async batch) |
| `backend/open_webui/retrieval/loaders/youtube.py` | `loop.run_in_executor(None, self.load)` |
| `backend/open_webui/models/users.py` | `@throttle(DATABASE_USER_ACTIVE_STATUS_UPDATE_INTERVAL)` on `update_last_active_by_id` |

Additional `asyncio.to_thread` call sites (blocking IO/parsing) live in
`retrieval/loaders/main.py`, `retrieval/vector/async_client.py`, `routers/files.py`,
`routers/knowledge.py`, `routers/retrieval.py`, `tools/builtin.py`, `utils/files.py`,
and `main.py` — enumerate them with the grep in the verification recipe rather than
trusting a fixed list here.

---

## Thread Pool Architecture

```
                    FastAPI / asyncio Event Loop
                              |
   +--------------------------+---------------------------+
   |                          |                           |
AnyIO thread limiter   Dedicated executors          Async I/O (no thread)
(global, configurable) (task-specific)              - async SQLAlchemy engine
   |                          |                       - redis.asyncio
   v                          v                       - aiohttp / httpx
asyncio.to_thread()    ThreadPoolExecutor /
- ldap3 bind/search      run_in_executor
- audio ffmpeg/whisper  - Pinecone sync batch (max_workers=5)
- reranking             - parallel vector queries (default workers)
- blocking file/parse   - Ollama port check (max_workers=2)
```

---

## 1. AnyIO Thread Limiter (global)

`asyncio.to_thread()` dispatches onto AnyIO's default worker thread pool, which is bounded
by a **capacity limiter** (a token semaphore). Each `to_thread()` call takes one token;
when all tokens are held, further calls wait.

**Configuration** — two halves:

- `THREAD_POOL_SIZE` is read and parsed in `config.py`: `os.getenv("THREAD_POOL_SIZE", None)`,
  coerced to `int` when set, falling back to `None` on a parse error.
- The lifespan in `main.py` applies it: when `THREAD_POOL_SIZE` is truthy and `> 0`, it
  sets `anyio.to_thread.current_default_thread_limiter().total_tokens = THREAD_POOL_SIZE`.

| `THREAD_POOL_SIZE` | Behavior |
|---|---|
| `None` (default) | AnyIO's built-in default limit (40 tokens at time of writing) is left unchanged |
| `0` | Falsy / not `> 0` → not applied; AnyIO default stays |
| `N > 0` | At most `N` concurrent `to_thread()` worker threads |

| Variable | Default | Description |
|---|---|---|
| `THREAD_POOL_SIZE` | `None` | Max concurrent `asyncio.to_thread()` workers. `None` ⇒ AnyIO default (≈40 at time of writing). |

---

## 2. `asyncio.to_thread()` — blocking non-DB work

The primary bridge for synchronous libraries. All calls share the AnyIO limiter above.
Representative sites (contracts, not transcriptions):

- **LDAP auth** (`routers/auths.py`): `ldap3` bind and search are blocking, so they run as
  `await asyncio.to_thread(connection_app.bind)` / `to_thread(... search ...)` /
  `to_thread(connection_user.bind)`.
- **Audio** (`routers/audio.py`): ffmpeg-style operations and the transcription pipeline
  are offloaded — e.g. `to_thread(transcode_audio_to_mp3, …)`, `to_thread(convert_audio_to_mp3, …)`,
  `to_thread(compress_audio, …)`, `to_thread(split_audio, …)`, and `to_thread(_run_pipeline)` /
  `to_thread(_run)`. (This replaces the old `ThreadPoolExecutor`-per-chunk approach the
  previous doc described.)
- **Retrieval** (`retrieval/utils.py`): reranking runs as
  `await asyncio.to_thread(self.reranking_function, query, documents)`, and the bulk
  collection fetch as `to_thread(get_all_items_from_collections, …)`.

> **Not** in this list anymore (the previous doc was stale): the socket event emitter,
> `routers/images.py`, and `routers/chats.py` no longer call `asyncio.to_thread()`. The
> emitter awaits async DB methods directly (verify: `grep -c to_thread backend/open_webui/socket/main.py`
> returns `0`).

---

## 3. Dedicated `ThreadPoolExecutor` Instances

A few subsystems create their own executor for task-specific parallelism, independent of
the AnyIO limiter.

- **Ollama port check** (`config.py`): `with ThreadPoolExecutor(max_workers=2) as pool:`
  probes the default Ollama port and a fallback port concurrently
  (`11434`, falling back to `12434`). Two workers because it is exactly two probes.
- **Parallel vector queries** (`retrieval/utils.py`): `with ThreadPoolExecutor() as executor:`
  (default worker count) fans out `process_query_collection` across every
  (query embedding × collection) pair and collects the futures. Independent per-collection
  queries that may hit different backends.
- **Pinecone batch upsert** (`retrieval/vector/dbs/pinecone.py`):
  `self._executor = ThreadPoolExecutor(max_workers=5)`.
  > **I.4/I.5 — describe the real wiring.** The 5-worker executor is used by the
  > **sync** batch path (`self._executor.submit(self.index.upsert, vectors=batch)`), and is
  > shut down via `self._executor.shutdown(wait=True)`. The 5 workers bound concurrent
  > batch submissions against the Pinecone client, which itself runs `pool_threads=20`
  > internally. Note the **async** batch path does *not* use `self._executor` — see §4.

---

## 4. `loop.run_in_executor()` Usage

`run_in_executor(None, fn)` schedules `fn` on the **default** executor (the same AnyIO-
managed pool that backs `to_thread`); passing an explicit executor uses that one instead.

- **YouTube loader** (`retrieval/loaders/youtube.py`): `await loop.run_in_executor(None, self.load)`
  — `None` ⇒ default executor.
- **Pinecone async batch** (`pinecone.py`): the async insert/upsert paths build
  `loop.run_in_executor(None, functools.partial(self.index.upsert, vectors=batch))` per
  batch and `await` them together. These use the **default** executor (`None`), *not*
  the 5-worker `self._executor` from §3 — a point the previous doc got wrong.

---

## Thread Pool Sizing Guidelines

> **I.6 — the old DB coupling no longer applies.** Because runtime DB access is
> async (it does not consume AnyIO tokens), the previous rule
> `THREAD_POOL_SIZE >= DATABASE_POOL_SIZE + DATABASE_POOL_MAX_OVERFLOW` is obsolete. Do not
> reintroduce it. The two pools are now independent:
> - The **AnyIO limiter** (`THREAD_POOL_SIZE`) bounds concurrent *blocking non-DB* work
>   (LDAP, audio, reranking, file/parse).
> - DB concurrency is bounded by the **async engine's pool** (`DATABASE_POOL_SIZE` /
>   `DATABASE_POOL_MAX_OVERFLOW`, or the async-SQLite default of 512 — see
>   [sqlalchemy.md](./sqlalchemy.md)).

Practical guidance:

- Leave `THREAD_POOL_SIZE` at its default unless you see contention on blocking work
  (LDAP logins stalling, audio transcription queuing).
- Size it to the expected concurrency of blocking operations, not to the DB pool.
- CPU-bound batches (audio, vector queries) already use dedicated executors, so they do
  not starve the shared limiter.

---

## Interaction with Other Components

- **SQLAlchemy** — runtime queries use the async engine + `AsyncSession`, awaited
  directly; they do not pass through `to_thread`. The sync engine and `to_thread` are
  unrelated paths. See [sqlalchemy.md](./sqlalchemy.md).
- **WebSockets** — the socket event emitter (`get_event_emitter` in `socket/main.py`)
  awaits async `Chats.*` methods during streaming; it consumes **no** thread tokens. See
  [heartbeats.md](./heartbeats.md).
- **Heartbeats** — the `heartbeat` handler `await`s `Users.update_last_active_by_id()`,
  which is `async` and decorated with `@throttle(DATABASE_USER_ACTIVE_STATUS_UPDATE_INTERVAL)`.
  It is **not** a synchronous call on the handler thread (a claim the previous doc made),
  and the throttle is enforced by the decorator, not by `to_thread`. See
  [heartbeats.md](./heartbeats.md).
- **Redis** — runtime Redis is `redis.asyncio` and consumes no thread tokens. The sync
  Redis client used by `RedisLock` / `RedisDict` (single-instance/startup paths) manages
  its own connection pool. See [redis.md](./redis.md).

---

## Debugging Thread Pool Issues

**Symptoms** of AnyIO limiter saturation: blocking operations (LDAP login, audio
transcription) queue and stall; `asyncio` slow-callback warnings; health endpoints fine
(they are async and do not depend on `to_thread`).

**Diagnosis:**
- Inspect the limit: log `anyio.to_thread.current_default_thread_limiter().total_tokens`.
- Live threads: `threading.active_count()`.
- DB pool (separate concern): `async_engine.pool.status()` for checked-out vs available
  async connections.
- `GLOBAL_LOG_LEVEL=DEBUG` for more detail.

**Mitigation:**
- Raise `THREAD_POOL_SIZE` when blocking *non-DB* work is the bottleneck.
- Raise `DATABASE_POOL_SIZE` when the async DB pool is the bottleneck (distinct from the
  thread limiter).
- Move heavy CPU-bound work onto a dedicated executor so it does not compete with the
  shared limiter.
- Throttle activity writes with `DATABASE_USER_ACTIVE_STATUS_UPDATE_INTERVAL`.

---

## Verification Recipe

Run from the repo root. If any line's expectation is violated, the doc is stale and must
be re-audited before it is trusted.

```bash
# THREAD_POOL_SIZE definition + AnyIO limiter application
grep -rn "THREAD_POOL_SIZE = os.getenv" backend/open_webui/config.py
grep -rn "current_default_thread_limiter\|total_tokens = THREAD_POOL_SIZE" backend/open_webui/main.py

# to_thread is for blocking NON-DB work; DB emitter no longer uses it
grep -rn "asyncio.to_thread" backend/open_webui/routers/auths.py backend/open_webui/routers/audio.py backend/open_webui/retrieval/utils.py
test "$(grep -c to_thread backend/open_webui/socket/main.py)" = 0 && echo "emitter has no to_thread (expected)"
test "$(grep -c to_thread backend/open_webui/routers/images.py)" = 0 && echo "images has no to_thread (expected)"
test "$(grep -c to_thread backend/open_webui/routers/chats.py)" = 0 && echo "chats has no to_thread (expected)"

# Dedicated executors
grep -rn "ThreadPoolExecutor(max_workers=2)" backend/open_webui/config.py
grep -rn "with ThreadPoolExecutor() as executor" backend/open_webui/retrieval/utils.py
grep -rn "ThreadPoolExecutor(max_workers=5)\|self._executor.submit\|pool_threads=20" backend/open_webui/retrieval/vector/dbs/pinecone.py

# run_in_executor uses the DEFAULT executor (None), not self._executor
grep -rn "run_in_executor(None" backend/open_webui/retrieval/loaders/youtube.py backend/open_webui/retrieval/vector/dbs/pinecone.py

# Heartbeat DB write is async + throttled (not a sync thread call)
grep -rn "@throttle(DATABASE_USER_ACTIVE_STATUS_UPDATE_INTERVAL)" backend/open_webui/models/users.py
grep -rn "async def update_last_active_by_id" backend/open_webui/models/users.py

# Enumerate every to_thread call site currently in the tree
grep -rln "asyncio.to_thread" backend/open_webui/
```
