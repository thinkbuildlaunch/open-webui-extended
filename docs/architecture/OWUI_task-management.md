---
# Machine-readable anchor block — see Directive 8 / Directive 11.
covers_files:
  - backend/open_webui/tasks.py
  - backend/open_webui/env.py
covers_symbols:
  - { symbol: create_task, file: backend/open_webui/tasks.py }
  - { symbol: redis_cleanup_task, file: backend/open_webui/tasks.py }
  - { symbol: redis_save_task, file: backend/open_webui/tasks.py }
  - { symbol: redis_send_command, file: backend/open_webui/tasks.py }
  - { symbol: redis_task_command_listener, file: backend/open_webui/tasks.py }
  - { symbol: redis_list_tasks, file: backend/open_webui/tasks.py }
  - { symbol: stop_task, file: backend/open_webui/tasks.py }
  - { symbol: stop_item_tasks, file: backend/open_webui/tasks.py }
  - { symbol: list_task_ids_by_item_id, file: backend/open_webui/tasks.py }
  - { symbol: has_active_tasks, file: backend/open_webui/tasks.py }
  - { symbol: get_active_chat_ids, file: backend/open_webui/tasks.py }
verified_against_commit: 7f29bbfa456dfca8f1bc4acb3e967253c8834948
---

# Task Management System (`tasks.py`)

> **Scope note.** This is `backend/open_webui/tasks.py` — the runtime registry that tracks
> and cancels long-running `asyncio` operations (chat completions, background jobs) across
> instances. It is a **different file** from `utils/task.py` (prompt templates); see
> [task-templates.md](./task-templates.md). The Redis backbone it rides on is documented in
> [redis.md](./redis.md); this doc focuses on the task lifecycle. A future consolidation of
> the two "task" docs is plausible.

`tasks.py` coordinates long-running operations with a **dual layer**: an in-process
`asyncio.Task` registry for direct control, plus optional Redis state + pub/sub so a task
started on one instance can be listed and cancelled from any instance.

---

## 1. Overview

- In-process registries for immediate control: `tasks` (`task_id → asyncio.Task`) and
  `item_tasks` (`item_id → [task_id]`).
- Optional Redis mirror (a hash + per-item sets) for cross-instance visibility.
- A Redis pub/sub channel carries `stop` commands so any instance can cancel a task it owns.
- Done-callbacks auto-clean both layers when a task finishes or is cancelled.

Every public function takes `redis` as its first argument and **degrades to local-only**
behavior when it is falsy.

## 2. Imports & Logging

Actual imports: `asyncio`, `json`, `logging`, `typing.{Dict, List, Optional}`,
`uuid.uuid4`, `fastapi.Request`, `redis.asyncio.Redis`, and **`REDIS_KEY_PREFIX`** from
`open_webui.env`. Logging is just `log = logging.getLogger(__name__)`.

> Corrected: the original claimed `from open_webui.env import SRC_LOG_LEVELS` plus
> `log.setLevel(SRC_LOG_LEVELS["MAIN"])`. Neither exists here — the module imports
> `REDIS_KEY_PREFIX`, not `SRC_LOG_LEVELS`, and never calls `setLevel`.

## 3. Distributed Coordination Architecture

**Local registries** (module globals):

```python
tasks: Dict[str, asyncio.Task] = {}
item_tasks = {}   # item_id -> [task_id]
```

**Redis keys** are namespaced with the configurable `REDIS_KEY_PREFIX` (default
`open-webui`), so they are **not** hard-coded literals:

- `REDIS_TASKS_KEY = f"{REDIS_KEY_PREFIX}:tasks"` — hash `task_id → item_id`
- `REDIS_ITEM_TASKS_KEY = f"{REDIS_KEY_PREFIX}:tasks:item"` — base for per-item sets
  (`{base}:{item_id}` → set of `task_id`)
- `REDIS_PUBSUB_CHANNEL = f"{REDIS_KEY_PREFIX}:tasks:commands"` — control channel

(See [redis.md](./redis.md) for the full key-pattern table.)

## 4. Redis Persistence Layer

- **`redis_save_task(redis, task_id, item_id)`** — a pipeline `HSET`s `task_id → item_id`
  and, when `item_id` is set, `SADD`s the task into the item's set; one `execute()`.
- **`redis_cleanup_task(redis, task_id, item_id)`** — pipeline `HDEL`s the task (and `SREM`s
  it from the item set), `execute()`s, **then** issues a separate `SCARD` and, if the set is
  now empty, `DELETE`s the set key.
  > Corrected: the original showed a single fused
  > `(await pipe.scard(...).execute())[-1]` expression. The real code executes the pipeline
  > first, then runs `await redis.scard(...)` / `await redis.delete(...)` as **separate
  > awaits** outside the pipeline.
- **`redis_list_tasks(redis)`** → `HKEYS`; **`redis_list_item_tasks(redis, item_id)`** →
  `SMEMBERS` of the item set.

## 5. Task Lifecycle

- **`create_task(redis, coroutine, id=None)`** → `(task_id, task)`. Generates a `uuid4`
  id, `asyncio.create_task(coroutine)`, registers a **done-callback** that schedules
  `cleanup_task`, records the task in `tasks` and `item_tasks[id]`, and (if `redis`) mirrors
  it via `redis_save_task`.
- **`cleanup_task(redis, task_id, id=None)`** — runs `redis_cleanup_task` first (when
  `redis`), then `tasks.pop(task_id, None)` and prunes `item_tasks[id]`, removing the entry
  when its list empties. `pop(..., None)` keeps it idempotent (no `KeyError`).

> `uuid4` gives a random, practically-unique id — not a cryptographic-security guarantee
> (the original called it "cryptographically secure"; it's `random`-based UUID v4).

## 6. Pub/Sub Command Distribution

- **`redis_task_command_listener(app)`** — subscribes to `REDIS_PUBSUB_CHANNEL` and loops
  over `pubsub.listen()`. It skips non-`message` frames, parses JSON, and for
  `{"action": "stop", "task_id": …}` cancels the task **only if it is local** (`tasks.get`).
  Exceptions are logged and swallowed so the loop never dies. (Started as a background task
  in the app lifespan — see [redis.md](./redis.md).)
- **`redis_send_command(redis, command)`** — JSON-encodes and publishes to the channel.
  > Corrected: it is **cluster-aware**. If the client looks like a cluster
  > (`hasattr(redis, "nodes_manager")`) it uses `execute_command("PUBLISH", …)` because
  > `RedisCluster` doesn't expose `publish()`; otherwise it calls `redis.publish(…)`. The
  > original showed only the plain `publish` path.

## 7. Data Structures & State

| Structure | Shape | Role |
|---|---|---|
| `tasks` | `dict[task_id, asyncio.Task]` | Direct cancel/await of the local task object |
| `item_tasks` | `dict[item_id, list[task_id]]` | Group tasks by entity (e.g. a chat) for bulk stop |
| `{prefix}:tasks` | Redis hash | Cross-instance `task_id → item_id` |
| `{prefix}:tasks:item:{item_id}` | Redis set | Cross-instance task ids for an item |

Both directions are queryable: task→item (hash) and item→tasks (set).

## 8. API Surface

| Function | Behavior |
|---|---|
| `create_task(redis, coroutine, id=None)` | Start + register a task → `(task_id, task)` |
| `stop_task(redis, task_id)` | Cancel a task → status dict |
| `stop_item_tasks(redis, item_id)` | Stop every task for an item; returns first failure or success |
| `list_tasks(redis)` | All active task ids (`redis_list_tasks` or local `tasks.keys()`) |
| `list_task_ids_by_item_id(redis, id)` | Task ids for an item |
| `has_active_tasks(redis, chat_id)` | `bool` — any tasks for a chat *(not in the original doc)* |
| `get_active_chat_ids(redis, chat_ids)` | Filter chat ids to those with active tasks *(not in the original doc)* |

**`stop_task` contract (corrected):**
- *Redis path*: `HGET`s the item_id, broadcasts a `stop` command via `redis_send_command`
  (so the owning instance cancels the live task), then directly `redis_cleanup_task`s
  (idempotent — safe even if the owner's done-callback also cleans up). Returns
  `{"status": True, "message": "Task {id} stopped."}`.
- *Local path*: pops + `cancel()`s the task, awaits it, and returns a `{"status": …}` dict.
  An unknown id returns `{"status": False, "message": "Task with ID {id} not found."}`.

> Corrected: `stop_task` **never raises `ValueError`** for an unknown id (the original's
> "Invalid task IDs raise ValueError" is wrong); it returns a `status: False` dict. No
> function in this module raises `ValueError`.

**Graceful degradation** — when `redis` is falsy, `list_tasks` → `tasks.keys()`,
`list_task_ids_by_item_id` → `item_tasks.get(id, [])`, and `stop_task` uses the local path,
so single-instance deployments work with no Redis.

---

## Verification Recipe

Run from the repo root. Symbol resolution for manual `git log -L` uses the overrides in
`docs/DOCUMENTATION_STANDARD.md`.

```bash
# Imports/logging: REDIS_KEY_PREFIX, NOT SRC_LOG_LEVELS / setLevel
grep -rn "from open_webui.env import REDIS_KEY_PREFIX\|log = logging.getLogger" backend/open_webui/tasks.py
grep -rn "SRC_LOG_LEVELS\|setLevel\|raise ValueError" backend/open_webui/tasks.py || echo "none (expected)"

# Keys are prefix-namespaced
grep -rn "REDIS_TASKS_KEY = f'{REDIS_KEY_PREFIX}\|REDIS_PUBSUB_CHANNEL = f'{REDIS_KEY_PREFIX}" backend/open_webui/tasks.py

# redis_cleanup_task: execute pipe, THEN separate scard/delete
grep -rn "await pipe.execute()\|await redis.scard\|await redis.delete" backend/open_webui/tasks.py

# redis_send_command is cluster-aware
grep -rn "def redis_send_command\|nodes_manager\|execute_command('PUBLISH'" backend/open_webui/tasks.py

# Lifecycle + listener
grep -rn "def create_task\|add_done_callback\|def cleanup_task\|def redis_task_command_listener" backend/open_webui/tasks.py

# stop_task returns status dicts (no exceptions); new query helpers exist
grep -rn "def stop_task\|status.: False, .message.: f'Task with ID\|def has_active_tasks\|def get_active_chat_ids" backend/open_webui/tasks.py
```
