# Heartbeats

The heartbeat system in Open WebUI Extended provides client liveness detection, session reaping, and user activity tracking. It operates at multiple layers to ensure robust detection of disconnected clients, especially in multi-instance deployments where a client may be connected to one instance while another handles cleanup.

---

## Relevant Files

| File | Purpose |
|---|---|
| `src/routes/+layout.svelte` (lines 103, 141-147, 175-181) | Client-side heartbeat emission (30s interval) |
| `backend/open_webui/socket/main.py` (lines 83-84, 103, 179-201, 204-253, 410-415) | Server-side heartbeat handler, ping/pong config, session reaping, usage cleanup |
| `backend/open_webui/socket/utils.py` (lines 9-47) | `RedisLock` used for distributed cleanup coordination |
| `backend/open_webui/env.py` (lines 779-789) | `WEBSOCKET_SERVER_PING_INTERVAL` and `WEBSOCKET_SERVER_PING_TIMEOUT` configuration |

---

## Three Layers of Heartbeat

The system uses three distinct heartbeat mechanisms, each operating at a different level:

### Layer 1: Engine.IO Ping/Pong (Transport Level)

**Purpose**: Detect dead TCP connections at the transport layer.

**How it works**:
- The Socket.IO server (via Engine.IO) sends a `ping` frame to each client at a configurable interval
- The client must respond with a `pong` frame within the timeout
- If no `pong` is received, the server closes the connection and fires a `disconnect` event

**Configuration** (in `socket/main.py`):
```python
sio = socketio.AsyncServer(
    ping_interval=WEBSOCKET_SERVER_PING_INTERVAL,  # default: 25 seconds
    ping_timeout=WEBSOCKET_SERVER_PING_TIMEOUT,     # default: 20 seconds
    ...
)
```

**Environment variables**:
| Variable | Default | Description |
|---|---|---|
| `WEBSOCKET_SERVER_PING_INTERVAL` | `25` | Seconds between server-initiated pings |
| `WEBSOCKET_SERVER_PING_TIMEOUT` | `20` | Seconds to wait for pong response |

**Characteristics**:
- Fully handled by the Socket.IO/Engine.IO library
- Transparent to application code
- Detects: network drops, client crashes, browser tab closes
- Does NOT detect: client application freezes where the Socket.IO library still responds

### Layer 2: Application Heartbeat (Client-Initiated)

**Purpose**: Track user activity at the application level and update `last_seen_at` timestamps.

**Client side** (`src/routes/+layout.svelte`):
```javascript
// On successful socket connection
heartbeatInterval = setInterval(() => {
    if (_socket.connected) {
        console.log('Sending heartbeat');
        _socket.emit('heartbeat', {});
    }
}, 30000);  // Every 30 seconds

// On disconnect
if (heartbeatInterval) {
    clearInterval(heartbeatInterval);
    heartbeatInterval = null;
}
```

**Server side** (`socket/main.py`):
```python
@sio.on("heartbeat")
async def heartbeat(sid, data):
    user = SESSION_POOL.get(sid)
    if user:
        SESSION_POOL[sid] = {**user, "last_seen_at": int(time.time())}
        Users.update_last_active_by_id(user["id"])
```

**What happens on each heartbeat**:
1. Client emits `heartbeat` event (empty payload `{}`)
2. Server looks up the session in `SESSION_POOL`
3. Updates `last_seen_at` to current Unix timestamp
4. Calls `Users.update_last_active_by_id()` to update the database `last_active_at` column

**Characteristics**:
- Application-level liveness signal
- Updates both in-memory/Redis state AND the persistent database
- 30-second interval is longer than the Engine.IO ping (25s), so a client that responds to pings but doesn't emit heartbeats is still considered "alive" for transport purposes but may be reaped by the session cleanup

### Layer 3: Session Reaping (Server-Side Cleanup)

**Purpose**: Remove orphaned sessions that missed heartbeats (e.g., instance crash, network partition, stuck clients).

**Implementation** (`socket/main.py`):
```python
SESSION_POOL_TIMEOUT = 120  # seconds without heartbeat before session is reaped

async def periodic_session_pool_cleanup():
    """Reap orphaned SESSION_POOL entries that missed heartbeats."""
    if not session_aquire_func():
        log.debug("Session cleanup lock held by another node. Skipping.")
        return

    try:
        while True:
            if not session_renew_func():
                log.error("Unable to renew session cleanup lock. Exiting.")
                return

            now = int(time.time())
            for sid in list(SESSION_POOL.keys()):
                entry = SESSION_POOL.get(sid)
                if entry and now - entry.get("last_seen_at", 0) > SESSION_POOL_TIMEOUT:
                    log.warning(f"Reaping orphaned session {sid} (user {entry.get('id')})")
                    del SESSION_POOL[sid]
            await asyncio.sleep(SESSION_POOL_TIMEOUT)
    finally:
        session_release_func()
```

**Key behaviors**:
- Runs as an `asyncio.create_task()` background task started during application lifespan
- Scans every 120 seconds (`SESSION_POOL_TIMEOUT`)
- Reaps any session where `now - last_seen_at > 120 seconds`
- Uses a distributed lock (`RedisLock`) so only ONE instance performs cleanup in multi-instance deployments
- The lock is renewed each iteration and released on exit

---

## Timing Diagram

```
Time(s)  Client                    Server
──────────────────────────────────────────────────────────
  0      connect ───────────────>  SESSION_POOL[sid] = {last_seen_at: 0}
                                   sio.enter_room(sid, "user:{id}")

 25                   <─────────── Engine.IO ping
         Engine.IO pong ────────>

 30      emit('heartbeat') ─────>  SESSION_POOL[sid].last_seen_at = 30
                                   Users.update_last_active_by_id()

 50                   <─────────── Engine.IO ping
         Engine.IO pong ────────>

 60      emit('heartbeat') ─────>  SESSION_POOL[sid].last_seen_at = 60

 75                   <─────────── Engine.IO ping
         Engine.IO pong ────────>

 90      emit('heartbeat') ─────>  SESSION_POOL[sid].last_seen_at = 90

 95      *** Client crashes ***

100                   <─────────── Engine.IO ping
         (no pong)
120                                Engine.IO: connection timeout
                                   disconnect event fires
                                   del SESSION_POOL[sid]

--- OR if disconnect event was missed (e.g., instance crash) ---

120                                periodic_session_pool_cleanup() runs
                                   now(210) - last_seen_at(90) = 120 > 120
                                   Reaps session
```

---

## Usage Pool Cleanup

In addition to session heartbeats, there's a parallel cleanup for model usage tracking:

```python
TIMEOUT_DURATION = 3  # seconds

async def periodic_usage_pool_cleanup():
    # Acquire distributed lock with retry
    for attempt in range(max_retries + 1):
        if aquire_func():
            break
        await asyncio.sleep(retry_delay)

    while True:
        now = int(time.time())
        for model_id, connections in list(USAGE_POOL.items()):
            expired_sids = [
                sid for sid, details in connections.items()
                if now - details["updated_at"] > TIMEOUT_DURATION
            ]
            for sid in expired_sids:
                del connections[sid]
            if not connections:
                del USAGE_POOL[model_id]
            else:
                USAGE_POOL[model_id] = connections
        await asyncio.sleep(TIMEOUT_DURATION)
```

**Key differences from session cleanup**:
- Much shorter timeout: 3 seconds (vs. 120 for sessions)
- Tracks model inference usage, not session liveness
- Client emits `usage` events during active model inference
- Also uses a distributed `RedisLock` for coordination
- Lock acquisition includes retry with random backoff

---

## Distributed Lock Coordination

In multi-instance deployments, both cleanup tasks use `RedisLock` to ensure only one instance runs the cleanup loop:

```python
# For session cleanup
session_cleanup_lock = RedisLock(
    redis_url=WEBSOCKET_REDIS_URL,
    lock_name=f"{REDIS_KEY_PREFIX}:session_cleanup_lock",
    timeout_secs=WEBSOCKET_REDIS_LOCK_TIMEOUT,  # default: 60s
    ...
)

# For usage cleanup
clean_up_lock = RedisLock(
    redis_url=WEBSOCKET_REDIS_URL,
    lock_name=f"{REDIS_KEY_PREFIX}:usage_cleanup_lock",
    timeout_secs=WEBSOCKET_REDIS_LOCK_TIMEOUT,
    ...
)
```

**Lock lifecycle**:
1. **Acquire**: `SET lock_name uuid NX EX 60` - succeeds only if no lock exists
2. **Renew**: Each cleanup iteration calls `SET lock_name uuid XX EX 60` - extends TTL
3. **Release**: On cleanup task exit, deletes the key if value matches our UUID
4. **Failover**: If the instance holding the lock crashes, the lock auto-expires after `WEBSOCKET_REDIS_LOCK_TIMEOUT` seconds, and another instance acquires it

In single-instance mode, lock functions are no-ops: `lambda: True`.

---

## Disconnect Event vs. Session Reaping

There are two paths for session cleanup:

### Path 1: Clean Disconnect
- Client disconnects gracefully (browser close, navigation, explicit disconnect)
- Server receives `disconnect` event immediately
- `SESSION_POOL[sid]` is deleted
- `USAGE_POOL` entries for this session are cleaned up
- `YdocManager.remove_user_from_all_documents(sid)` is called

### Path 2: Orphaned Session (Reaping)
- Client disappears without disconnect (network failure, instance crash, OOM kill)
- Engine.IO ping/pong may eventually detect and fire `disconnect` on the local instance
- **But**: If the instance that held the connection also crashed, no `disconnect` fires
- The session remains in `SESSION_POOL` (Redis hash) with a stale `last_seen_at`
- `periodic_session_pool_cleanup()` detects it after 120s and reaps it
- This is the safety net for multi-instance deployments

---

## Connection to Other Components

### Heartbeats + Redis
- `SESSION_POOL` is a `RedisDict` in multi-instance mode, so heartbeat timestamps are visible to all instances
- The cleanup lock ensures coordinated reaping across instances
- Single-instance mode uses plain Python dicts

### Heartbeats + SQLAlchemy
- Each heartbeat triggers `Users.update_last_active_by_id()`, which updates the `last_active_at` column in the database
- This provides a persistent record of user activity beyond the in-memory/Redis session state

### Heartbeats + WebSockets
- Heartbeats ride on the WebSocket connection established by Socket.IO
- If the WebSocket drops, the heartbeat interval is cleared client-side
- The Engine.IO ping/pong provides the first line of defense for connection health

### Heartbeats + ThreadPooling
- The `Users.update_last_active_by_id()` call in the heartbeat handler is a synchronous database operation called from an async context
- It runs on the default thread pool (governed by `THREAD_POOL_SIZE`)
