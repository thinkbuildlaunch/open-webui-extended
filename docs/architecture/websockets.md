# WebSockets

Open WebUI Extended uses Socket.IO (built on Engine.IO) for real-time bidirectional communication between the browser and server. This enables live chat streaming, collaborative document editing, channel messaging, model usage tracking, and session management.

---

## Relevant Files

### Backend
| File | Purpose |
|---|---|
| `backend/open_webui/socket/main.py` | Core Socket.IO server: event handlers, session management, Yjs collaboration, cleanup tasks |
| `backend/open_webui/socket/utils.py` | `RedisDict`, `RedisLock`, `YdocManager` utility classes |
| `backend/open_webui/main.py` (line 1524) | Mounts Socket.IO app at `/ws` |
| `backend/open_webui/main.py` (lines 1497-1512) | WebSocket upgrade validation middleware |
| `backend/open_webui/main.py` (lines 648-649) | Starts periodic cleanup background tasks |
| `backend/open_webui/env.py` (lines 726-799) | WebSocket environment variable definitions |
| `backend/open_webui/tasks.py` | Distributed task management using Redis pub/sub |

### Frontend
| File | Purpose |
|---|---|
| `src/routes/+layout.svelte` (lines 107-187) | Socket.IO client setup, connection events, heartbeat |
| `src/lib/stores/index.ts` (line 29) | Global Svelte store for the socket instance |
| `src/lib/components/common/RichTextInput/Collaboration.ts` | Yjs collaborative editing provider via Socket.IO |

---

## Server Setup

### Socket.IO Server Creation (`socket/main.py`)

The server is created with different configurations depending on whether Redis is enabled:

```python
# With Redis (multi-instance)
if WEBSOCKET_MANAGER == "redis":
    mgr = socketio.AsyncRedisManager(WEBSOCKET_REDIS_URL, redis_options=WEBSOCKET_REDIS_OPTIONS)
    sio = socketio.AsyncServer(
        cors_allowed_origins=SOCKETIO_CORS_ORIGINS,
        async_mode="asgi",
        transports=["websocket"],        # or ["polling"] if ENABLE_WEBSOCKET_SUPPORT=False
        allow_upgrades=ENABLE_WEBSOCKET_SUPPORT,
        always_connect=True,
        client_manager=mgr,              # Redis-backed manager for cross-instance events
        ping_interval=25,                # Engine.IO ping interval
        ping_timeout=20,                 # Engine.IO ping timeout
    )

# Without Redis (single-instance)
else:
    sio = socketio.AsyncServer(
        # Same config but no client_manager
    )
```

### ASGI Mounting

The Socket.IO ASGI app is mounted at `/ws`:

```python
# socket/main.py
app = socketio.ASGIApp(sio, socketio_path="/ws/socket.io")

# main.py
app.mount("/ws", socket_app)
```

### WebSocket Upgrade Middleware (`main.py`)

A middleware validates WebSocket upgrade requests before they reach Socket.IO:

```python
@app.middleware("http")
async def inspect_websocket(request: Request, call_next):
    if "/ws/socket.io" in request.url.path and request.query_params.get("transport") == "websocket":
        upgrade = (request.headers.get("Upgrade") or "").lower()
        connection = (request.headers.get("Connection") or "").lower().split(",")
        if upgrade != "websocket" or "upgrade" not in connection:
            return JSONResponse(status_code=400, content={"detail": "Invalid WebSocket upgrade request"})
    return await call_next(request)
```

This works around an [upstream Engine.IO issue](https://github.com/miguelgrinberg/python-engineio/issues/367).

---

## Client Setup

### Socket.IO Connection (`src/routes/+layout.svelte`)

```javascript
const _socket = io(`${WEBUI_BASE_URL}` || undefined, {
    reconnection: true,
    reconnectionDelay: 1000,
    reconnectionDelayMax: 5000,
    randomizationFactor: 0.5,
    path: '/ws/socket.io',
    transports: enableWebsocket ? ['websocket'] : ['polling', 'websocket'],
    auth: { token: localStorage.token }
});
```

**Connection parameters**:
- **Reconnection**: Enabled with exponential backoff (1s to 5s, randomized)
- **Path**: `/ws/socket.io` matches the server mount
- **Transport**: Pure WebSocket when enabled; falls back to polling + WebSocket upgrade otherwise
- **Auth**: JWT token sent in the `auth` handshake object

### Client Events

| Event | Direction | Purpose |
|---|---|---|
| `connect` | Server -> Client | Connection established |
| `connect_error` | Server -> Client | Connection failed |
| `disconnect` | Server -> Client | Connection lost |
| `reconnect_attempt` | Library | Reconnection in progress |
| `reconnect_failed` | Library | All reconnection attempts exhausted |

---

## Socket.IO Events (Application Level)

### Session Management

#### `connect` (server-side)
```python
@sio.event
async def connect(sid, environ, auth):
    # Decode JWT token from auth
    # Look up user in database
    # Store in SESSION_POOL with last_seen_at
    # Join user:{id} room
```

#### `user-join` (client -> server)
Emitted after reconnection to re-establish the session:
```python
@sio.on("user-join")
async def user_join(sid, data):
    # Re-authenticate via token
    # Update SESSION_POOL
    # Join user:{id} room
    # Join all accessible channel rooms
    return {"id": user.id, "name": user.name}
```

#### `heartbeat` (client -> server)
See [Heartbeats documentation](./heartbeats.md) for full details.

#### `disconnect` (server-side)
```python
@sio.event
async def disconnect(sid):
    # Remove from SESSION_POOL
    # Clean up USAGE_POOL entries
    # Remove from all Yjs documents
```

### Channel Messaging

#### `join-channels` (client -> server)
```python
@sio.on("join-channels")
async def join_channel(sid, data):
    # Authenticate user
    # Join channel:{id} rooms for all accessible channels
```

#### `events:channel` (client -> server, broadcast)
Handles typing indicators and read receipts:
```python
@sio.on("events:channel")
async def channel_events(sid, data):
    # Verify user is in the channel room
    if event_type == "typing":
        # Broadcast typing indicator to channel room
    elif event_type == "last_read_at":
        # Update member's last_read_at in database
```

### Chat Streaming

#### `events` (server -> client)
The `get_event_emitter()` function creates an emitter for streaming chat responses:

```python
def get_event_emitter(request_info, update_db=True):
    async def __event_emitter__(event_data):
        await sio.emit("events", {
            "chat_id": chat_id,
            "message_id": message_id,
            "data": event_data,
        }, room=f"user:{user_id}")

        # Also persist to database via asyncio.to_thread()
        if event_type == "message":
            await asyncio.to_thread(Chats.upsert_message_to_chat_by_id_and_message_id, ...)
```

**Supported event types**:
| Type | Purpose |
|---|---|
| `status` | Status updates during processing |
| `message` | Incremental message content (appended) |
| `replace` | Complete message content replacement |
| `embeds` | Rich embed attachments |
| `files` | File attachments |
| `source` / `citation` | RAG source citations |

#### `get_event_call()` (server -> client, with response)
For bidirectional RPC-style calls with timeout:

```python
response = await sio.call(
    "events", event_data,
    to=request_info["session_id"],
    timeout=WEBSOCKET_EVENT_CALLER_TIMEOUT,  # default: 300s
)
```

### Model Usage Tracking

#### `usage` (client -> server)
```python
@sio.on("usage")
async def usage(sid, data):
    model_id = data["model"]
    USAGE_POOL[model_id] = {
        **(USAGE_POOL[model_id] if model_id in USAGE_POOL else {}),
        sid: {"updated_at": int(time.time())},
    }
```

### Collaborative Document Editing (Yjs)

#### `join-note` (client -> server)
Joins a note room with access control verification.

#### `ydoc:document:join` (client -> server)
```python
@sio.on("ydoc:document:join")
async def ydoc_document_join(sid, data):
    # Verify access to document
    # Add user to YdocManager
    # Join doc_{document_id} room
    # Reconstruct Yjs document from stored updates
    # Send full state to joining client
    # Notify other participants
```

#### `ydoc:document:update` (client -> server, broadcast)
```python
@sio.on("ydoc:document:update")
async def yjs_document_update(sid, data):
    # Cancel pending save tasks for this document
    # Append update to YdocManager
    # Broadcast to all other editors (skip_sid=sid)
    # Schedule debounced save (0.5s) to database
```

#### `ydoc:awareness:update` (client -> server, broadcast)
Cursor positions and selections, broadcast to all other editors.

#### `ydoc:document:leave` (client -> server)
```python
@sio.on("ydoc:document:leave")
async def yjs_document_leave(sid, data):
    # Remove user from YdocManager
    # Leave doc room
    # Notify other participants
    # If no users left, clear document from Redis/memory
```

---

## Room Structure

Socket.IO rooms are used to target messages to specific audiences:

| Room Pattern | Purpose | Joined When |
|---|---|---|
| `user:{user_id}` | All sessions of a specific user | `connect`, `user-join` |
| `channel:{channel_id}` | All participants in a channel | `user-join`, `join-channels` |
| `note:{note_id}` | Users viewing a specific note | `join-note` |
| `doc_{document_id}` | Users collaboratively editing a document | `ydoc:document:join` |

### Utility Functions for Room Operations

```python
async def emit_to_users(event, data, user_ids):
    """Send event to multiple users via their user:{id} rooms."""
    for user_id in user_ids:
        await sio.emit(event, data, room=f"user:{user_id}")

async def enter_room_for_users(room, user_ids):
    """Make all sessions of users join a room."""
    for user_id in user_ids:
        session_ids = get_session_ids_from_room(f"user:{user_id}")
        for sid in session_ids:
            await sio.enter_room(sid, room)

def get_user_ids_from_room(room):
    """Get unique user IDs from all sessions in a room."""
    active_session_ids = get_session_ids_from_room(room)
    return list(set([SESSION_POOL.get(sid)["id"] for sid in active_session_ids ...]))
```

---

## In-Memory vs. Redis-Backed State

| Data Structure | Single-Instance | Multi-Instance (Redis) |
|---|---|---|
| `SESSION_POOL` | Python `dict` | `RedisDict` (Redis Hash) |
| `USAGE_POOL` | Python `dict` | `RedisDict` (Redis Hash) |
| `MODELS` | Python `dict` | `RedisDict` (Redis Hash) |
| Cleanup locks | `lambda: True` (no-op) | `RedisLock` (distributed mutex) |
| Socket.IO event fan-out | Local only | `AsyncRedisManager` (pub/sub) |
| Yjs document state | In-memory dicts | Redis Lists + Sets |

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `ENABLE_WEBSOCKET_SUPPORT` | `True` | Enable WebSocket transport. When `False`, uses HTTP long-polling only. |
| `WEBSOCKET_MANAGER` | `""` | Set to `redis` to enable Redis-backed cross-instance event broadcasting |
| `WEBSOCKET_REDIS_URL` | `REDIS_URL` | Redis URL for the Socket.IO manager (can be different from main Redis) |
| `WEBSOCKET_REDIS_CLUSTER` | `REDIS_CLUSTER` | Enable Redis Cluster mode for WebSocket Redis |
| `WEBSOCKET_REDIS_OPTIONS` | `None` | JSON dict of redis-py options (e.g., `{"socket_connect_timeout": 5}`) |
| `WEBSOCKET_REDIS_LOCK_TIMEOUT` | `60` | TTL for distributed cleanup locks in seconds |
| `WEBSOCKET_SENTINEL_HOSTS` | `""` | Sentinel hosts for WebSocket Redis |
| `WEBSOCKET_SENTINEL_PORT` | `26379` | Sentinel port for WebSocket Redis |
| `WEBSOCKET_SERVER_LOGGING` | `False` | Enable Socket.IO debug logging |
| `WEBSOCKET_SERVER_ENGINEIO_LOGGING` | `False` | Enable Engine.IO debug logging |
| `WEBSOCKET_SERVER_PING_INTERVAL` | `25` | Seconds between Engine.IO server pings |
| `WEBSOCKET_SERVER_PING_TIMEOUT` | `20` | Seconds to wait for pong before disconnecting |
| `WEBSOCKET_EVENT_CALLER_TIMEOUT` | `None` | Timeout for RPC-style `sio.call()` in seconds (default behavior: no timeout; fallback: 300s) |

---

## Frontend Collaborative Editing Provider

### `SocketIOCollaborationProvider` (`Collaboration.ts`)

A custom Yjs provider that uses Socket.IO instead of WebSocket for Yjs CRDT synchronization:

**Lifecycle**:
1. **Join**: Emit `ydoc:document:join` with `document_id`, `user_id`, `user_name`, `user_color`
2. **Receive state**: Listen for `ydoc:document:state`, apply with `Y.applyUpdate()`
3. **Send updates**: On local Yjs `update` event, emit `ydoc:document:update`
4. **Receive updates**: Listen for `ydoc:document:update`, apply with `Y.applyUpdate()`
5. **Awareness**: Send/receive cursor positions via `ydoc:awareness:update`
6. **Leave**: Emit `ydoc:document:leave` on editor destruction

**Custom `SimpleAwareness`**: A lightweight awareness implementation for cursor/selection tracking, replacing the standard Yjs awareness protocol with a Socket.IO-native approach.

---

## Connection Lifecycle

```
1. Browser loads  -->  setupSocket() called
2. Socket.IO connects to /ws/socket.io (WebSocket or polling)
3. Server: connect event fires
   - Decode JWT from auth.token
   - Look up user in DB
   - Store in SESSION_POOL
   - Join user:{id} room
4. Client: connect event fires
   - Check version compatibility
   - Start 30s heartbeat interval
   - Emit user-join with auth token
5. Server: user-join handler
   - Re-verify auth
   - Join channel rooms
   - Return {id, name}
6. Normal operation: events flow bidirectionally
7. Disconnect:
   - Client: clear heartbeat interval
   - Server: clean up SESSION_POOL, USAGE_POOL, Yjs documents
```
