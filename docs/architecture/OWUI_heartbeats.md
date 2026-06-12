---
# Machine-readable anchor block — see I.8.
covers_files:
  - src/routes/+layout.svelte
  - backend/open_webui/socket/main.py
  - backend/open_webui/socket/utils.py
  - backend/open_webui/models/users.py
  - backend/open_webui/env.py
covers_symbols:
  - { symbol: heartbeat, file: backend/open_webui/socket/main.py }
  - { symbol: SESSION_POOL_TIMEOUT, file: backend/open_webui/socket/main.py }
  - { symbol: periodic_session_pool_cleanup, file: backend/open_webui/socket/main.py }
  - { symbol: periodic_usage_pool_cleanup, file: backend/open_webui/socket/main.py }
  - { symbol: update_last_active_by_id, file: backend/open_webui/models/users.py }
  - { symbol: WEBSOCKET_SERVER_PING_INTERVAL, file: backend/open_webui/env.py }
  - { symbol: WEBSOCKET_SERVER_PING_TIMEOUT, file: backend/open_webui/env.py }
verified_against_commit: 304d2d673749691abad905b96230b30ddb77e145
---

# Heartbeats

The heartbeat system in Open WebUI Extended provides client liveness detection,
session reaping, and user activity tracking. It operates at multiple layers to
ensure robust detection of disconnected clients, especially in multi-instance
deployments where a client may be connected to one instance while another handles
cleanup.

---

## Relevant Files

| File | Subject (grep for these symbols) |
|---|---|
| `src/routes/+layout.svelte` | `heartbeatInterval` — client-side heartbeat emission |
| `backend/open_webui/socket/main.py` | `heartbeat`, `SESSION_POOL`, `SESSION_POOL_TIMEOUT`, `periodic_session_pool_cleanup`, `periodic_usage_pool_cleanup`, `USAGE_POOL`, `TIMEOUT_DURATION` |
| `backend/open_webui/socket/utils.py` | `RedisLock` — distributed cleanup coordination |
| `backend/open_webui/models/users.py` | `update_last_active_by_id` — DB activity write |
| `backend/open_webui/env.py` | `WEBSOCKET_SERVER_PING_INTERVAL`, `WEBSOCKET_SERVER_PING_TIMEOUT` |

---

## Three Layers of Heartbeat

The system uses three distinct mechanisms, each operating at a different level.

### Layer 1: Engine.IO Ping/Pong (transport level)

**Contract**: the Socket.IO server (via Engine.IO) detects dead TCP connections.
The server sends a `ping` frame at a fixed interval; the client must answer with a
`pong` within the timeout, or the server closes the connection and fires its
`disconnect` event.

The interval and timeout are passed to `socketio.AsyncServer(...)` in `socket/main.py`
from two env vars (defined in `env.py`):

| Env var | Default at time of writing | Meaning |
|---|---|---|
| `WEBSOCKET_SERVER_PING_INTERVAL` | `25` (seconds) | Time between server-initiated pings |
| `WEBSOCKET_SERVER_PING_TIMEOUT` | `20` (seconds) | Time to wait for a `pong` before disconnecting |

The defaults are the fallbacks assigned in `env.py` when the env var is unset or
unparseable — treat the symbols as the source of truth, not these copies.

**Characteristics** (falsifiable against the `AsyncServer` constructor args):
- Fully handled by the Socket.IO/Engine.IO library; transparent to application code.
- Detects network drops, client crashes, and browser-tab closes.
- Does **not** detect an application-level freeze in which the Socket.IO library is
  still able to answer pings.

### Layer 2: Application Heartbeat (client-initiated)

**Contract**: track user activity at the application level and refresh the
`last_seen_at` timestamp the server keeps per session.

- **Client** (`heartbeatInterval` in `+layout.svelte`): on a successful socket
  `connect`, the client starts an interval that emits a `heartbeat` event (empty
  payload) every 30 seconds while `_socket.connected` is true, and clears that
  interval on `disconnect`. The 30s cadence is a literal in the `setInterval` call,
  not a shared constant.
- **Server** (`heartbeat` handler in `socket/main.py`): looks up the session in
  `SESSION_POOL`; if present, rewrites the entry with a fresh `last_seen_at` (current
  Unix time) and **awaits** `Users.update_last_active_by_id(user["id"])`.

> **I.4 — contract, not a copy.** The handler `await`s
> `Users.update_last_active_by_id()` directly. That method is `async def` and runs its
> `UPDATE … SET last_active_at` through an `AsyncSession` (`get_async_db_context()` in
> `models/users.py`) — it is **not** a synchronous DB call dispatched to a thread pool.
> Any doc or refactor that treats it as sync (e.g. wrapping it in `run_in_executor`) is
> wrong.

**Characteristics**:
- Updates both the in-memory/Redis session state (`SESSION_POOL`) *and* the persistent
  `last_active_at` column.
- The client's 30s emit cadence is longer than the default ping interval (25s), so a
  client answering pings but not emitting heartbeats stays "alive" at the transport
  layer yet can still be reaped by Layer 3.

### Layer 3: Session Reaping (server-side cleanup)

**Contract**: `periodic_session_pool_cleanup()` removes orphaned `SESSION_POOL`
entries that stopped sending heartbeats (instance crash, network partition, stuck
client) so they do not leak indefinitely.

Behavior, expressed as invariants you can check against the function body:
- Runs as an `asyncio.create_task()` started in the `main.py` lifespan.
- Acquires a distributed `RedisLock` (`session_cleanup_lock`) up front and returns
  immediately if another node holds it — so exactly one instance runs the loop.
- Each iteration: renews the lock (exiting if renewal fails), then deletes any session
  whose age exceeds the threshold, using a **strict** comparison
  `now - last_seen_at > SESSION_POOL_TIMEOUT`.
- Sleeps for `SESSION_POOL_TIMEOUT` between scans, and releases the lock on exit.

The single magic number lives in one place:

| Symbol | Value at time of writing | Role |
|---|---|---|
| `SESSION_POOL_TIMEOUT` | `120` (seconds) | Both the reap age threshold *and* the inter-scan sleep |

---

## Timing: Reap Latency Is a Range, Not an Instant

Because the scan loop sleeps `SESSION_POOL_TIMEOUT` between passes and its phase
relative to a client's last heartbeat is arbitrary, reaping is **not** a single
deterministic moment. Model it as a range and a precondition:

- **Precondition**: reaping only matters on the path where the Engine.IO `disconnect`
  never fired — e.g. the instance holding the connection died, so no `disconnect`
  handler ran to delete the session. In the normal case, the `disconnect` handler
  removes the `SESSION_POOL` entry (and its `USAGE_POOL` entries and ydoc memberships)
  long before the reaper looks.
- **Latency range**: a session is removed on the first scan that observes
  `now - last_seen_at > SESSION_POOL_TIMEOUT`. Depending on where the client's last
  heartbeat fell within the loop's sleep window, that lands anywhere from just over
  `SESSION_POOL_TIMEOUT` to roughly `2 × SESSION_POOL_TIMEOUT` after the last
  heartbeat.

The two cleanup paths:

1. **Clean disconnect** — client closes gracefully (tab close, navigation, explicit
   disconnect). The server's `disconnect` handler fires, deletes `SESSION_POOL[sid]`,
   cleans this sid out of `USAGE_POOL`, and calls
   `YDOC_MANAGER.remove_user_from_all_documents(sid)`.
2. **Orphaned session (reaping)** — client vanishes without a `disconnect` (network
   failure, instance crash, OOM kill). If the owning instance also died, no
   `disconnect` fires anywhere; the entry sits in `SESSION_POOL` (a Redis hash in
   multi-instance mode) with a stale `last_seen_at` until `periodic_session_pool_cleanup()`
   reaps it. This is the multi-instance safety net.

---

## Usage Pool Cleanup (parallel mechanism)

`periodic_usage_pool_cleanup()` is a separate loop that expires model-usage entries
rather than sessions:

- Tracks active model inference: clients emit `usage` events, which stamp
  `USAGE_POOL[model_id][sid]["updated_at"]`.
- Expiry threshold is `TIMEOUT_DURATION` (3 seconds at time of writing) — far shorter
  than `SESSION_POOL_TIMEOUT`, because it reflects in-flight inference, not session
  liveness.
- Also guarded by a distributed `RedisLock` (`usage_cleanup_lock`), but its lock
  acquisition retries with a randomized backoff (see `periodic_usage_pool_cleanup`),
  whereas session cleanup skips immediately if the lock is held.

---

## Distributed Lock Coordination

Both cleanup loops use `RedisLock` (`socket/utils.py`) so only one instance runs each
loop in a multi-instance deployment. The locks are named with the `REDIS_KEY_PREFIX`
namespace: `…:session_cleanup_lock` and `…:usage_cleanup_lock`.

Lock contract (check against `RedisLock.aquire_lock` / `renew_lock` / `release_lock`):
- **Acquire**: `SET name uuid NX EX timeout` — succeeds only if no lock exists.
- **Renew**: `SET name uuid XX EX timeout` — extends the TTL only if the lock still
  exists; each loop iteration renews.
- **Release**: deletes the key only when its value matches this instance's UUID, so one
  instance can never release another's lock.
- **Failover**: if the lock holder dies, the key auto-expires after
  `WEBSOCKET_REDIS_LOCK_TIMEOUT` (60s at time of writing, from `env.py`) and another
  instance acquires it.

In single-instance mode (`WEBSOCKET_MANAGER` not `redis`), the lock acquire/renew/
release functions are no-ops bound to `lambda: True`, and `SESSION_POOL` / `USAGE_POOL`
are plain Python dicts.

---

## Connection to Other Components

- **Redis** — In multi-instance mode `SESSION_POOL` is a `RedisDict`, so heartbeat
  timestamps are visible to every instance and the cleanup lock coordinates reaping
  across them. See [redis.md](./redis.md).
- **SQLAlchemy** — each heartbeat awaits `Users.update_last_active_by_id()`, persisting
  `last_active_at` beyond the in-memory/Redis session state. It is fully async (see the
  I.4 note above).
- **WebSockets** — heartbeats ride the Socket.IO connection; the client clears its
  interval when the socket drops, and Engine.IO ping/pong is the first line of defense
  for connection health.

---

## Verification Recipe

Run from the repo root. If any line returns nothing, the doc is stale and must be
re-audited before it is trusted.

```bash
# Client-side heartbeat emitter
grep -rn "heartbeatInterval" src/routes/+layout.svelte

# Server-side heartbeat handler + the awaited async DB write
grep -rn "async def heartbeat" backend/open_webui/socket/main.py
grep -rn "await Users.update_last_active_by_id" backend/open_webui/socket/main.py
grep -rn "async def update_last_active_by_id" backend/open_webui/models/users.py

# Session reaping: function, threshold constant, strict comparison
grep -rn "def periodic_session_pool_cleanup" backend/open_webui/socket/main.py
grep -rn "SESSION_POOL_TIMEOUT" backend/open_webui/socket/main.py
grep -rn "0) > SESSION_POOL_TIMEOUT" backend/open_webui/socket/main.py

# Usage cleanup + its threshold
grep -rn "def periodic_usage_pool_cleanup" backend/open_webui/socket/main.py
grep -rn "TIMEOUT_DURATION = " backend/open_webui/socket/main.py

# Ping/pong config + defaults
grep -rn "WEBSOCKET_SERVER_PING_INTERVAL\|WEBSOCKET_SERVER_PING_TIMEOUT" backend/open_webui/env.py

# Distributed cleanup locks
grep -rn "session_cleanup_lock\|usage_cleanup_lock" backend/open_webui/socket/main.py
```
