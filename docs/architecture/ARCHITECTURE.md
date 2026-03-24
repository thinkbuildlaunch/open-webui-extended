# Open WebUI Extended - Infrastructure Architecture Overview

This document provides a comprehensive overview of the core infrastructure components that power Open WebUI Extended. Each component is designed to work both independently and in concert, enabling a scalable, real-time, multi-instance deployment.

## Components at a Glance

| Component | Purpose | Key Files |
|---|---|---|
| [Redis](./redis.md) | In-memory data store for caching, sessions, pub/sub, and shared state | `backend/open_webui/utils/redis.py`, `backend/open_webui/env.py` |
| [Redis Sentinels](./redis-sentinels.md) | High-availability failover for Redis | `backend/open_webui/utils/redis.py` (`SentinelRedisProxy`) |
| [Heartbeats](./heartbeats.md) | Client liveness detection and session reaping | `backend/open_webui/socket/main.py`, `src/routes/+layout.svelte` |
| [WebSockets](./websockets.md) | Real-time bidirectional communication via Socket.IO | `backend/open_webui/socket/main.py`, `src/routes/+layout.svelte` |
| [SQLAlchemy](./sqlalchemy.md) | ORM and database connection management | `backend/open_webui/internal/db.py`, `backend/open_webui/env.py` |
| [ThreadPooling](./threadpooling.md) | Async-to-sync bridging and parallel execution | `backend/open_webui/main.py`, `backend/open_webui/config.py` |

---

## How the Components Interact

### System Architecture Diagram

```
 Browser (Svelte Frontend)
    |
    |  Socket.IO (WebSocket / polling)
    |  Heartbeat every 30s
    v
 FastAPI + Socket.IO ASGI Server
    |         |              |
    |         |              +---> SQLAlchemy (PostgreSQL / SQLite)
    |         |                      |
    |         |                      +---> QueuePool / NullPool (connection pooling)
    |         |
    |         +---> ThreadPoolExecutor / AnyIO thread limiter
    |                (sync DB calls, LDAP, image gen, etc.)
    |
    +---> Redis (standalone / Sentinel / Cluster)
             |
             +---> SESSION_POOL (RedisDict hash)
             +---> USAGE_POOL (RedisDict hash)
             +---> MODELS (RedisDict hash)
             +---> Pub/Sub (task commands, Socket.IO cross-instance)
             +---> Distributed locks (cleanup coordination)
             +---> Yjs document updates (collaborative editing)
             +---> Rate limiting buckets
             +---> Token revocation store
             +---> Session persistence (starsessions)
             +---> AppConfig persistence
```

### Interaction Map

#### 1. WebSockets + Redis (Distributed Real-Time)

When `WEBSOCKET_MANAGER=redis`, Socket.IO uses `AsyncRedisManager` for cross-instance event broadcasting. All connected clients across all server instances receive events through Redis pub/sub. The `SESSION_POOL`, `USAGE_POOL`, and `MODELS` dictionaries are backed by Redis hashes (`RedisDict`), making them visible to every instance.

**Data flow:**
```
Instance A receives WebSocket event
  -> Socket.IO AsyncRedisManager publishes to Redis
  -> Redis fans out to all subscribers
  -> Instance B receives and delivers to its local clients
```

#### 2. Heartbeats + WebSockets + Redis (Liveness Detection)

The heartbeat system has three layers:

1. **Engine.IO ping/pong** (transport-level): Server pings every 25s, client must respond within 20s. Detects dead TCP connections.
2. **Application heartbeat** (client-initiated): Client emits `heartbeat` event every 30s. Server updates `SESSION_POOL[sid].last_seen_at`.
3. **Session reaping** (server-side cleanup): Background task scans `SESSION_POOL` every 120s. Any session without a heartbeat for >120s is reaped. Uses `RedisLock` to ensure only one instance performs cleanup.

#### 3. WebSockets + SQLAlchemy + ThreadPooling (Database Updates via Socket Events)

Socket.IO event handlers often need to write to the database. Since SQLAlchemy sessions are synchronous and Socket.IO handlers are async, the bridge is `asyncio.to_thread()`:

```python
# In get_event_emitter (socket/main.py)
await asyncio.to_thread(
    Chats.upsert_message_to_chat_by_id_and_message_id,
    chat_id, message_id, {"content": content}
)
```

The AnyIO thread limiter (configured via `THREAD_POOL_SIZE`) governs how many of these sync calls can execute concurrently, preventing thread exhaustion.

#### 4. Redis + SQLAlchemy (Complementary Persistence)

Redis and SQLAlchemy serve different persistence needs:

| Concern | Redis | SQLAlchemy |
|---|---|---|
| Session state (who is online) | `SESSION_POOL` hash | `Users.last_active_at` column |
| Chat messages | Streaming via pub/sub | Permanent storage |
| Configuration | `AppConfig` live values | Migration-managed schema |
| Rate limiting | Rolling window buckets | N/A |
| Token revocation | TTL-based keys | N/A |
| Collaborative docs | Yjs update lists | Note content on save |

#### 5. Redis Sentinels + All Redis Consumers

When Sentinel is configured, every Redis consumer (Socket.IO manager, `RedisDict`, `RedisLock`, `YdocManager`, rate limiter, task system) transparently benefits from automatic failover via `SentinelRedisProxy`. The proxy intercepts every Redis command and retries on `ConnectionError` or `ReadOnlyError`.

#### 6. ThreadPooling + SQLAlchemy (Safe Async Database Access)

The thread pool size directly affects database connection pool utilization:

```
THREAD_POOL_SIZE  -->  max concurrent sync calls
DATABASE_POOL_SIZE  -->  max concurrent DB connections
```

If `THREAD_POOL_SIZE > DATABASE_POOL_SIZE`, threads will block waiting for a database connection. The recommended configuration keeps these values aligned.

---

## Single-Instance vs. Multi-Instance Deployment

### Single-Instance (Default)

- No Redis required
- `SESSION_POOL`, `USAGE_POOL`, `MODELS` are plain Python dicts
- Task management uses local `asyncio.Task` tracking
- Cleanup locks are no-ops (`lambda: True`)
- SQLite works fine with `NullPool`

### Multi-Instance (Production)

- **Required**: `REDIS_URL` set, `WEBSOCKET_MANAGER=redis`
- All shared state moves to Redis hashes
- Socket.IO events broadcast via Redis pub/sub
- Distributed locks coordinate cleanup across instances
- Task cancellation propagates via pub/sub
- PostgreSQL recommended with `QueuePool`
- `THREAD_POOL_SIZE` and `DATABASE_POOL_SIZE` should be tuned per instance

---

## Environment Variable Quick Reference

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
| `DATABASE_POOL_SIZE` | `None` | Connection pool size |
| `DATABASE_POOL_MAX_OVERFLOW` | `0` | Extra connections above pool_size |
| `DATABASE_POOL_TIMEOUT` | `30` | Wait time for connection (seconds) |
| `DATABASE_POOL_RECYCLE` | `3600` | Connection lifetime (seconds) |

### Thread Pool
| Variable | Default | Description |
|---|---|---|
| `THREAD_POOL_SIZE` | `None` | AnyIO thread limiter token count |

---

## Graceful Degradation

The system is designed to degrade gracefully when components are unavailable:

- **No Redis**: Falls back to in-memory dicts for session/usage pools, local task tracking, in-memory rate limiting. Single-instance only.
- **No PostgreSQL**: SQLite with `NullPool` is the default. No connection pooling, but functional.
- **No WebSocket support**: Falls back to HTTP long-polling transport via Socket.IO.
- **No thread pool configured**: AnyIO uses its default thread limiter (typically 40 threads).

---

## Further Reading

- [Redis](./redis.md) - Connection management, key patterns, pub/sub, and caching
- [Redis Sentinels](./redis-sentinels.md) - High availability, failover proxy, and configuration
- [Heartbeats](./heartbeats.md) - Liveness detection, session reaping, and cleanup coordination
- [WebSockets](./websockets.md) - Socket.IO setup, events, rooms, and collaborative editing
- [SQLAlchemy](./sqlalchemy.md) - Engine configuration, models, migrations, and connection pooling
- [ThreadPooling](./threadpooling.md) - AnyIO limiter, ThreadPoolExecutor usage, and async bridging
