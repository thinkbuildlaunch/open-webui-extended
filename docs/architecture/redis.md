---
# Machine-readable anchor block — see Directive 8.
covers_files:
  - backend/open_webui/utils/redis.py
  - backend/open_webui/socket/utils.py
  - backend/open_webui/socket/main.py
  - backend/open_webui/tasks.py
  - backend/open_webui/internal/config.py
  - backend/open_webui/main.py
  - backend/open_webui/utils/rate_limit.py
  - backend/open_webui/utils/auth.py
  - backend/open_webui/env.py
  - backend/open_webui/utils/telemetry/instrumentors.py
covers_symbols:
  - { symbol: get_redis_connection, file: backend/open_webui/utils/redis.py }
  - { symbol: get_redis_client, file: backend/open_webui/utils/redis.py }
  - { symbol: SentinelRedisProxy, file: backend/open_webui/utils/redis.py }
  - { symbol: RedisDict, file: backend/open_webui/socket/utils.py }
  - { symbol: RedisLock, file: backend/open_webui/socket/utils.py }
  - { symbol: YdocManager, file: backend/open_webui/socket/utils.py }
  - { symbol: redis_task_command_listener, file: backend/open_webui/tasks.py }
  - { symbol: redis_send_command, file: backend/open_webui/tasks.py }
  - { symbol: AppConfig, file: backend/open_webui/internal/config.py }
  - { symbol: RateLimiter, file: backend/open_webui/utils/rate_limit.py }
  - { symbol: redis_request_hook, file: backend/open_webui/utils/telemetry/instrumentors.py }
verified_against_commit: 304d2d673749691abad905b96230b30ddb77e145
---

# Redis

Redis serves as the central shared-state and messaging backbone for Open WebUI
Extended. It is **optional** for single-instance deployments but **required** for
multi-instance (horizontally scaled) deployments.

---

## Relevant Files

| File | Subject (grep for these symbols) |
|---|---|
| `backend/open_webui/utils/redis.py` | `get_redis_connection`, `get_redis_client`, `SentinelRedisProxy`, `_CONNECTION_POOL` |
| `backend/open_webui/socket/utils.py` | `RedisDict`, `RedisLock`, `YdocManager` |
| `backend/open_webui/socket/main.py` | `SESSION_POOL`, `USAGE_POOL`, `MODELS`, WebSocket Redis integration |
| `backend/open_webui/tasks.py` | `redis_task_command_listener`, `redis_send_command`, `REDIS_PUBSUB_CHANNEL` |
| `backend/open_webui/internal/config.py` | `AppConfig` — persistent config backed by Redis |
| `backend/open_webui/main.py` | Redis init in the lifespan (`get_redis_client`) |
| `backend/open_webui/utils/rate_limit.py` | `RateLimiter` — rolling-window limiter |
| `backend/open_webui/utils/auth.py` | `is_valid_token`, token/user revocation keys |
| `backend/open_webui/env.py` | Redis env var definitions |
| `backend/open_webui/utils/telemetry/instrumentors.py` | `redis_request_hook`, `RedisInstrumentor` |

> No dedicated Redis/Sentinel test module exists at time of writing. Before adding a
> reference to one, prove it exists from the repo root (`find . -name 'test_*redis*'`),
> per Directive 3 — a path miss is not proof of absence, but an empty find result is.

---

## Connection Management

### `get_redis_connection()` (`utils/redis.py`)

The primary factory for Redis clients. Its docstring lists the topology precedence,
which is the contract to rely on (check the branch order in the function body):

1. **Sentinel** — when `redis_sentinels` is non-empty. Builds a `Sentinel` and wraps it
   in `SentinelRedisProxy` for automatic failover (see [redis-sentinels.md](./redis-sentinels.md)).
2. **Cluster** — when `redis_cluster` is true. Requires a `redis_url`
   (raises `ValueError` otherwise) and uses `RedisCluster.from_url`.
3. **Standalone** — a plain `redis://` / `rediss://` connection via `from_url`.

The sync-vs-async client is chosen by the `async_mode` argument (it imports
`redis.asyncio` vs `redis`), and `decode_responses=True` is the default.

### Connection caching

Connections are cached in a module-level dict named `_CONNECTION_POOL`, keyed by
`(redis_url, sentinels_tuple, async_mode, decode_responses)`, so only one connection
exists per unique configuration. (The name is `_CONNECTION_POOL`, not
`_CONNECTION_CACHE` — grep for it.)

### `get_redis_client()` (`utils/redis.py`)

A convenience wrapper that reads the global env vars (`REDIS_URL`,
`REDIS_SENTINEL_HOSTS`/`REDIS_SENTINEL_PORT`, `REDIS_CLUSTER`) and calls
`get_redis_connection()`. **Contract**: returns `None` when Redis is not configured
(no URL and no sentinels) or when the connection attempt raises — it never propagates
the error. Takes an `async_mode` flag; the lifespan startup passes `async_mode=True`.

---

## Environment Variables

All defaults below are the fallbacks assigned in `env.py` **at time of writing**; the
env-var symbols are the source of truth.

| Variable | Default | Description |
|---|---|---|
| `REDIS_URL` | `""` (disabled) | Full connection URL, e.g. `redis://localhost:6379/0`, `rediss://user:pass@host:6380/1` |
| `REDIS_CLUSTER` | `False` | When `True`, uses the `RedisCluster` client |
| `REDIS_KEY_PREFIX` | `open-webui` | Namespace prefix prepended to all keys |
| `REDIS_SENTINEL_HOSTS` | `""` | Comma-separated sentinel hostnames |
| `REDIS_SENTINEL_PORT` | `26379` | Port for all sentinel instances |
| `REDIS_SENTINEL_MAX_RETRY_COUNT` | `2` | Retry attempts on `ConnectionError`/`ReadOnlyError`; values `< 1` are reset to `2` |
| `REDIS_SOCKET_CONNECT_TIMEOUT` | `None` | TCP connect timeout, seconds (float) |
| `REDIS_SOCKET_KEEPALIVE` | `False` | When `True`, enables TCP keepalive |
| `REDIS_HEALTH_CHECK_INTERVAL` | `None` | Seconds between redis-py health checks; values `<= 0` become `None` |
| `REDIS_RECONNECT_DELAY` | `None` | Delay between sentinel failover retries, milliseconds (float) |

### WebSocket-specific Redis variables

The WebSocket layer can use a **separate** Redis instance:

| Variable | Default | Description |
|---|---|---|
| `WEBSOCKET_REDIS_URL` | `REDIS_URL` | Redis URL for the Socket.IO manager |
| `WEBSOCKET_REDIS_CLUSTER` | `REDIS_CLUSTER` | Cluster mode for WebSocket Redis |
| `WEBSOCKET_REDIS_OPTIONS` | `None` | JSON dict of extra redis-py options; falls back to `{"socket_connect_timeout": REDIS_SOCKET_CONNECT_TIMEOUT}` when that timeout is set |
| `WEBSOCKET_REDIS_LOCK_TIMEOUT` | `60` | TTL (seconds) for distributed cleanup locks |
| `WEBSOCKET_SENTINEL_HOSTS` | `""` | Sentinel hosts for WebSocket Redis |
| `WEBSOCKET_SENTINEL_PORT` | `26379` | Sentinel port for WebSocket Redis |

---

## Redis Key Patterns

All keys are prefixed with `{REDIS_KEY_PREFIX}:` (default `open-webui:`). The `{prefix}`
below stands for that namespace.

### Shared state (hashes via `RedisDict`)

| Key | Type | Purpose |
|---|---|---|
| `{prefix}:models` | Hash | Model configurations visible to all instances |
| `{prefix}:session_pool` | Hash | Active WebSocket sessions: `sid → {user_data, last_seen_at}` |
| `{prefix}:usage_pool` | Hash | Active model usage: `model_id → {sid: {updated_at}}` |

### Task management (`tasks.py`)

| Key | Type | Purpose |
|---|---|---|
| `{prefix}:tasks` | Hash | Active task registry: `task_id → item_id` (`REDIS_TASKS_KEY`) |
| `{prefix}:tasks:item:{item_id}` | Set | Task IDs for a given item (`REDIS_ITEM_TASKS_KEY`) |
| `{prefix}:tasks:commands` | Pub/Sub channel | Cross-instance task commands (`REDIS_PUBSUB_CHANNEL`), JSON `{"action": "stop", "task_id": …}` |

### Collaborative documents (Yjs, `YdocManager`)

| Key | Type | Purpose |
|---|---|---|
| `{prefix}:ydoc:documents:{doc_id}:updates` | List | Ordered Yjs CRDT updates |
| `{prefix}:ydoc:documents:{doc_id}:users` | Set | Session IDs editing the document |
| `{prefix}:ydoc:documents:session:{sid}:documents` | Set | Per-session reverse index of joined docs |

> `doc_id` is normalized in storage keys: `YdocManager` replaces `:` with `_`
> (so `note:abc` is stored as `note_abc`). The reverse index exists so disconnect
> cleanup can iterate only this session's documents instead of `SCAN`-ning the keyspace.

### Distributed locks (`RedisLock`)

| Key | Type | Purpose |
|---|---|---|
| `{prefix}:usage_cleanup_lock` | String | Guards `periodic_usage_pool_cleanup()` |
| `{prefix}:session_cleanup_lock` | String | Guards `periodic_session_pool_cleanup()` |

### Rate limiting (`RateLimiter`)

| Key | Type | Purpose |
|---|---|---|
| `{prefix}:ratelimit:{key}:{bucket_index}` | String | Rolling-window bucket counter with TTL |

### Authentication (`utils/auth.py`)

| Key | Type | Purpose |
|---|---|---|
| `{prefix}:auth:token:{jti}:revoked` | String | Per-token revocation marker, keyed by JWT `jti`; TTL = token's remaining lifetime. Used for user-initiated sign-out. |
| `{prefix}:auth:user:{user_id}:revoked_at` | String | Per-user revocation timestamp. Used by OIDC back-channel logout when `jti` is unknown — tokens with `iat <= revoked_at` are rejected. |

### Configuration (`AppConfig`)

| Key | Type | Purpose |
|---|---|---|
| `{prefix}:config:{name}` | String | Persistent `AppConfig` value (JSON), read/written in `internal/config.py` |

---

## Redis-Backed Data Structures (`socket/utils.py`)

### `RedisDict`

A `dict`-like interface backed by a Redis Hash. Used for `SESSION_POOL`, `USAGE_POOL`,
and `MODELS`.

- **Storage**: Redis Hash (`HSET`/`HGET`/`HDEL`/`HGETALL`); values serialized as JSON.
- **Operations**: `__setitem__`, `__getitem__`, `__delitem__`, `__contains__`,
  `__len__`, `keys()`, `values()`, `items()`, `get()`, `set()`, `clear()`, `update()`,
  `setdefault()`.

> **Directive 6 — intentional-looking-wrong code.** `RedisDict.set(mapping)`
> deliberately **never** `DELETE`s the whole hash. It issues an `HSET` of all new values
> and then an `HDEL` of only the now-absent keys — specifically so concurrent readers
> never observe a momentarily empty dict. It additionally caches a per-process SHA-256
> signature of the serialized mapping and skips the write entirely when the mapping is
> unchanged from the last one this process wrote. Do **not** "simplify" this to an
> atomic `DELETE` + `HSET`: that reintroduces the empty-read race this code exists to
> avoid.

### `RedisLock`

A distributed mutex over Redis `SET` with NX/XX and an expiry. Contract:

- **Acquire**: `SET name uuid NX EX timeout` — succeeds only if the key is absent.
- **Renew**: `SET name uuid XX EX timeout` — extends TTL only if the key exists.
- **Release**: deletes the key only when its stored value matches this instance's UUID,
  so an instance can never release another's lock.

### `YdocManager`

Manages Yjs collaborative document state with automatic compaction.

- **Storage**: a Redis List for ordered updates, a Redis Set for active users; falls
  back to in-memory dicts when Redis is unavailable (dual mode).
- **Compaction**: triggers at `YdocManager.COMPACTION_THRESHOLD` (500 at time of
  writing) and squashes the oldest half of the update log into a single Yjs snapshot.

---

## Pub/Sub Usage

### Task command channel

`tasks.py` uses Redis pub/sub for distributed task cancellation on
`REDIS_PUBSUB_CHANNEL` (`{prefix}:tasks:commands`):

- **Publish**: any instance calls `redis_send_command()`. **Contract / surprising
  detail**: it detects cluster clients (by a `nodes_manager` attribute) and uses
  `execute_command("PUBLISH", …)` for them, because `RedisCluster` does not expose
  `publish()` directly; standalone/sentinel clients use `redis.publish()`.
- **Subscribe**: every instance runs `redis_task_command_listener()`, which subscribes
  to the channel and, on a `{"action": "stop", "task_id": …}` message, cancels the
  matching local `asyncio.Task` if it owns it.

### Socket.IO cross-instance events

When `WEBSOCKET_MANAGER=redis`, Socket.IO's `AsyncRedisManager` fans out events across
instances via its own pub/sub channels (created in `socket/main.py`).

---

## Initialization Flow

1. **Application startup** (`main.py` lifespan): `app.state.redis = get_redis_client(async_mode=True)`.
   `get_redis_client()` reads the env vars and returns `None` when Redis is not
   configured.
2. If `app.state.redis is not None`, the lifespan starts `redis_task_command_listener`
   as a background `asyncio` task (and cancels it on shutdown).
3. **Socket module** (`socket/main.py`): when `WEBSOCKET_MANAGER=redis`, it constructs
   the `AsyncRedisManager` for Socket.IO, `RedisDict` instances for `SESSION_POOL` /
   `USAGE_POOL` / `MODELS`, `RedisLock` instances for cleanup coordination, and an async
   Redis connection passed into `YdocManager`.

---

## Graceful Degradation

When Redis is unavailable (`REDIS_URL` empty or the connection fails):

- `get_redis_client()` returns `None`.
- `SESSION_POOL`, `USAGE_POOL`, `MODELS` are plain Python dicts.
- Task management falls back to local `asyncio.Task` tracking (the `tasks` / `item_tasks`
  module dicts).
- `RateLimiter` falls back to its in-memory `_memory_store`.
- The cleanup lock acquire/renew/release functions are no-ops bound to `lambda: True`.
- `YdocManager` uses in-memory dicts.
- **Limitation**: multi-instance deployments cannot share state in this mode.

---

## Telemetry

Redis operations are traced via OpenTelemetry. `RedisInstrumentor().instrument(request_hook=redis_request_hook)`
is wired up in `utils/telemetry/instrumentors.py`. `redis_request_hook` sets span
attributes for DB type/instance, host/port, and the command/statement, enabling
distributed tracing of Redis calls.

---

## Verification Recipe

Run from the repo root. If any line returns nothing, the doc is stale and must be
re-audited before it is trusted.

```bash
# Connection factory, wrapper, sentinel proxy, and the cache dict name
grep -rn "def get_redis_connection\|def get_redis_client\|class SentinelRedisProxy\|_CONNECTION_POOL" backend/open_webui/utils/redis.py

# Data structures
grep -rn "class RedisDict\|class RedisLock\|class YdocManager\|COMPACTION_THRESHOLD" backend/open_webui/socket/utils.py
# The intentional non-DELETE bulk set (Directive 6)
grep -rn "never DELETE the whole hash\|def set(self, mapping" backend/open_webui/socket/utils.py

# Task pub/sub
grep -rn "REDIS_PUBSUB_CHANNEL\|def redis_task_command_listener\|def redis_send_command" backend/open_webui/tasks.py

# AppConfig persistence key
grep -rn "class AppConfig" backend/open_webui/internal/config.py
grep -rn ":config:" backend/open_webui/internal/config.py

# Lifespan Redis init
grep -rn "get_redis_client(async_mode=True)\|redis_task_command_listener" backend/open_webui/main.py

# Rate limiter + key pattern
grep -rn "class RateLimiter\|:ratelimit:" backend/open_webui/utils/rate_limit.py

# Auth revocation keys (both mechanisms)
grep -rn "auth:token:.*:revoked\|auth:user:.*:revoked_at" backend/open_webui/utils/auth.py

# Env vars
grep -rn "REDIS_URL\|REDIS_CLUSTER\|REDIS_KEY_PREFIX\|REDIS_SENTINEL_MAX_RETRY_COUNT\|REDIS_SOCKET_KEEPALIVE\|REDIS_HEALTH_CHECK_INTERVAL" backend/open_webui/env.py

# Telemetry hook
grep -rn "def redis_request_hook\|RedisInstrumentor().instrument" backend/open_webui/utils/telemetry/instrumentors.py

# Confirm there is NO redis test module (Directive 3: prove absence)
find . -name 'test_*redis*'
```
