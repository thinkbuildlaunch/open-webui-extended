# Redis Sentinels

Redis Sentinel provides automatic failover and high availability for Redis in Open WebUI Extended. When configured, the application transparently handles master election, connection retries, and failover recovery without any downtime visible to users.

---

## Relevant Files

| File | Purpose |
|---|---|
| `backend/open_webui/utils/redis.py` | `SentinelRedisProxy` class, `parse_redis_service_url()`, `get_sentinels_from_env()`, `get_sentinel_url_from_env()` |
| `backend/open_webui/env.py` (lines 444-473) | Sentinel environment variables |
| `backend/open_webui/socket/main.py` (lines 63-70, 109-120) | Sentinel URL construction for Socket.IO manager |
| `backend/open_webui/main.py` (lines 630-637) | Application-level Redis+Sentinel initialization |
| `backend/open_webui/test/util/test_redis.py` | Comprehensive test suite for `SentinelRedisProxy` |

---

## How Sentinel Works in This Codebase

### Architecture Overview

```
                   Redis Sentinel Cluster
              +--------+  +--------+  +--------+
              | Sent-1 |  | Sent-2 |  | Sent-3 |
              +--------+  +--------+  +--------+
                   |            |            |
                   +-----+------+-----+------+
                         |            |
                    +--------+   +--------+
                    | Master |   | Replica|
                    +--------+   +--------+
                         ^
                         |
              SentinelRedisProxy
              (auto-failover retry)
                         ^
                         |
         +---------------+---------------+
         |               |               |
   SESSION_POOL    Task Pub/Sub    Rate Limiter
   (RedisDict)     (tasks.py)     (rate_limit.py)
```

### Connection Establishment

When `REDIS_SENTINEL_HOSTS` is set, `get_redis_connection()` takes the Sentinel path:

1. **Parse the Redis URL** via `parse_redis_service_url()` to extract:
   - `username` and `password` (for Sentinel authentication)
   - `service` name (hostname portion of URL, default: `mymaster`)
   - `port` and `db` number

2. **Parse Sentinel hosts** via `get_sentinels_from_env()`:
   ```python
   # Input: REDIS_SENTINEL_HOSTS="sentinel1,sentinel2,sentinel3"
   #        REDIS_SENTINEL_PORT="26379"
   # Output: [("sentinel1", 26379), ("sentinel2", 26379), ("sentinel3", 26379)]
   ```

3. **Create a Sentinel instance** (async or sync depending on mode):
   ```python
   sentinel = redis.asyncio.sentinel.Sentinel(
       [("sentinel1", 26379), ("sentinel2", 26379), ("sentinel3", 26379)],
       port=6379,
       db=0,
       username="user",
       password="pass",
       decode_responses=True,
       socket_connect_timeout=REDIS_SOCKET_CONNECT_TIMEOUT,
   )
   ```

4. **Wrap in `SentinelRedisProxy`**:
   ```python
   connection = SentinelRedisProxy(sentinel, "mymaster", async_mode=True)
   ```

---

## `SentinelRedisProxy` (`utils/redis.py`)

The proxy is the core mechanism for transparent failover. It wraps a Sentinel instance and intercepts all attribute access (Redis commands) to add retry logic.

### Class Structure

```python
class SentinelRedisProxy:
    def __init__(self, sentinel, service, *, async_mode=True, **kw):
        self._sentinel = sentinel
        self._service = service
        self._kw = kw
        self._async_mode = async_mode

    def _master(self):
        return self._sentinel.master_for(self._service, **self._kw)
```

### How `__getattr__` Works

When any Redis command is called on the proxy (e.g., `proxy.get("key")`):

1. **Resolve the current master** via `self._master()` which calls `sentinel.master_for(service_name)`
2. **Get the actual method** from the master connection
3. **Check if it's a factory method** (`pipeline`, `pubsub`, `monitor`, `client`, `transaction`) - these are returned directly without wrapping
4. **Wrap the call** with retry logic based on the mode (async or sync)

### Retry Logic

The proxy retries on two specific exception types:

- **`redis.exceptions.ConnectionError`**: The master is unreachable (network issue, master down)
- **`redis.exceptions.ReadOnlyError`**: Connected to what was the master, but it's been demoted to a replica

For each retry:
1. Log a debug message: `"Redis sentinel fail-over (ConnectionError). Retry 1/2"`
2. Wait `REDIS_RECONNECT_DELAY` milliseconds (if configured)
3. Re-resolve the master via `self._master()` (Sentinel will return the new master)
4. Retry the command

If all retries are exhausted, log an error and re-raise the exception.

### Async Mode

In async mode, the proxy handles three types of callables:

1. **Async generator functions** (e.g., `scan_iter`): Returns a wrapped async generator that retries on failover
2. **Regular async methods** (e.g., `get`, `set`): Returns an async wrapper that awaits the result and retries
3. **Sync methods** called from async context: Detects via `inspect.iscoroutine()` and awaits if needed

```python
# Async retry wrapper (simplified)
async def _wrapped(*args, **kwargs):
    for i in range(REDIS_SENTINEL_MAX_RETRY_COUNT):
        try:
            method = getattr(self._master(), item)
            result = method(*args, **kwargs)
            if inspect.iscoroutine(result):
                return await result
            return result
        except (ConnectionError, ReadOnlyError) as e:
            if i < max_retries - 1:
                await asyncio.sleep(REDIS_RECONNECT_DELAY / 1000)
                continue
            raise
```

### Sync Mode

In sync mode, the wrapper is simpler:

```python
def _wrapped(*args, **kwargs):
    for i in range(REDIS_SENTINEL_MAX_RETRY_COUNT):
        try:
            method = getattr(self._master(), item)
            return method(*args, **kwargs)
        except (ConnectionError, ReadOnlyError) as e:
            if i < max_retries - 1:
                time.sleep(REDIS_RECONNECT_DELAY / 1000)
                continue
            raise
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `REDIS_SENTINEL_HOSTS` | `""` | Comma-separated list of sentinel hostnames. When set, enables Sentinel mode. Example: `sentinel1,sentinel2,sentinel3` |
| `REDIS_SENTINEL_PORT` | `26379` | Port used by all sentinel instances (same port for all) |
| `REDIS_SENTINEL_MAX_RETRY_COUNT` | `2` | Number of retry attempts per Redis operation during failover. Minimum value: 1. |
| `REDIS_RECONNECT_DELAY` | `None` | Delay between retries in **milliseconds**. When `None`, retries happen immediately. Example: `500` for 500ms delay |
| `REDIS_SOCKET_CONNECT_TIMEOUT` | `None` | TCP connection timeout in **seconds** (float). Applied to Sentinel connections. Example: `5.0` |
| `REDIS_URL` | `""` | Used to extract service name, credentials, port, and DB number for Sentinel. The hostname becomes the service name (default: `mymaster`) |

### WebSocket-Specific Sentinel Variables

| Variable | Default | Description |
|---|---|---|
| `WEBSOCKET_SENTINEL_HOSTS` | `""` | Separate sentinel hosts for the WebSocket Redis (allows different Redis cluster) |
| `WEBSOCKET_SENTINEL_PORT` | `26379` | Sentinel port for WebSocket Redis |

---

## URL Construction for Socket.IO

Socket.IO's `AsyncRedisManager` requires a `redis+sentinel://` URL format. The `get_sentinel_url_from_env()` function constructs this:

```python
def get_sentinel_url_from_env(redis_url, sentinel_hosts_env, sentinel_port_env):
    redis_config = parse_redis_service_url(redis_url)
    # ...
    return f"redis+sentinel://{auth_part}{hosts_part}/{db}/{service}"
    # Example: "redis+sentinel://user:pass@sentinel1:26379,sentinel2:26379/0/mymaster"
```

This is used in `socket/main.py`:

```python
if WEBSOCKET_SENTINEL_HOSTS:
    mgr = socketio.AsyncRedisManager(
        get_sentinel_url_from_env(
            WEBSOCKET_REDIS_URL, WEBSOCKET_SENTINEL_HOSTS, WEBSOCKET_SENTINEL_PORT
        ),
        redis_options=WEBSOCKET_REDIS_OPTIONS,
    )
```

---

## `parse_redis_service_url()` (`utils/redis.py`)

Parses a standard Redis URL to extract Sentinel-relevant parameters:

```python
def parse_redis_service_url(redis_url):
    # Input: "redis://user:pass@mymaster:6379/2"
    # Output: {
    #     "username": "user",
    #     "password": "pass",
    #     "service": "mymaster",    # hostname becomes service name
    #     "port": 6379,
    #     "db": 2,
    # }
```

Key details:
- Supports both `redis://` and `rediss://` (TLS) schemes
- Hostname becomes the Sentinel **service name** (default: `mymaster`)
- Port defaults to `6379` if not specified
- DB defaults to `0` if not specified in the path

---

## Configuration Examples

### Minimal Sentinel Setup

```env
REDIS_URL=redis://mymaster:6379/0
REDIS_SENTINEL_HOSTS=sentinel1,sentinel2,sentinel3
REDIS_SENTINEL_PORT=26379
```

### Sentinel with Authentication

```env
REDIS_URL=redis://username:password@mymaster:6379/0
REDIS_SENTINEL_HOSTS=sentinel1,sentinel2,sentinel3
REDIS_SENTINEL_PORT=26379
```

### Sentinel with Tuned Failover

```env
REDIS_URL=redis://mymaster:6379/0
REDIS_SENTINEL_HOSTS=sentinel1,sentinel2,sentinel3
REDIS_SENTINEL_PORT=26379
REDIS_SENTINEL_MAX_RETRY_COUNT=5
REDIS_RECONNECT_DELAY=500
REDIS_SOCKET_CONNECT_TIMEOUT=5.0
```

### Separate Sentinel for WebSocket Layer

```env
# Main Redis (for tasks, auth, config)
REDIS_URL=redis://mymaster:6379/0
REDIS_SENTINEL_HOSTS=sentinel1,sentinel2,sentinel3

# WebSocket Redis (for Socket.IO, sessions, usage)
WEBSOCKET_MANAGER=redis
WEBSOCKET_REDIS_URL=redis://ws-master:6379/0
WEBSOCKET_SENTINEL_HOSTS=ws-sentinel1,ws-sentinel2,ws-sentinel3
WEBSOCKET_SENTINEL_PORT=26379
```

---

## Failover Sequence

When a Redis master goes down:

1. **Sentinel detects failure** (configurable timeout on the Sentinel side)
2. **Sentinel promotes a replica** to master
3. **Application sends a Redis command** (e.g., `SESSION_POOL["sid"]`)
4. **`SentinelRedisProxy` catches** `ConnectionError` or `ReadOnlyError`
5. **Proxy logs**: `"Redis sentinel fail-over (ConnectionError). Retry 1/2"`
6. **Proxy waits** `REDIS_RECONNECT_DELAY` ms (if configured)
7. **Proxy calls** `self._master()` which queries Sentinel for the new master
8. **Proxy retries** the command on the new master
9. **If still failing**, repeats up to `REDIS_SENTINEL_MAX_RETRY_COUNT` times
10. **If all retries exhausted**, raises the exception to the caller

---

## Testing

The test suite at `backend/open_webui/test/util/test_redis.py` covers:

- `SentinelRedisProxy` creation for both sync and async modes
- Failover retry on `ConnectionError` (verifies retry count and master re-resolution)
- Failover retry on `ReadOnlyError` (same flow)
- Factory method pass-through (`pipeline`, `pubsub`, `monitor`, `client`, `transaction`)
- String, hash, list, and pub/sub command delegation
- Async generator support (e.g., `scan_iter`)
- Retry exhaustion (exception propagation after max retries)
