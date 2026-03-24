# Redis

Redis serves as the central shared-state and messaging backbone for Open WebUI Extended. It is **optional** for single-instance deployments but **required** for multi-instance (horizontally scaled) deployments.

---

## Relevant Files

| File | Purpose |
|---|---|
| `backend/open_webui/utils/redis.py` | Connection management, Sentinel proxy, connection caching |
| `backend/open_webui/env.py` (lines 436-473) | Redis environment variable definitions |
| `backend/open_webui/socket/utils.py` | `RedisDict`, `RedisLock`, `YdocManager` - Redis-backed data structures |
| `backend/open_webui/socket/main.py` | WebSocket Redis integration, `SESSION_POOL`, `USAGE_POOL`, `MODELS` |
| `backend/open_webui/tasks.py` | Distributed task management via Redis hashes and pub/sub |
| `backend/open_webui/config.py` | `AppConfig` persistent configuration backed by Redis |
| `backend/open_webui/main.py` (lines 630-642) | Redis initialization at application startup |
| `backend/open_webui/utils/rate_limit.py` | Redis-backed rolling-window rate limiter |
| `backend/open_webui/utils/auth.py` | Token revocation with Redis TTL keys |
| `backend/open_webui/routers/auths.py` | Rate limiting on authentication endpoints |
| `backend/open_webui/utils/telemetry/instrumentors.py` | OpenTelemetry Redis instrumentation |
| `backend/open_webui/test/util/test_redis.py` | Test suite for Sentinel proxy |

---

## Connection Management

### `get_redis_connection()` (`utils/redis.py`)

This is the primary factory function for obtaining Redis clients. It supports three modes:

1. **Standalone Redis** (`REDIS_URL` set, no sentinels, no cluster)
   ```python
   # Async mode
   redis.asyncio.from_url(redis_url, decode_responses=True)
   # Sync mode
   redis.Redis.from_url(redis_url, decode_responses=True)
   ```

2. **Redis Sentinel** (`REDIS_SENTINEL_HOSTS` set)
   - Creates a `Sentinel` instance with the parsed hosts
   - Wraps it in `SentinelRedisProxy` for automatic failover (see [Redis Sentinels](./redis-sentinels.md))

3. **Redis Cluster** (`REDIS_CLUSTER=True`)
   ```python
   redis.asyncio.cluster.RedisCluster.from_url(redis_url, decode_responses=True)
   ```

### Connection Caching

Connections are cached in a module-level `_CONNECTION_CACHE` dictionary keyed by `(redis_url, sentinels_tuple, async_mode, decode_responses)`. This ensures only one connection per unique configuration exists.

### `get_redis_client()` (`utils/redis.py`)

A convenience wrapper that calls `get_redis_connection()` with the global environment variables (`REDIS_URL`, `REDIS_SENTINEL_HOSTS`, etc.) and returns `None` on failure instead of raising.

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `REDIS_URL` | `""` (disabled) | Full Redis connection URL. Examples: `redis://localhost:6379/0`, `rediss://user:pass@host:6380/1` |
| `REDIS_CLUSTER` | `False` | When `True`, uses `RedisCluster` client instead of standalone |
| `REDIS_KEY_PREFIX` | `open-webui` | Namespace prefix prepended to all Redis keys to avoid collisions |
| `REDIS_SENTINEL_HOSTS` | `""` | Comma-separated sentinel hostnames (e.g., `sentinel1,sentinel2,sentinel3`) |
| `REDIS_SENTINEL_PORT` | `26379` | Port for all sentinel instances |
| `REDIS_SENTINEL_MAX_RETRY_COUNT` | `2` | Number of retry attempts on `ConnectionError` or `ReadOnlyError` (minimum 1) |
| `REDIS_SOCKET_CONNECT_TIMEOUT` | `None` | TCP connection timeout in seconds (float) |
| `REDIS_RECONNECT_DELAY` | `None` | Delay between sentinel failover retries in milliseconds (float) |

### WebSocket-Specific Redis Variables

The WebSocket layer can optionally use a **separate** Redis instance:

| Variable | Default | Description |
|---|---|---|
| `WEBSOCKET_REDIS_URL` | `REDIS_URL` | Redis URL for the Socket.IO manager |
| `WEBSOCKET_REDIS_CLUSTER` | `REDIS_CLUSTER` | Cluster mode for WebSocket Redis |
| `WEBSOCKET_REDIS_OPTIONS` | `None` | JSON dict of additional redis-py options (e.g., `{"socket_connect_timeout": 5}`) |
| `WEBSOCKET_REDIS_LOCK_TIMEOUT` | `60` | TTL for distributed cleanup locks (seconds) |
| `WEBSOCKET_SENTINEL_HOSTS` | `""` | Sentinel hosts for WebSocket Redis (separate from main) |
| `WEBSOCKET_SENTINEL_PORT` | `26379` | Sentinel port for WebSocket Redis |

---

## Redis Key Patterns

All keys are prefixed with `{REDIS_KEY_PREFIX}:` (default: `open-webui:`).

### Shared State (Hashes via RedisDict)

| Key | Type | Purpose |
|---|---|---|
| `{prefix}:models` | Hash | Model configurations visible to all instances |
| `{prefix}:session_pool` | Hash | Active WebSocket sessions: `{sid} -> {user_data, last_seen_at}` |
| `{prefix}:usage_pool` | Hash | Active model usage: `{model_id} -> {sid: {updated_at}}` |

### Task Management

| Key | Type | Purpose |
|---|---|---|
| `{prefix}:tasks` | Hash | Active task registry: `{task_id} -> {item_id}` |
| `{prefix}:tasks:item:{item_id}` | Set | Task IDs associated with a specific item |
| `{prefix}:tasks:commands` | Pub/Sub Channel | Cross-instance task commands (JSON: `{"action": "stop", "task_id": "..."}`) |

### Collaborative Documents (Yjs)

| Key | Type | Purpose |
|---|---|---|
| `{prefix}:ydoc:documents:{doc_id}:updates` | List | Ordered Yjs CRDT updates for a document |
| `{prefix}:ydoc:documents:{doc_id}:users` | Set | Session IDs of users editing the document |

### Distributed Locks

| Key | Type | Purpose |
|---|---|---|
| `{prefix}:usage_cleanup_lock` | String | Lock for `periodic_usage_pool_cleanup()` |
| `{prefix}:session_cleanup_lock` | String | Lock for `periodic_session_pool_cleanup()` |

### Rate Limiting

| Key | Type | Purpose |
|---|---|---|
| `{prefix}:ratelimit:{key}:{bucket_index}` | String | Rolling window bucket counters with TTL |

### Authentication

| Key | Type | Purpose |
|---|---|---|
| `{prefix}:auth:token:{jti}:revoked` | String | Revoked JWT token marker (expires with JWT) |

### Configuration

| Key | Type | Purpose |
|---|---|---|
| `{prefix}:config:{key}` | String | Persistent `AppConfig` values |

---

## Redis-Backed Data Structures

### `RedisDict` (`socket/utils.py`)

A Python dict-like interface backed by a Redis Hash. Used for `SESSION_POOL`, `USAGE_POOL`, and `MODELS`.

```python
class RedisDict:
    def __init__(self, name, redis_url, redis_sentinels=[], redis_cluster=False)
```

- **Storage**: Redis Hash (`HSET`/`HGET`/`HDEL`/`HGETALL`)
- **Serialization**: JSON for values
- **Operations**: `__setitem__`, `__getitem__`, `__delitem__`, `__contains__`, `__len__`, `keys()`, `values()`, `items()`, `get()`, `set()`, `clear()`, `update()`, `setdefault()`
- **Atomic bulk set**: `set(mapping)` uses a pipeline to `DELETE` + `HSET` atomically

### `RedisLock` (`socket/utils.py`)

A distributed mutex using Redis `SET NX/XX` with expiration.

```python
class RedisLock:
    def __init__(self, redis_url, lock_name, timeout_secs, ...)
```

- **Acquire**: `SET lock_name lock_id NX EX timeout` - only succeeds if key doesn't exist
- **Renew**: `SET lock_name lock_id XX EX timeout` - only succeeds if key exists
- **Release**: Check value matches `lock_id`, then `DELETE`
- **Lock ID**: UUID per instance, prevents one instance from releasing another's lock

### `YdocManager` (`socket/utils.py`)

Manages Yjs collaborative document state with automatic compaction.

```python
class YdocManager:
    COMPACTION_THRESHOLD = 500
```

- **Storage**: Redis List for ordered updates, Redis Set for active users
- **Compaction**: When update count reaches 500, squashes the oldest half into a single Yjs snapshot
- **Dual mode**: Uses in-memory dicts when Redis is unavailable

---

## Pub/Sub Usage

### Task Command Channel

The `tasks.py` module uses Redis pub/sub for distributed task cancellation:

```python
REDIS_PUBSUB_CHANNEL = f"{REDIS_KEY_PREFIX}:tasks:commands"

# Publishing (any instance)
await redis.publish(REDIS_PUBSUB_CHANNEL, json.dumps({"action": "stop", "task_id": "..."}))

# Subscribing (all instances, in redis_task_command_listener)
pubsub = redis.pubsub()
await pubsub.subscribe(REDIS_PUBSUB_CHANNEL)
async for message in pubsub.listen():
    # Cancel local task if we own it
```

### Socket.IO Cross-Instance Events

When `WEBSOCKET_MANAGER=redis`, Socket.IO's `AsyncRedisManager` handles event fan-out automatically via its own pub/sub channels.

---

## Initialization Flow

1. **Application startup** (`main.py` lifespan):
   ```python
   app.state.redis = get_redis_connection(
       redis_url=REDIS_URL,
       redis_sentinels=get_sentinels_from_env(REDIS_SENTINEL_HOSTS, REDIS_SENTINEL_PORT),
       redis_cluster=REDIS_CLUSTER,
       async_mode=True,
   )
   ```
2. If Redis is available, starts `redis_task_command_listener` as a background task
3. **Socket module** (`socket/main.py`): If `WEBSOCKET_MANAGER=redis`, creates:
   - `AsyncRedisManager` for Socket.IO
   - `RedisDict` instances for `SESSION_POOL`, `USAGE_POOL`, `MODELS`
   - `RedisLock` instances for cleanup coordination
   - Async Redis connection for `YdocManager`

---

## Graceful Degradation

When Redis is unavailable (`REDIS_URL` empty or connection fails):

- `get_redis_client()` returns `None`
- `SESSION_POOL`, `USAGE_POOL`, `MODELS` fall back to plain Python dicts
- Task management uses local `asyncio.Task` tracking only
- Rate limiter falls back to in-memory storage
- Cleanup locks become no-ops (`lambda: True`)
- `YdocManager` uses in-memory dicts
- **Limitation**: Multi-instance deployments will not share state

---

## Telemetry

Redis operations are instrumented via OpenTelemetry (`utils/telemetry/instrumentors.py`):

```python
from opentelemetry.instrumentation.redis import RedisInstrumentor
RedisInstrumentor().instrument(request_hook=redis_request_hook)
```

The `redis_request_hook` adds span attributes for the DB type, endpoint, and command being executed, enabling distributed tracing of Redis operations.
