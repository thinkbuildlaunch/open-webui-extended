---
# Machine-readable anchor block — see Directive 8 / Directive 11.
covers_files:
  - backend/open_webui/socket/main.py
  - backend/open_webui/socket/utils.py
  - backend/open_webui/utils/redis.py
  - backend/open_webui/models/access_grants.py
covers_symbols:
  - { symbol: user_join, file: backend/open_webui/socket/main.py }
  - { symbol: get_event_emitter, file: backend/open_webui/socket/main.py }
  - { symbol: _make_channel_emitter, file: backend/open_webui/socket/main.py }
  - { symbol: channel_events, file: backend/open_webui/socket/main.py }
  - { symbol: usage, file: backend/open_webui/socket/main.py }
  - { symbol: ydoc_document_join, file: backend/open_webui/socket/main.py }
  - { symbol: yjs_document_update, file: backend/open_webui/socket/main.py }
  - { symbol: normalize_document_id, file: backend/open_webui/socket/main.py }
  - { symbol: periodic_session_pool_cleanup, file: backend/open_webui/socket/main.py }
  - { symbol: periodic_usage_pool_cleanup, file: backend/open_webui/socket/main.py }
  - { symbol: RedisDict, file: backend/open_webui/socket/utils.py }
  - { symbol: RedisLock, file: backend/open_webui/socket/utils.py }
  - { symbol: YdocManager, file: backend/open_webui/socket/utils.py }
verified_against_commit: 933422f032f5b958e7c519825ad94505d56eaaf7
---

# Real-Time Communication (`socket/main.py`, `socket/utils.py`)

The Socket.IO layer: session/presence state, chat-completion event streaming, channel
messaging, and CRDT collaborative editing — single-instance or Redis-distributed.

> **Heavy overlap — read alongside.** [websockets.md](./websockets.md) documents the
> Socket.IO server setup, client, event/room model, and the ydoc handlers;
> [heartbeats.md](./heartbeats.md) covers presence/reaping; [redis.md](./redis.md) covers
> the `RedisDict`/`RedisLock`/`YdocManager` key patterns. This doc is the socket-internals
> view and is a **strong merge candidate** with `websockets.md`.

> **What was wrong in the original guide (it was severely stale/partly fictional).**
> - **There is no `USER_POOL`.** The pools are `SESSION_POOL`, `USAGE_POOL`, and `MODELS`;
>   per-user fan-out uses Socket.IO **rooms** (`user:{id}`), not a `USER_POOL` dict.
> - **Event names**: the server emits `events` (chat streaming) and listens on
>   `events:channel` / `events:chat` — **not** `chat-events` / `channel-events`.
> - **Async**: model lookups are awaited (`await Users.get_user_by_id`, `await Notes.get_note_by_id`),
>   and the emitter awaits async `Chats.*` writes (no `to_thread`).
> - **Access control**: uses `AccessGrants.has_access(...)` and `has_permission(...)`, not
>   `has_access(..., access_control=...)` / `get_users_with_access`.
> - **Sentinel URL** is built by `build_sentinel_url(...)` (not `get_sentinel_url_from_env`);
>   `cors_allowed_origins=SOCKETIO_CORS_ORIGINS` (not `[]`); ping interval/timeout are set.

---

## 1. Overview

`socket/main.py` builds one `socketio.AsyncServer` and registers the event handlers;
`socket/utils.py` provides the Redis-backed primitives. Shared state lives in
`SESSION_POOL` (`sid → {user fields, last_seen_at}`), `USAGE_POOL`
(`model_id → {sid: {updated_at}}`), and `MODELS` — all `RedisDict`s in multi-instance mode,
plain dicts otherwise.

## 2. Imports & Integration

`asyncio`, `socketio`, `pycrdt as Y`, `redis.asyncio as aioredis`. App integration:
`Users`/`UserNameResponse`, `Channels`, `Chats`, `Notes`/`NoteUpdateForm`, `AccessGrants`;
`decode_token`, **`has_permission`** (from `utils/access_control`); `create_task` /
`stop_item_tasks`; `RedisDict`/`RedisLock`/`YdocManager`; and `build_sentinel_url` /
`get_redis_connection` from `utils/redis`. (The original's
`from utils.access_control import has_access, get_users_with_access` is wrong.)

## 3. Distributed Server & State

When `WEBSOCKET_MANAGER == "redis"`, a `socketio.AsyncRedisManager` is attached as
`client_manager` (its URL rebuilt to `redis+sentinel://` via `build_sentinel_url` when
sentinels are configured). The server always sets `cors_allowed_origins=SOCKETIO_CORS_ORIGINS`,
the transport per `ENABLE_WEBSOCKET_SUPPORT`, and `ping_interval`/`ping_timeout` from env
(see [heartbeats.md](./heartbeats.md)). In Redis mode `SESSION_POOL`/`USAGE_POOL`/`MODELS`
are `RedisDict`s and the cleanup locks are real `RedisLock`s; otherwise they are local dicts
and the lock funcs are `lambda: True` no-ops.

## 4. Collaborative Editing (Yjs / `pycrdt`)

CRDT documents are managed by `YdocManager` (§8). Handlers (all in `socket/main.py`):

- **`ydoc_document_join`** (`@sio.on("ydoc:document:join")`) — resolves `document_id` via
  **`normalize_document_id`** (see the Directive-6 note), enforces read access for `note:` docs
  via `AccessGrants.has_access`, registers the session in `YdocManager`, joins the
  `doc_{document_id}` room, reconstructs the doc from stored updates, and emits
  `ydoc:document:state` to the joiner plus `ydoc:user:joined` to the room.
- **`yjs_document_update`** (`@sio.on("ydoc:document:update")`) — verifies room membership and
  **re-checks write permission** (room membership only proves read), cancels pending saves
  (`stop_item_tasks`), appends to `YdocManager`, broadcasts to other editors (`skip_sid=sid`),
  and schedules a debounced (~0.5s) DB save via `create_task`.
- Plus `ydoc:document:state`, `ydoc:awareness:update`, `ydoc:document:leave` (clears the doc
  when the last editor leaves).

> **Directive 6 — `normalize_document_id` is a security control.** `YdocManager` stores keys
> with `:`→`_`, so `normalize_document_id` rewrites underscore-prefixed ids back to the colon
> form *before* the `note:` access check — without it, `note_abc` would dodge authorization.
> The per-update write re-check is likewise deliberate.

## 5. Presence & Activity

- **`connect`** (`@sio.event`) — decodes the JWT, `await Users.get_user_by_id`, stores
  `SESSION_POOL[sid] = {**user fields (minus profile/bio/etc.), "last_seen_at": now}`, and
  joins `user:{user.id}`. (No `USER_POOL`.)
- **`user_join`** (`@sio.on("user-join")`) — re-auths after reconnect, refreshes `SESSION_POOL`,
  rejoins `user:{id}` and (with the `features.channels` permission) the user's `channel:{id}`
  rooms; returns `{id, name}`.
- **`disconnect(sid, reason=None)`** — deletes the `SESSION_POOL` entry, cleans `USAGE_POOL`,
  and calls `YDOC_MANAGER.remove_user_from_all_documents(sid)`.
- **`periodic_session_pool_cleanup`** reaps orphaned sessions past `SESSION_POOL_TIMEOUT`;
  **`periodic_usage_pool_cleanup`** expires `USAGE_POOL` entries past `TIMEOUT_DURATION`
  (3s). Both run under a distributed `RedisLock`. See [heartbeats.md](./heartbeats.md).

## 6. Event Emission & Chat Integration

**`get_event_emitter(request_info, update_db=True)`** returns an async emitter:

- If `request_info["chat_id"]` starts with `"channel:"` it returns a dedicated
  **`_make_channel_emitter`** (writes model output into a channel message, throttled).
- Otherwise it `await sio.emit("events", {chat_id, message_id, data}, room=f"user:{user_id}")`
  — one emit to the user's room (Socket.IO fans out to all sessions), **not** a manual loop
  over a `USER_POOL`, and the event name is **`events`** (not `chat-events`).
- When `update_db`, it `await`s the async `Chats.*` methods per `event_data["type"]`
  (`status`, `message` (append), `replace`, `embeds`, `files`, `source`/`citation`).

`get_event_call` (aliased `get_event_caller`) does RPC-style `sio.call("events", …)` with a
timeout. **`usage`** (`@sio.on("usage")`) stamps `USAGE_POOL[model_id][sid]["updated_at"]`.

## 7. Channels & Access Control

- **`channel_events`** (`@sio.on("events:channel")`) — the sender must already be in the
  `channel:{id}` room; `typing` is broadcast to the room (with a `UserNameResponse`),
  `last_read_at` updates the member's marker. (Event name is `events:channel`, not
  `channel-events`.) `events:chat` handles direct-chat `last_read_at`.
- **`join_note` / `join_channel`** authenticate, then gate via `AccessGrants.has_access`
  (notes) or `has_permission(..., "features.channels")` (channels) before `enter_room`.
- **`disconnect_user_sessions(user_id)`** force-disconnects a user's sessions (used on
  role/permission changes) so cached `SESSION_POOL` data is re-fetched on reconnect.

## 8. Redis-Backed Data Structures (`socket/utils.py`)

- **`RedisDict(name, redis_url, redis_sentinels=[], redis_cluster=False)`** — a Hash-backed
  dict (`HSET`/`HGET`/…; JSON values). Its `set(mapping)` deliberately **never `DELETE`s the
  hash** (HSET new + HDEL stale, with a per-process signature skip-cache) — see the Directive-6
  note in [redis.md](./redis.md).
- **`RedisLock(redis_url, lock_name, timeout_secs, redis_sentinels=[], redis_cluster=False)`** —
  `aquire_lock` (`SET NX EX`), `renew_lock` (`SET XX EX`), `release_lock` (delete iff the stored
  UUID matches). Used by the two cleanup loops.
- **`YdocManager(redis=None, redis_key_prefix=f"{REDIS_KEY_PREFIX}:ydoc:documents")`** — stores
  ordered updates (Redis List or in-memory) and active users (Redis Set), with **rolling
  compaction** at `COMPACTION_THRESHOLD` (500) and a per-session reverse index so disconnect
  cleanup avoids a keyspace `SCAN`. The original's `append_to_updates` omitted compaction and
  hard-coded the key prefix.

---

## Verification Recipe

Run from the repo root. Symbol resolution for manual `git log -L` uses the overrides in
`docs/DOCUMENTATION_STANDARD.md`.

```bash
# No USER_POOL; the real pools + 'events' emit
grep -rn "USER_POOL" backend/open_webui/socket/main.py || echo "no USER_POOL (expected)"
grep -rn "SESSION_POOL = \|USAGE_POOL = \|MODELS = \|sio.emit('events'" backend/open_webui/socket/main.py | head

# Real event names (events:channel / events:chat, not channel-events/chat-events)
grep -rn "@sio.on('events:channel')\|@sio.on('events:chat')\|chat-events\|channel-events" backend/open_webui/socket/main.py

# Async + AccessGrants/has_permission; sentinel URL builder
grep -rn "await Users.get_user_by_id\|await Notes.get_note_by_id\|AccessGrants.has_access\|has_permission\|build_sentinel_url\|SOCKETIO_CORS_ORIGINS" backend/open_webui/socket/main.py | head

# Emitter: channel mode + async Chats writes (no USER_POOL loop)
grep -rn "def get_event_emitter\|def _make_channel_emitter\|await Chats.upsert_message_to_chat_by_id_and_message_id" backend/open_webui/socket/main.py

# ydoc security: normalize + write re-check
grep -rn "def normalize_document_id\|room membership only proves read access\|permission='write'" backend/open_webui/socket/main.py

# utils classes carry redis_cluster + compaction
grep -rn "class RedisDict\|class RedisLock\|class YdocManager\|redis_cluster=False\|COMPACTION_THRESHOLD = 500\|never DELETE the whole hash" backend/open_webui/socket/utils.py
```
