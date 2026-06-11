---
# Machine-readable anchor block — see Directive 8.
covers_files:
  - backend/open_webui/socket/main.py
  - backend/open_webui/socket/utils.py
  - backend/open_webui/main.py
  - backend/open_webui/utils/asgi_middleware.py
  - backend/open_webui/env.py
  - src/routes/+layout.svelte
  - src/lib/stores/index.ts
  - src/lib/components/common/RichTextInput/Collaboration.ts
covers_symbols:
  - { symbol: user_join, file: backend/open_webui/socket/main.py }
  - { symbol: get_event_emitter, file: backend/open_webui/socket/main.py }
  - { symbol: get_event_call, file: backend/open_webui/socket/main.py }
  - { symbol: _make_channel_emitter, file: backend/open_webui/socket/main.py }
  - { symbol: normalize_document_id, file: backend/open_webui/socket/main.py }
  - { symbol: WebsocketUpgradeGuardMiddleware, file: backend/open_webui/utils/asgi_middleware.py }
  - { symbol: setupSocket, file: src/routes/+layout.svelte }
  - { symbol: SocketIOCollaborationProvider, file: src/lib/components/common/RichTextInput/Collaboration.ts }
  - { symbol: SimpleAwareness, file: src/lib/components/common/RichTextInput/Collaboration.ts }
  - { symbol: socketConnected, file: src/lib/stores/index.ts }
  - { symbol: WEBSOCKET_MANAGER, file: backend/open_webui/env.py }
  - { symbol: WEBSOCKET_SERVER_PING_INTERVAL, file: backend/open_webui/env.py }
verified_against_commit: 304d2d673749691abad905b96230b30ddb77e145
---

# WebSockets

Open WebUI Extended uses Socket.IO (built on Engine.IO) for real-time bidirectional
communication between browser and server: live chat streaming, collaborative document
editing, channel messaging, model usage tracking, and session management.

> **Read this first — socket DB writes are async, not thread-pooled.** The event
> emitter and socket handlers `await` async model methods directly; there are **zero**
> `asyncio.to_thread()` calls in `socket/main.py` (verify:
> `grep -c to_thread backend/open_webui/socket/main.py` returns `0`). A previous version
> of this doc showed the emitter wrapping DB writes in `asyncio.to_thread()` — that is
> obsolete (see [sqlalchemy.md](./sqlalchemy.md) / [threadpooling.md](./threadpooling.md)).

---

## Relevant Files

### Backend

| File | Subject (grep for these symbols) |
|---|---|
| `backend/open_webui/socket/main.py` | `sio`, `connect`, `disconnect`, `user_join`, `heartbeat`, `usage`, `get_event_emitter`, `get_event_call`, `normalize_document_id`, ydoc handlers, cleanup tasks |
| `backend/open_webui/socket/utils.py` | `RedisDict`, `RedisLock`, `YdocManager` |
| `backend/open_webui/main.py` | `app.mount("/ws", socket_app)`; `app.add_middleware(WebsocketUpgradeGuardMiddleware)`; `asyncio.create_task(periodic_*_cleanup())` |
| `backend/open_webui/utils/asgi_middleware.py` | `WebsocketUpgradeGuardMiddleware` |
| `backend/open_webui/env.py` | `WEBSOCKET_*` env vars |
| `backend/open_webui/tasks.py` | distributed task management (Redis pub/sub) — see [redis.md](./redis.md) |

### Frontend

| File | Subject |
|---|---|
| `src/routes/+layout.svelte` | `setupSocket`, `io(...)` client config, `connect`/`disconnect` handlers, `heartbeatInterval`, `user-join` emit |
| `src/lib/stores/index.ts` | `socket` / `socketConnected` Svelte stores |
| `src/lib/components/common/RichTextInput/Collaboration.ts` | `SocketIOCollaborationProvider`, `SimpleAwareness` |

---

## Server Setup (`socket/main.py`)

### Socket.IO server

A single `sio = socketio.AsyncServer(...)` is created with `async_mode="asgi"`,
`always_connect=True`, and CORS from `SOCKETIO_CORS_ORIGINS`. Two things vary:

- **Transport**: `["websocket"]` when `ENABLE_WEBSOCKET_SUPPORT` is true, else `["polling"]`;
  `allow_upgrades` tracks the same flag.
- **Cross-instance manager**: when `WEBSOCKET_MANAGER == "redis"`, a
  `socketio.AsyncRedisManager` is attached as `client_manager` (its URL is the WebSocket
  Redis URL, rebuilt into a `redis+sentinel://` form when sentinels are configured).
  Without Redis, no manager is set and fan-out is local only.

> **Directive 5 — ping values come from symbols, not literals.** `ping_interval` and
> `ping_timeout` are set to `WEBSOCKET_SERVER_PING_INTERVAL` / `WEBSOCKET_SERVER_PING_TIMEOUT`
> (defaults `25` / `20` seconds at time of writing), **not** hard-coded `25`/`20`. See
> [heartbeats.md](./heartbeats.md) Layer 1 for how these drive dead-connection detection.

### ASGI mounting

`socketio.ASGIApp(sio, socketio_path="/ws/socket.io")` is exported as `app` and mounted
in `main.py` via `app.mount("/ws", socket_app)`.

### WebSocket upgrade guard

`WebsocketUpgradeGuardMiddleware` (a pure-ASGI middleware class in
`utils/asgi_middleware.py`, added via `app.add_middleware(...)`) rejects requests to
`/ws/socket.io` that claim `transport=websocket` but lack a valid `Upgrade: websocket` /
`Connection: upgrade` header pair, returning HTTP 400.

> **Directive 4/6 — it's a middleware class now, not a decorator.** A prior version of
> this doc showed an `@app.middleware("http")` function named `inspect_websocket`. The
> current implementation is the ASGI class above; the logic and rationale are unchanged —
> it works around python-engineio issue #367, where engineio mishandles such requests.

---

## Client Setup (`src/routes/+layout.svelte`)

`setupSocket(enableWebsocket)` builds the client via `io(WEBUI_BASE_URL, {...})`:

- **Reconnection**: enabled, `reconnectionDelay: 1000` → `reconnectionDelayMax: 5000`,
  `randomizationFactor: 0.5`.
- **Path**: `/ws/socket.io` (matches the server mount).
- **Transport**: `["websocket"]` when enabled, else `["polling", "websocket"]` (poll then
  upgrade).
- **Auth**: `{ token: localStorage.token }` in the handshake.

Library/connection events the client listens for: `connect`, `connect_error`,
`disconnect` (plus Socket.IO's built-in reconnection events). The socket instance is
published to the `socket` store and liveness to `socketConnected` (`stores/index.ts`).

---

## Application Events

### Session management

- **`connect`** (`@sio.event`, server): decodes the JWT from `auth["token"]`, looks up the
  user, stores `SESSION_POOL[sid] = {…user, last_seen_at}`, and joins the `user:{id}` room.
- **`user-join`** (`@sio.on("user-join")`, client→server): re-authenticates after
  reconnection, refreshes `SESSION_POOL`, rejoins `user:{id}` and (with the `channels`
  permission) the user's `channel:{id}` rooms, and returns `{id, name}`.
- **`heartbeat`** (client→server): refreshes `last_seen_at` and persists activity — see
  [heartbeats.md](./heartbeats.md).
- **`disconnect`** (`@sio.event`, server) — note the signature is `disconnect(sid, reason=None)`:
  deletes `SESSION_POOL[sid]`, removes the sid from `USAGE_POOL`, and calls
  `YDOC_MANAGER.remove_user_from_all_documents(sid)`.

### Channel messaging

- **`join-channels`** (client→server): joins `channel:{id}` rooms for every channel the
  authenticated user may access (admins, or users with the `channels` permission).
- **`events:channel`** (client→server, broadcast): the sender must already be in the room;
  `typing` is broadcast to the channel room, `last_read_at` updates the member's read
  marker in the DB.
- **`events:chat`** (client→server): handles `last_read_at` for direct chats
  (`Chats.update_chat_last_read_at_by_id`).

### Chat streaming

`get_event_emitter(request_info, update_db=True)` returns an async emitter for streaming
model output.

> **Directive 4/6 — two behaviors the old doc missed.**
> 1. **Channel mode**: when `request_info["chat_id"]` starts with `"channel:"`, the factory
>    returns a dedicated channel emitter (`_make_channel_emitter`) that writes model output
>    into a channel message instead of a chat. The default emitter handles per-user chats.
> 2. **Async DB persistence**: the default emitter emits the `events` payload to the
>    `user:{id}` room and then `await`s the async `Chats.*` methods directly (e.g.
>    `await Chats.upsert_message_to_chat_by_id_and_message_id(...)`). It does **not** use
>    `asyncio.to_thread()`.

Persisted `events` types (per the `event_type` branches): `status`, `message`
(appended), `replace` (full replacement), `embeds`, `files`, and `source`/`citation`.

`get_event_call()` (aliased `get_event_caller`) issues an RPC-style `sio.call("events", …, to=session_id, timeout=WEBSOCKET_EVENT_CALLER_TIMEOUT)`,
fast-failing if the session has left `SESSION_POOL` and returning an error dict on
`TimeoutError`.

### Model usage tracking

**`usage`** (client→server): if the sid is in `SESSION_POOL`, stamps
`USAGE_POOL[model_id][sid] = {"updated_at": <now>}`. Entries are expired by
`periodic_usage_pool_cleanup()` — see [heartbeats.md](./heartbeats.md).

### Collaborative document editing (Yjs)

Handlers: `join-note`, `ydoc:document:join`, `ydoc:document:state`,
`ydoc:document:update`, `ydoc:awareness:update`, `ydoc:document:leave`. State lives in
`YdocManager` (Redis Lists/Sets, or in-memory dicts) and clients sit in the
`doc_{document_id}` room.

> **Directive 6 — two security checks that look removable but are not.**
> - `normalize_document_id()` rewrites underscore-prefixed IDs (`note_abc`) back to the
>   colon form (`note:abc`) **before** authorization. `YdocManager` stores keys with `:`
>   replaced by `_`, so without this rewrite an attacker could pass `note_abc` to dodge the
>   `note:`-keyed access check. Do not "simplify" it away.
> - `ydoc:document:update` re-checks **write** permission on every update via
>   `AccessGrants.has_access(..., permission="write")`. Room membership only proves *read*
>   access, so this second check is deliberate — removing it would let any reader write.

`ydoc:document:update` also cancels pending save tasks, appends the update to
`YdocManager`, broadcasts to other editors (`skip_sid=sid`), and schedules a debounced
(~0.5s) DB save. `ydoc:document:leave` removes the user and clears the document when the
last editor leaves.

---

## Room Structure

| Room pattern | Audience | Joined when |
|---|---|---|
| `user:{user_id}` | all sessions of one user | `connect`, `user-join` |
| `channel:{channel_id}` | channel participants | `user-join`, `join-channels` |
| `note:{note_id}` | viewers of a note | `join-note` |
| `doc_{document_id}` | collaborative editors of a document | `ydoc:document:join` |

Helper functions in `socket/main.py`: `emit_to_users(event, data, user_ids)`,
`enter_room_for_users(room, user_ids)`, `get_session_ids_from_room(room)`,
`get_user_ids_from_room(room)`, and `disconnect_user_sessions(user_id)` (used to
invalidate cached role/permission data on role change or deletion).

---

## In-Memory vs. Redis-Backed State

Selection is by `WEBSOCKET_MANAGER` (`"redis"` ⇒ multi-instance). See [redis.md](./redis.md).

| State | Single-instance | Multi-instance (Redis) |
|---|---|---|
| `SESSION_POOL`, `USAGE_POOL`, `MODELS` | Python `dict` | `RedisDict` (Redis Hash) |
| Cleanup locks (`session_cleanup_lock`, `usage_cleanup_lock`) | no-op `lambda: True` | `RedisLock` (distributed mutex) |
| Socket.IO event fan-out | local only | `AsyncRedisManager` (pub/sub) |
| Yjs document state | in-memory dicts | Redis Lists + Sets |

---

## Environment Variables

Defaults are the fallbacks in `env.py` **at time of writing**; the symbols are the
source of truth. (Redis-specific WebSocket vars are detailed in [redis.md](./redis.md);
ping vars in [heartbeats.md](./heartbeats.md).)

| Variable | Default | Description |
|---|---|---|
| `ENABLE_WEBSOCKET_SUPPORT` | `True` | When `False`, server/client use HTTP long-polling instead of the WebSocket transport |
| `WEBSOCKET_MANAGER` | `""` | Set to `redis` for Redis-backed cross-instance fan-out |
| `WEBSOCKET_REDIS_URL` | `REDIS_URL` | Redis URL for the Socket.IO manager |
| `WEBSOCKET_REDIS_CLUSTER` | `REDIS_CLUSTER` | Cluster mode for WebSocket Redis |
| `WEBSOCKET_REDIS_OPTIONS` | `None` | JSON dict of extra redis-py options |
| `WEBSOCKET_REDIS_LOCK_TIMEOUT` | `60` | TTL (seconds) for distributed cleanup locks |
| `WEBSOCKET_SENTINEL_HOSTS` / `WEBSOCKET_SENTINEL_PORT` | `""` / `26379` | Sentinel hosts/port for WebSocket Redis |
| `WEBSOCKET_SERVER_LOGGING` | `False` | Socket.IO debug logging |
| `WEBSOCKET_SERVER_ENGINEIO_LOGGING` | `False` (falls back to `WEBSOCKET_SERVER_LOGGING`) | Engine.IO debug logging |
| `WEBSOCKET_SERVER_PING_INTERVAL` | `25` | Seconds between Engine.IO server pings |
| `WEBSOCKET_SERVER_PING_TIMEOUT` | `20` | Seconds to wait for a pong before disconnecting |
| `WEBSOCKET_EVENT_CALLER_TIMEOUT` | `None` | Timeout (seconds) for RPC-style `sio.call()` |

> **`WEBSOCKET_EVENT_CALLER_TIMEOUT` defaults to `None` (no timeout).** The value `300`
> is **only** the fallback used when the env var is set to a non-integer string — it is
> not the default. Verify in `env.py`.

---

## Frontend Collaborative Editing Provider (`Collaboration.ts`)

`SocketIOCollaborationProvider` is a custom Yjs provider that synchronizes CRDT updates
over Socket.IO instead of a raw WebSocket. Lifecycle (by emitted/received event):

- **Join**: emit `ydoc:document:join` with `document_id`, `user_id`, `user_name`, `user_color`.
- **Initial state**: listen for `ydoc:document:state`, apply with `Y.applyUpdate()`.
- **Send / receive updates**: on local Yjs `update`, emit `ydoc:document:update`; on
  inbound `ydoc:document:update`, apply with `Y.applyUpdate()`.
- **Awareness**: send/receive cursor and selection via `ydoc:awareness:update`.
- **Leave**: emit `ydoc:document:leave` on destruction.

`SimpleAwareness` is a lightweight awareness implementation (cursor/selection tracking)
that replaces the standard Yjs awareness protocol with a Socket.IO-native approach.

---

## Connection Lifecycle

```
1. Browser loads  ->  setupSocket() builds the io(...) client
2. Connect to /ws/socket.io (websocket, or polling->upgrade)
3. Server `connect`: decode JWT from auth.token, look up user,
   store in SESSION_POOL, join user:{id} room
4. Client `connect`: version check, start 30s heartbeat interval,
   emit `user-join` with the auth token
5. Server `user-join`: re-verify auth, join channel rooms, return {id, name}
6. Normal operation: events flow bidirectionally
7. Disconnect:
   - Client: clear heartbeat interval (and show a reconnect toast after a short delay)
   - Server `disconnect(sid, reason)`: clean up SESSION_POOL, USAGE_POOL, Yjs docs
```

---

## Verification Recipe

Run from the repo root. If any line's expectation is violated, the doc is stale and must
be re-audited before it is trusted.

```bash
# Socket DB writes are async (no to_thread in the socket layer)
test "$(grep -c to_thread backend/open_webui/socket/main.py)" = 0 && echo "no to_thread (expected)"
grep -rn "await Chats.upsert_message_to_chat_by_id_and_message_id" backend/open_webui/socket/main.py

# Server config pulls ping from symbols, attaches Redis manager conditionally
grep -rn "ping_interval=WEBSOCKET_SERVER_PING_INTERVAL\|ping_timeout=WEBSOCKET_SERVER_PING_TIMEOUT\|AsyncRedisManager" backend/open_webui/socket/main.py
grep -rn "socketio_path='/ws/socket.io'\|socketio_path=\"/ws/socket.io\"" backend/open_webui/socket/main.py
grep -rn "app.mount\(.\/ws." backend/open_webui/main.py

# Upgrade guard is an ASGI middleware class, not @app.middleware("http")
grep -rn "class WebsocketUpgradeGuardMiddleware" backend/open_webui/utils/asgi_middleware.py
grep -rn "add_middleware(WebsocketUpgradeGuardMiddleware)" backend/open_webui/main.py

# Key handlers + signatures
grep -rn "async def connect(\|async def disconnect(sid, reason\|async def user_join(\|def get_event_emitter\|def get_event_call\|def _make_channel_emitter\|@sio.on('events:chat')" backend/open_webui/socket/main.py

# Security-critical ydoc checks (Directive 6)
grep -rn "def normalize_document_id\|room membership only proves read access\|permission='write'" backend/open_webui/socket/main.py

# Event-caller timeout default is None; 300 is only the bad-value fallback
grep -rn "WEBSOCKET_EVENT_CALLER_TIMEOUT" backend/open_webui/env.py

# Frontend
grep -rn "setupSocket\|path: '/ws/socket.io'\|emit('user-join'" src/routes/+layout.svelte
grep -rn "class SocketIOCollaborationProvider\|class SimpleAwareness" src/lib/components/common/RichTextInput/Collaboration.ts
grep -rn "export const socket" src/lib/stores/index.ts
```
