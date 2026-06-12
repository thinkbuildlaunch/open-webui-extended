---
# Machine-readable anchor block — see I.8 / Part II.
covers_files:
  - backend/open_webui/env.py
  - backend/open_webui/config.py
  - backend/open_webui/internal/config.py
covers_symbols:
  - { symbol: DEVICE_TYPE, file: backend/open_webui/env.py }
  - { symbol: JSONFormatter, file: backend/open_webui/env.py }
  - { symbol: GLOBAL_LOG_LEVEL, file: backend/open_webui/env.py }
  - { symbol: SRC_LOG_LEVELS, file: backend/open_webui/env.py }
  - { symbol: DATA_DIR, file: backend/open_webui/env.py }
  - { symbol: DATABASE_URL, file: backend/open_webui/env.py }
  - { symbol: REDIS_URL, file: backend/open_webui/env.py }
  - { symbol: WEBUI_SECRET_KEY, file: backend/open_webui/env.py }
  - { symbol: WEBUI_AUTH, file: backend/open_webui/env.py }
  - { symbol: parse_section, file: backend/open_webui/env.py }
verified_against_commit: e127a76e4cdd9a7c9ed0b9f527cf6fc05620b751
---

# Environment Configuration (`env.py`)

`backend/open_webui/env.py` parses the **startup / infrastructure** environment: directory
layout, Docker/device detection, logging, the database/Redis/WebSocket wiring, secrets and
auth posture, audit logging, and OpenTelemetry. These values are read **once at import** and
are not user-editable at runtime.

> **Scope — `env.py` vs `config.py` (read this first).** `env.py` holds plain,
> read-at-import settings. The much larger catalog of **user-facing** settings (AI providers,
> RAG, OAuth, web search, audio/image, most feature flags) lives in `config.py` as
> **`ConfigVar`s** — persisted in the DB and editable from the Admin UI via `AppConfig`
> (`internal/config.py`); see [redis.md](./redis.md) and the official
> [Environment Variable reference](https://docs.openwebui.com/reference/env-configuration/).
> Don't expect `THREAD_POOL_SIZE`, `JWT_EXPIRES_IN`, `CORS_ALLOW_ORIGIN`, or the RAG/OAuth
> variables in `env.py` — they are `config.py` ConfigVars.

> **What changed since the original guide.** Its biggest error: the "hierarchical
> per-component logging" section. `SRC_LOG_LEVELS` is now an **empty, legacy dict** (`{} # do
> not remove`); there is no `log_sources` loop and no `log.setLevel(SRC_LOG_LEVELS["CONFIG"])`.
> Real logging is `GLOBAL_LOG_LEVEL` plus a new `LOG_FORMAT=json` mode backed by `JSONFormatter`.

---

## 1. Overview

Top-of-module code resolves paths, detects the device, configures logging, loads `.env`
(via `python-dotenv`), then defines the infra config. Most settings are simple
`NAME = os.getenv(...)` with light coercion; failures fall back to safe defaults.

## 2. Paths & Docker Detection

- `ENV_FILE_PATH = Path(__file__).resolve()`, then `OPEN_WEBUI_DIR` (open_webui/),
  `BACKEND_DIR` (backend/), `BASE_DIR` (repo root).
- `DOCKER = os.getenv("DOCKER", "False") == "true"`; `FROM_INIT_PY` distinguishes a
  pip-installed package; `VERSION` comes from `importlib.metadata` (package) or `package.json`.
- `DATA_DIR`, `FRONTEND_BUILD_DIR`, `STATIC_DIR`, `FONTS_DIR` are resolved here.
- **Data migration (still present):** under `FROM_INIT_PY`, an existing `DATA_DIR` is copied
  into a new location (`shutil.copytree` / `copy2`), archived (`shutil.make_archive(... "zip")`),
  and removed; a legacy `data/ollama.db` is renamed to `webui.db`.
- Also: `ENV` (dev/test/prod), `DEPLOYMENT_ID`, `INSTANCE_ID` (uuid4 default),
  `ENABLE_DB_MIGRATIONS`.

## 3. Device / ML Acceleration

`USE_CUDA = os.getenv("USE_CUDA_DOCKER", "false")`; `DEVICE_TYPE` starts `"cpu"`. If CUDA is
requested but `torch.cuda.is_available()` is false, the error is captured in a module-level
`_cuda_error`, `USE_CUDA_DOCKER` is reset to `false`, and it logs once logging is up. **MPS is
only probed on macOS when still on CPU** (`sys.platform == "darwin" and DEVICE_TYPE == "cpu"`).
(The original implied MPS is always probed and used a `cuda_error` local — both inaccurate.)

## 4. Logging (corrected)

- `GLOBAL_LOG_LEVEL` (default `INFO`) configures the root logger via `logging.basicConfig`.
- `LOG_FORMAT` — set to `json` to emit single-line JSON via the **`JSONFormatter`** class
  (fields `ts`/`level`/`msg`/`caller`, plus `error`/`stacktrace`); otherwise plain text to
  stdout.
- **`SRC_LOG_LEVELS = {}`** is a retained-but-empty legacy variable (`# do not remove`). The
  original doc's per-component `log_sources` table and `setLevel` call no longer exist. (Note:
  some modules still `import SRC_LOG_LEVELS`; it just resolves to `{}`.)

## 5. Database (`DATABASE_URL` + pool + SQLite PRAGMAs)

`env.py` builds the SQLAlchemy URL and pool knobs consumed by `internal/db.py`
(see [sqlalchemy.md](./sqlalchemy.md)):

- `DATABASE_URL` (default `sqlite:///{DATA_DIR}/webui.db`); built from `DATABASE_TYPE`/`USER`/
  `PASSWORD`/`HOST`/`PORT`/`NAME` when all are set; `postgres://`→`postgresql://`.
- Pool: `DATABASE_POOL_SIZE` (None), `DATABASE_POOL_MAX_OVERFLOW` (0), `DATABASE_POOL_TIMEOUT`
  (30), `DATABASE_POOL_RECYCLE` (3600); `DATABASE_SCHEMA`.
- SQLite tuning: `DATABASE_ENABLE_SQLITE_WAL` (default **True**) and the
  `DATABASE_SQLITE_PRAGMA_*` set (synchronous/busy_timeout/cache_size/temp_store/mmap_size/
  journal_size_limit); `DATABASE_ENABLE_SESSION_SHARING`,
  `DATABASE_USER_ACTIVE_STATUS_UPDATE_INTERVAL`.

## 6. Redis & Distributed State

- `REDIS_URL`, `REDIS_KEY_PREFIX` (`open-webui`), `REDIS_CLUSTER`.
- Sentinel: `REDIS_SENTINEL_HOSTS`/`PORT`, `REDIS_SENTINEL_MAX_RETRY_COUNT` (values `<1` reset
  to 2), `REDIS_RECONNECT_DELAY`.
- Connection hygiene: `REDIS_SOCKET_CONNECT_TIMEOUT`, `REDIS_SOCKET_KEEPALIVE`,
  `REDIS_HEALTH_CHECK_INTERVAL`. See [redis.md](./redis.md) / [redis-sentinels.md](./redis-sentinels.md).

## 7. WebSocket / Scaling

`ENABLE_WEBSOCKET_SUPPORT`, `WEBSOCKET_MANAGER` (`redis` for multi-instance),
`WEBSOCKET_REDIS_URL`/`WEBSOCKET_REDIS_CLUSTER`/`WEBSOCKET_REDIS_OPTIONS`,
`WEBSOCKET_SENTINEL_HOSTS`/`PORT`, `WEBSOCKET_REDIS_LOCK_TIMEOUT` (60),
`WEBSOCKET_SERVER_PING_INTERVAL` (25) / `_PING_TIMEOUT` (20), `WEBSOCKET_EVENT_CALLER_TIMEOUT`
(None; `300` only as the bad-value fallback). See [websockets.md](./websockets.md) /
[heartbeats.md](./heartbeats.md). `UVICORN_WORKERS` (≥1) is also parsed here.

## 8. Auth & Security

- `WEBUI_SECRET_KEY` (legacy fallback `WEBUI_JWT_SECRET_KEY`; dev fallback `t0p-s3cr3t`) — signs
  JWTs and encrypts secrets at rest. `WEBUI_AUTH` (default True) gates authentication.
- Trusted-header SSO: `WEBUI_AUTH_TRUSTED_EMAIL_HEADER` / `_NAME_HEADER` / `_GROUPS_HEADER` /
  `_ROLE_HEADER`.
- Cookies: `WEBUI_SESSION_COOKIE_SAME_SITE`/`_SECURE` and `WEBUI_AUTH_COOKIE_SAME_SITE`/`_SECURE`
  (the auth-cookie pair falls back to the session-cookie values).
- License: `LICENSE_KEY`, `LICENSE_BLOB`(_PATH), `LICENSE_PUBLIC_KEY` (loaded via
  `cryptography` `serialization.load_pem_public_key`).
- Misc posture: `OFFLINE_MODE` (also sets `HF_HUB_OFFLINE=1` and disables version checks),
  `SAFE_MODE`, `RESET_CONFIG_ON_START`, `WEBUI_NAME`, `ENABLE_COMPRESSION_MIDDLEWARE`.

## 9. Audit & OpenTelemetry

- Audit: `AUDIT_LOG_LEVEL` (`NONE`/`METADATA`/`REQUEST`/`REQUEST_RESPONSE`),
  `AUDIT_LOGS_FILE_PATH`, `AUDIT_LOG_FILE_ROTATION_SIZE`, `AUDIT_UVICORN_LOGGER_NAMES`,
  `MAX_BODY_LOG_SIZE`, `AUDIT_EXCLUDED_PATHS` / `AUDIT_INCLUDED_PATHS`.
- OTEL: `ENABLE_OTEL` (+ `_TRACES`/`_METRICS`/`_LOGS`), `OTEL_EXPORTER_OTLP_ENDPOINT`,
  `OTEL_SERVICE_NAME`, samplers, basic-auth, and grpc/http exporter selection.

## 10. Banner Parsing & ConfigVar Boundary

`env.py` also defines helpers like **`parse_section`** (HTML→structured via `markdown` +
`BeautifulSoup`) used to seed default banners. Beyond that, the boundary holds: anything
admin-editable/persisted is a `config.py` `ConfigVar` (managed by `AppConfig`), not an
`env.py` value. For the exhaustive per-variable catalog (types, defaults, ConfigVar status),
use the official reference linked at the top.

---

## Verification Recipe

Run from the repo root. Symbol resolution for manual `git log -L` uses the overrides in
`docs/DOCUMENTATION_STANDARD.md`.

```bash
# Logging: GLOBAL_LOG_LEVEL + JSONFormatter; SRC_LOG_LEVELS is empty legacy
grep -rn "class JSONFormatter\|LOG_FORMAT = \|SRC_LOG_LEVELS = {}" backend/open_webui/env.py
grep -rn "log_sources\|setLevel(SRC_LOG_LEVELS" backend/open_webui/env.py || echo "no per-component log loop (expected)"

# Device detection: MPS only on darwin+cpu; _cuda_error module var
grep -rn "DEVICE_TYPE = 'cpu'\|sys.platform == 'darwin' and DEVICE_TYPE == 'cpu'\|_cuda_error" backend/open_webui/env.py

# Paths + data migration still present
grep -rn "OPEN_WEBUI_DIR = \|DATA_DIR = \|shutil.make_archive\|data}/ollama.db\|def parse_section" backend/open_webui/env.py

# Infra config lives in env.py; ConfigVars live in config.py
grep -rn "^DATABASE_URL = \|^REDIS_URL = \|^WEBUI_SECRET_KEY = \|^WEBUI_AUTH = \|^ENABLE_OTEL = " backend/open_webui/env.py
grep -rn "^THREAD_POOL_SIZE = \|^JWT_EXPIRES_IN = \|^CORS_ALLOW_ORIGIN = " backend/open_webui/config.py
test "$(grep -c '^THREAD_POOL_SIZE = ' backend/open_webui/env.py)" = 0 && echo "THREAD_POOL_SIZE not in env.py (expected)"
```
