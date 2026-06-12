---
# Machine-readable anchor block — see I.8 / Part II.
covers_files:
  - backend/open_webui/utils/redis.py
  - backend/open_webui/env.py
  - backend/open_webui/socket/main.py
covers_symbols:
  - { symbol: SentinelRedisProxy, file: backend/open_webui/utils/redis.py }
  - { symbol: _resolve_master, file: backend/open_webui/utils/redis.py }
  - { symbol: _should_retry, file: backend/open_webui/utils/redis.py }
  - { symbol: _FACTORY_METHODS, file: backend/open_webui/utils/redis.py }
  - { symbol: get_redis_connection, file: backend/open_webui/utils/redis.py }
  - { symbol: _build_sentinel, file: backend/open_webui/utils/redis.py }
  - { symbol: build_sentinel_url, file: backend/open_webui/utils/redis.py }
  - { symbol: get_sentinels_from_env, file: backend/open_webui/utils/redis.py }
  - { symbol: REDIS_SENTINEL_MAX_RETRY_COUNT, file: backend/open_webui/env.py }
  - { symbol: REDIS_SENTINEL_HOSTS, file: backend/open_webui/env.py }
verified_against_commit: 1d341b84029243b73fd086c384ba5b1513ab4e56
---

# Redis Sentinels

Redis Sentinel provides automatic failover and high availability for Redis in Open WebUI
Extended. When configured, the application transparently handles master re-resolution and
connection retries on failover, without callers having to know a failover occurred.

---

## Relevant Files

| File | Subject (grep for these symbols) |
|---|---|
| `backend/open_webui/utils/redis.py` | `SentinelRedisProxy`, `_resolve_master`, `_should_retry`, `_FACTORY_METHODS`, `get_redis_connection`, `_build_sentinel`, `build_sentinel_url`, `parse_redis_url` (aliased `parse_redis_service_url`), `get_sentinels_from_env` |
| `backend/open_webui/env.py` | `REDIS_SENTINEL_HOSTS`, `REDIS_SENTINEL_PORT`, `REDIS_SENTINEL_MAX_RETRY_COUNT`, `REDIS_RECONNECT_DELAY`, `REDIS_SOCKET_CONNECT_TIMEOUT`, `WEBSOCKET_SENTINEL_HOSTS`, `WEBSOCKET_SENTINEL_PORT` |
| `backend/open_webui/socket/main.py` | Socket.IO manager URL via `build_sentinel_url` (module-level, no function anchor — informational) |

> **No Sentinel test module exists at time of writing.** There is no
> `backend/open_webui/test/` directory and no `test_*redis*` file anywhere in the tree
> (`find . -name 'test_*redis*'` is empty). A prior version of this doc described a
> `backend/open_webui/test/util/test_redis.py` "comprehensive test suite" — it does not
> exist. Per I.3, confirm with the root-level `find` before re-adding any such
> reference.

---

## How Sentinel Works in This Codebase

```
                   Redis Sentinel Cluster
              +--------+  +--------+  +--------+
              | Sent-1 |  | Sent-2 |  | Sent-3 |
              +--------+  +--------+  +--------+
                   \           |           /
                    +----------+----------+
                          |          |
                     +--------+  +---------+
                     | Master |  | Replica |
                     +--------+  +---------+
                          ^
                          |  SentinelRedisProxy (re-resolves master + retries)
                          |
          +---------------+----------------+
          |               |                |
    SESSION_POOL     Task Pub/Sub     Rate Limiter
    (RedisDict)      (tasks.py)       (rate_limit.py)
```

**Connection establishment** — `get_redis_connection()` takes the Sentinel path whenever
its `redis_sentinels` argument is non-empty (it has precedence over cluster/standalone).
The steps, all in `utils/redis.py`:

1. `get_sentinels_from_env(hosts_csv, port)` turns `"sentinel1,sentinel2,sentinel3"` +
   port into `[("sentinel1", 26379), …]`.
2. `_build_sentinel(...)` parses the Redis URL with `parse_redis_url()` (alias
   `parse_redis_service_url`) to get `service` / `port` / `db` / `username` / `password`,
   constructs a `redis(.asyncio).sentinel.Sentinel(...)` (async vs sync chosen by
   `async_mode`), and wraps it: `SentinelRedisProxy(sentinel, cfg["service"], async_mode=…)`.

> **Contract, not a copy.** `_build_sentinel` passes `socket_connect_timeout` and the
> other configured socket options through to the `Sentinel`, and the service name comes
> from the **hostname** of `REDIS_URL` (default `mymaster`) — not a separate setting.

---

## `SentinelRedisProxy` (`utils/redis.py`)

The proxy is the transparent-failover mechanism. It wraps a `Sentinel` and intercepts
attribute access (Redis commands) through `__getattr__` to add retry logic.

**Construction** (the real signature — grep it): `__init__(self, sentinel, service_name, *, async_mode=True)`.
It stores `_sentinel`, `_service_name`, and `_async_mode`. There is **no** `**kw` / `_kw`
and **no** `_master()` method; master resolution is `_resolve_master()`, which returns
`self._sentinel.master_for(self._service_name)` with no extra kwargs.

**`__getattr__` flow** for `proxy.<name>(...)`:

1. Resolve the current master (`self._sentinel.master_for(self._service_name)`) and read
   `original = getattr(master, name)`.
2. If `original` is not callable, or `name` is in `_FACTORY_METHODS`
   (`{pipeline, pubsub, monitor, client, transaction}` at time of writing), return it
   **unwrapped** — factory/handle objects are passed straight through.
3. Otherwise return a retry wrapper: `_wrap_sync(name)` in sync mode, else `_wrap_async(name, original)`.

**Retry logic** (sync and async share the shape):

- The loop runs `for attempt in range(REDIS_SENTINEL_MAX_RETRY_COUNT)`.
- Only `_SENTINEL_RETRYABLE = (redis.exceptions.ConnectionError, redis.exceptions.ReadOnlyError)`
  is caught — `ConnectionError` (master unreachable) and `ReadOnlyError` (the old master was
  demoted to a replica).
- `_should_retry(attempt)` is `attempt < REDIS_SENTINEL_MAX_RETRY_COUNT - 1`. While it holds:
  `_log_retry()` emits a debug line, the proxy sleeps `REDIS_RECONNECT_DELAY / 1000` seconds
  **only if** `REDIS_RECONNECT_DELAY` is set, and the loop re-runs — each iteration
  re-resolves the master, so Sentinel returns the freshly-promoted one.
- When retries are exhausted, `_log_exhausted()` runs and the exception is re-raised.

> **Exact log wording (I.5 — don't paraphrase from memory).** `_log_retry` formats
> `'Sentinel failover (%s) — retry %d/%d'` with the exception class name, `attempt + 1`, and
> `REDIS_SENTINEL_MAX_RETRY_COUNT` — e.g. `Sentinel failover (ConnectionError) — retry 1/2`.
> It is **not** `"Redis sentinel fail-over (…). Retry 1/2"`.

**Async vs sync wrappers.** In async mode, `_wrap_async` dispatches by callable kind:
`_wrap_async_gen` for async-generator methods (e.g. `scan_iter`) and `_wrap_async_call`
for regular coroutine methods; `_wrap_async_call` `await`s the result when
`inspect.iscoroutine(result)` is true and returns it otherwise. Sync mode uses `_wrap_sync`,
which calls the method and returns directly. Both use the same retry/backoff loop above.

---

## URL Construction for Socket.IO

Socket.IO's `AsyncRedisManager` needs a `redis+sentinel://` URL, built by **`build_sentinel_url(base_url, hosts_csv, port)`** (there is no `get_sentinel_url_from_env`).
It returns `f"redis+sentinel://{auth}{nodes}/{db}/{service}"`, e.g.
`redis+sentinel://user:pass@sentinel1:26379,sentinel2:26379/0/mymaster`.

In `socket/main.py` (module-level, under `if WEBSOCKET_MANAGER == "redis"`):

```python
ws_redis_url = (
    build_sentinel_url(WEBSOCKET_REDIS_URL, sentinel_hosts, WEBSOCKET_SENTINEL_PORT)
    if sentinel_hosts else WEBSOCKET_REDIS_URL
)
redis_manager = socketio.AsyncRedisManager(ws_redis_url, redis_options=WEBSOCKET_REDIS_OPTIONS)
```

(Illustrative — the variable is `redis_manager`/`ws_redis_url`; grep `build_sentinel_url`
in `socket/main.py`.)

---

## `parse_redis_url()` / `parse_redis_service_url()` (`utils/redis.py`)

`parse_redis_service_url` is a module-level alias of `parse_redis_url`. It extracts the
Sentinel-relevant parameters from a Redis URL:

- Input `redis://user:pass@mymaster:6379/2` → `{service: "mymaster", port: 6379, db: 2, username: "user", password: "pass"}`.
- The **hostname** becomes the Sentinel `service` name (default `mymaster`).
- Accepts `redis://` and `rediss://` (TLS); rejects other schemes with `ValueError`.
- `port` defaults to `6379`, `db` to `0`.

---

## Environment Variables

Defaults are the fallbacks in `env.py` **at time of writing**; the symbols are the source
of truth.

| Variable | Default | Description |
|---|---|---|
| `REDIS_SENTINEL_HOSTS` | `""` | Comma-separated sentinel hostnames; when set, enables Sentinel mode (e.g. `sentinel1,sentinel2,sentinel3`) |
| `REDIS_SENTINEL_PORT` | `26379` | Port shared by all sentinel instances |
| `REDIS_SENTINEL_MAX_RETRY_COUNT` | `2` | Total attempts per command during failover; a value `< 1` is **reset to `2`** (not clamped to 1) |
| `REDIS_RECONNECT_DELAY` | `None` | Delay between retries in **milliseconds** (slept as `value / 1000` s); `None` ⇒ retry immediately |
| `REDIS_SOCKET_CONNECT_TIMEOUT` | `None` | TCP connect timeout (seconds, float), applied to the Sentinel |
| `REDIS_URL` | `""` | Source of the Sentinel `service` name, credentials, port, and db (hostname ⇒ service, default `mymaster`) |

### WebSocket-specific Sentinel variables

| Variable | Default | Description |
|---|---|---|
| `WEBSOCKET_SENTINEL_HOSTS` | `""` | Separate sentinel hosts for the WebSocket Redis |
| `WEBSOCKET_SENTINEL_PORT` | `26379` | Sentinel port for the WebSocket Redis |

---

## Configuration Examples

```env
# Minimal
REDIS_URL=redis://mymaster:6379/0
REDIS_SENTINEL_HOSTS=sentinel1,sentinel2,sentinel3
REDIS_SENTINEL_PORT=26379

# With auth: put credentials in REDIS_URL
REDIS_URL=redis://username:password@mymaster:6379/0

# Tuned failover
REDIS_SENTINEL_MAX_RETRY_COUNT=5
REDIS_RECONNECT_DELAY=500          # ms
REDIS_SOCKET_CONNECT_TIMEOUT=5.0   # seconds

# Separate Sentinel for the WebSocket layer
WEBSOCKET_MANAGER=redis
WEBSOCKET_REDIS_URL=redis://ws-master:6379/0
WEBSOCKET_SENTINEL_HOSTS=ws-sentinel1,ws-sentinel2,ws-sentinel3
WEBSOCKET_SENTINEL_PORT=26379
```

---

## Failover Sequence

1. The Redis master goes down; Sentinel (server-side) promotes a replica.
2. The application issues a Redis command through `SentinelRedisProxy`.
3. The wrapper catches `ConnectionError` or `ReadOnlyError`.
4. `_log_retry()` logs `Sentinel failover (<ExceptionName>) — retry n/N`.
5. If `REDIS_RECONNECT_DELAY` is set, it sleeps `REDIS_RECONNECT_DELAY / 1000` s.
6. The loop re-runs: `_resolve_master()` asks Sentinel for the new master, and the command
   is retried against it.
7. This repeats while `_should_retry(attempt)` holds (up to `REDIS_SENTINEL_MAX_RETRY_COUNT`
   total attempts); if still failing, the exception is re-raised to the caller.

---

## Verification Recipe

Run from the repo root. If any line's expectation is violated, the doc is stale and must
be re-audited. Symbol resolution for the manual `git log -L` checks uses the overrides in
`docs/DOCUMENTATION_STANDARD.md`.

```bash
# Proxy + real method/field names (NOT _master / **kw / get_sentinel_url_from_env)
grep -rn "class SentinelRedisProxy\|def _resolve_master\|def _should_retry\|_FACTORY_METHODS = " backend/open_webui/utils/redis.py
grep -rn "service_name" backend/open_webui/utils/redis.py
grep -rn "def _master\|self._kw\|get_sentinel_url_from_env" backend/open_webui/utils/redis.py || echo "absent (expected)"

# Exact retry log wording
grep -rn "Sentinel failover (%s) — retry %d/%d" backend/open_webui/utils/redis.py

# Retryable exceptions + factory passthrough set
grep -rn "_SENTINEL_RETRYABLE\|ConnectionError\|ReadOnlyError" backend/open_webui/utils/redis.py
grep -rn "pipeline.*pubsub.*monitor.*client.*transaction" backend/open_webui/utils/redis.py

# URL builder is build_sentinel_url, used by the Socket.IO manager
grep -rn "def build_sentinel_url\|redis+sentinel://" backend/open_webui/utils/redis.py
grep -rn "build_sentinel_url\|AsyncRedisManager" backend/open_webui/socket/main.py

# parse helper + its alias
grep -rn "def parse_redis_url\|parse_redis_service_url = parse_redis_url" backend/open_webui/utils/redis.py

# Env var: <1 resets to 2 (not min 1)
grep -rn "REDIS_SENTINEL_MAX_RETRY_COUNT" backend/open_webui/env.py

# Sentinel test module does NOT exist (I.3 — prove absence from root)
find . -name 'test_*redis*' -not -path './node_modules/*'   # expected: no output
ls backend/open_webui/test 2>/dev/null || echo "no backend/open_webui/test dir (expected)"
```
