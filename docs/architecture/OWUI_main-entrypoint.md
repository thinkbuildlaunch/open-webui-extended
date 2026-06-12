---
# Machine-readable anchor block — see I.8 / Part II.
covers_files:
  - backend/open_webui/main.py
  - backend/open_webui/utils/asgi_middleware.py
  - backend/open_webui/internal/config.py
  - backend/open_webui/env.py
covers_symbols:
  - { symbol: lifespan, file: backend/open_webui/main.py }
  - { symbol: get_models, file: backend/open_webui/main.py }
  - { symbol: get_base_models, file: backend/open_webui/main.py }
  - { symbol: chat_completion, file: backend/open_webui/main.py }
  - { symbol: get_app_config, file: backend/open_webui/main.py }
  - { symbol: get_app_version, file: backend/open_webui/main.py }
  - { symbol: healthcheck, file: backend/open_webui/main.py }
  - { symbol: AuthTokenMiddleware, file: backend/open_webui/utils/asgi_middleware.py }
  - { symbol: CommitSessionMiddleware, file: backend/open_webui/utils/asgi_middleware.py }
  - { symbol: RedirectMiddleware, file: backend/open_webui/utils/asgi_middleware.py }
verified_against_commit: fedd834934fa36c7df9fb0aa514cc3c654cc22ab
---

# Application Entrypoint (`main.py`)

`backend/open_webui/main.py` assembles the FastAPI app: it binds configuration to
`app.state`, registers the middleware stack and ~30 feature routers, mounts the Socket.IO
app, defines the model/chat/config/health endpoints, and runs the async `lifespan`.

> **What changed since the original guide (it was stale).**
> - **Middleware is pure-ASGI classes via `app.add_middleware(...)`**, not
>   `@app.middleware("http")` decorators. The doc's `check_url` and
>   `commit_session_after_request` functions are gone — replaced by
>   **`AuthTokenMiddleware`** and **`CommitSessionMiddleware`** (in
>   `utils/asgi_middleware.py`). A code comment there records that the old
>   `BaseHTTPMiddleware` versions were rewritten as ASGI middleware.
> - **`lifespan` is async** and does much more than the sketch: `await async_reset_config()`
>   (not sync `reset_config`), `await install_tool_and_function_dependencies()`, admin
>   bootstrap, a scheduler loop, **both** cleanup tasks, and tool/terminal-server init.
> - Redis is `get_redis_client(async_mode=True)` (not the verbose `get_redis_connection(...)`).

---

## 1. Structure Overview

Module-level code builds the app (`app = FastAPI(lifespan=lifespan, ...)`), assigns
`app.state.*`, mounts middleware/routers/`/ws`, and declares the handful of endpoints that
live in `main.py` itself. Per-feature behavior lives in the included routers (see
[routers.md](./routers.md)).

## 2. Imports & Dependencies

FastAPI/Starlette, `asyncio`/`aiohttp`/`anyio.to_thread`, the sync `redis.Redis` +
`starsessions` Redis store, and a large fan-in of `open_webui.config`, `open_webui.env`,
routers, models, and utils. Routers are grouped by domain (ollama, openai, retrieval,
images, audio, chats, …); `AppConfig` comes from `internal/config.py`.

## 3. Configuration → `app.state`

`app.state.config = AppConfig(redis_url=…, redis_cluster=…, redis_key_prefix=…)`
(`internal/config.py`; bridges live values to Redis — see [redis.md](./redis.md)). Hundreds
of env-derived values are then bound, e.g. `app.state.config.ENABLE_OLLAMA_API = ENABLE_OLLAMA_API`,
`...OLLAMA_BASE_URLS`, OpenAI/RAG/auth/feature/security settings. This makes config both
runtime-mutable (via the configs router) and centrally discoverable.

## 4. Runtime State

Non-config runtime objects also hang off `app.state`, including:

- `instance_id`, `main_loop`, `redis`, `startup_complete`, `LICENSE_METADATA`.
- Provider/model registries: `MODELS`, `OLLAMA_MODELS`, `OPENAI_MODELS`, `BASE_MODELS`,
  `TOOL_SERVERS`, `TERMINAL_SERVERS`.
- Tool/function + RAG runtime: `TOOLS`, `FUNCTIONS`, `EMBEDDING_FUNCTION`,
  `RERANKING_FUNCTION`, `ef`, `rf` (the embedding/reranking models, built via `get_ef`/`get_rf`).
- Auth: `oauth_manager`, `oauth_client_manager`, `ENABLE_SCIM`, `SCIM_TOKEN`.

> Corrected: `app.state.MODELS` exists (assigned from the imported `MODELS`) and is read in
> `chat_completion`; the original's `app.state.MODELS = {}` undersold it.

## 5. Middleware Stack (`utils/asgi_middleware.py` + others)

Registered with `app.add_middleware(...)` (Starlette applies the **last-added outermost**).
Roughly, inner→outer:

- `CompressMiddleware` (conditional on the compression setting)
- `RedirectMiddleware` — legacy entry-point rewrites (e.g. `/watch?v=` → SPA route)
- `SecurityHeadersMiddleware`
- **`CommitSessionMiddleware`** — commits the request's DB session after the response
  (replaces the old `commit_session_after_request` that called `Session.commit()`).
- **`AuthTokenMiddleware(fastapi_app=app)`** — extracts the auth credential onto request
  state (replaces the old `check_url`).
- `WebsocketUpgradeGuardMiddleware` — rejects malformed `/ws/socket.io` upgrade requests
  (see [websockets.md](./websockets.md)).
- `CORSMiddleware`.
- Session middleware (`SessionAutoloadMiddleware` + a `starsessions` session middleware),
  added separately later.

## 6. Routing & Endpoints

~30 `app.include_router(...)` calls mount the feature routers with stable prefixes — e.g.
`ollama.router` at `/ollama`, `openai.router` at `/openai`, and the `/api/v1/*` group
(`tasks`, `images`, `audio`, `retrieval`, `configs`, `chats`, `files`, …). The Socket.IO app
is mounted at `/ws`.

Endpoints defined **in `main.py`**:

- **Models**: `GET /api/models` (`get_models`, access-filtered), `GET /api/models/base`
  (`get_base_models`, admin), `POST /api/models/unload`.
- **Chat pipeline**: `POST /api/chat/completions` (`chat_completion`), `POST /api/chat/completed`,
  `POST /api/chat/actions/{action_id}`.
- **Tasks**: `POST /api/tasks/stop/{task_id}`, `GET /api/tasks`,
  `GET|POST /api/tasks/chat/{chat_id}` (see [task-management.md](./task-management.md)).
- **System**: `GET /api/config` (`get_app_config`), `GET /api/version` (`get_app_version`),
  `GET /api/version/updates`, `GET /health` (`healthcheck`), `GET /health/db` (pings the DB,
  and Redis when configured).

## 7. Lifecycle (`lifespan`)

`async def lifespan(app)` — startup, in order:

1. `app.state.main_loop = asyncio.get_running_loop()`; `instance_id`; `start_logger()`.
2. `if RESET_CONFIG_ON_START: await async_reset_config()`.
3. `if LICENSE_KEY: get_license_data(app, LICENSE_KEY)`; admin bootstrap
   (`create_admin_user(...)`); on license issues, `await Functions.deactivate_all_functions()`.
4. `await install_tool_and_function_dependencies()`.
5. `app.state.redis = get_redis_client(async_mode=True)`; if present, start
   `redis_task_command_listener` as a background task.
6. **Thread limiter**: if `THREAD_POOL_SIZE > 0`, set
   `anyio.to_thread.current_default_thread_limiter().total_tokens = THREAD_POOL_SIZE`
   (see [threadpooling.md](./threadpooling.md)).
7. Background loops: `periodic_usage_pool_cleanup`, `periodic_session_pool_cleanup`,
   `scheduler_worker_loop(app)`.
8. Warm-up: `get_all_models(...)` (when base-model caching is enabled), `set_tool_servers`,
   `set_terminal_servers`; then `app.state.startup_complete = True`.

Shutdown (after `yield`): `await close_session()` and cancel the
`redis_task_command_listener` task.

## 8. Integration Points

- **AI providers**: Ollama (`/ollama`) and OpenAI-compatible (`/openai`) backends, plus
  pipelines and tool/terminal servers; the unified `chat_completion` pipeline resolves a
  model from `app.state.MODELS`.
- **Retrieval / search / docs**: the retrieval router + web-search providers (see
  [retrieval-utils.md](./retrieval-utils.md)).
- **Auth**: OAuth (`oauth_manager`), SCIM, LDAP, JWT (via `AuthTokenMiddleware`).
- **Storage/state**: Redis (cache, sessions, tasks — [redis.md](./redis.md)), SQLAlchemy
  ([sqlalchemy.md](./sqlalchemy.md)), and the Socket.IO real-time layer
  ([websockets.md](./websockets.md)).
- **Extensibility**: `app.state.TOOLS` / `app.state.FUNCTIONS` registries feed the chat
  pipeline.

---

## Verification Recipe

Run from the repo root. Symbol resolution for manual `git log -L` uses the overrides in
`docs/DOCUMENTATION_STANDARD.md`.

```bash
# Middleware is ASGI classes via add_middleware (not @app.middleware http decorators)
grep -rn "app.add_middleware(AuthTokenMiddleware\|app.add_middleware(CommitSessionMiddleware\|app.add_middleware(RedirectMiddleware\|app.add_middleware(WebsocketUpgradeGuardMiddleware" backend/open_webui/main.py
grep -rn "class AuthTokenMiddleware\|class CommitSessionMiddleware\|class RedirectMiddleware" backend/open_webui/utils/asgi_middleware.py
grep -rn "async def check_url\|async def commit_session_after_request" backend/open_webui/main.py || echo "old decorators absent (expected)"

# Lifespan content
grep -rn "async def lifespan\|await async_reset_config()\|await install_tool_and_function_dependencies()\|get_redis_client(async_mode=True)\|periodic_session_pool_cleanup\|scheduler_worker_loop\|app.state.startup_complete = True" backend/open_webui/main.py

# State + AppConfig
grep -rn "app.state.config = AppConfig\|app.state.MODELS = \|app.state.EMBEDDING_FUNCTION\|app.state.ef = \|app.state.TOOL_SERVERS" backend/open_webui/main.py | head

# Endpoints defined in main.py
grep -rn "@app.get('/api/models')\|@app.get('/api/models/base')\|@app.post('/api/chat/completions')\|@app.post('/api/chat/actions/{action_id}')\|@app.get('/api/config')\|@app.get('/health')" backend/open_webui/main.py

# Routers + /ws mount
grep -rcn "app.include_router(" backend/open_webui/main.py
grep -rn "app.mount('/ws'" backend/open_webui/main.py
```
