---
# Machine-readable anchor block — see Directive 8 / Directive 11.
covers_files:
  - backend/open_webui/internal/db.py
  - backend/open_webui/config.py
  - backend/open_webui/env.py
covers_symbols:
  - { symbol: JSONField, file: backend/open_webui/internal/db.py }
  - { symbol: _make_async_url, file: backend/open_webui/internal/db.py }
  - { symbol: extract_ssl_params_from_url, file: backend/open_webui/internal/db.py }
  - { symbol: get_session, file: backend/open_webui/internal/db.py }
  - { symbol: get_async_db, file: backend/open_webui/internal/db.py }
  - { symbol: get_async_db_context, file: backend/open_webui/internal/db.py }
  - { symbol: SessionLocal, file: backend/open_webui/internal/db.py }
  - { symbol: AsyncSessionLocal, file: backend/open_webui/internal/db.py }
  - { symbol: ScopedSession, file: backend/open_webui/internal/db.py }
verified_against_commit: 81d4466e495cfbb69b8c03e7370513106aec3d6c
---

# Database Infrastructure (`internal/db.py`)

`internal/db.py` builds Open WebUI's SQLAlchemy layer: the declarative `Base`, the
`JSONField` type, and **two engines** — a sync `engine` for import-time/startup work and an
async `async_engine` for all runtime queries — with SQLite, SQLCipher, and Postgres support.

> **Strong merge candidate.** This file is also the subject of
> [sqlalchemy.md](./sqlalchemy.md), which covers the same engines, pooling, sessions,
> migrations, models, and vector engines in more depth. Treat the two as a consolidation pair;
> this doc keeps the original "database infrastructure" framing.

> **What changed since the original guide (it was very stale).**
> - **Peewee is entirely removed.** There is no `handle_peewee_migration`, no
>   `peewee_migrate.Router`, no `register_connection`, no `internal/wrappers.py`, and no
>   `internal/migrations/` directory (confirm with the recipe; per Directive 3 the absence is
>   proven from the repo root). Migrations are pure **Alembic**, run from `config.py`'s
>   `run_migrations()` (gated by `ENABLE_DB_MIGRATIONS`).
> - **Dual sync/async engine.** The original described only the sync engine; runtime now uses
>   the **async** engine + `AsyncSession`.
> - **`JSONField.impl = types.UnicodeText`** (not `types.Text`), and it has **no** Peewee-style
>   `db_value`/`python_value` methods.
> - The shared sync session is **`ScopedSession`** (the original's `Session = scoped_session(...)`);
>   there is **no sync `get_db_context`** — only the async `get_async_db_context`.

---

## 1. Overview

The module constructs the engines at import time, exposes `Base`/`JSONField` for the model
layer, and provides session factories/generators. There is **no migration code here** anymore
— Alembic runs from `config.py`.

## 2. Imports & Integrations

`json`, `os`, `sys`, `contextlib.{contextmanager, asynccontextmanager}`, URL parsing; from
SQLAlchemy: `create_engine`, `create_async_engine`/`async_sessionmaker`/`AsyncSession`,
`declarative_base`, `sessionmaker`/`scoped_session`, `NullPool`/`QueuePool`, `MetaData`,
`types`, `event`. From `env`: `DATABASE_URL`, `DATABASE_SCHEMA`, the `DATABASE_POOL_*` knobs,
the `DATABASE_SQLITE_PRAGMA_*` set, `DATABASE_ENABLE_SQLITE_WAL`,
`DATABASE_ENABLE_SESSION_SHARING`, `OPEN_WEBUI_DIR`. (No `peewee_migrate`, no
`internal.wrappers`, no `SRC_LOG_LEVELS`.)

## 3. `JSONField`

A `TypeDecorator` storing arbitrary Python objects as JSON text, portable across SQLite and
Postgres:

- `impl = types.UnicodeText`; `cache_ok = True`.
- `process_bind_param`: `json.dumps(value)` on write, `None` → `None`.
- `process_result_value`: `json.loads(value)` on read, `None` stays `None`.
- `copy()` clones the type during DDL. (The original's `db_value`/`python_value` Peewee methods
  no longer exist.)

## 4. Migrations (Alembic only — no Peewee)

The Peewee→SQLAlchemy transition is finished and the legacy machinery is gone. Schema
migrations are Alembic, invoked by `run_migrations()` in `config.py`
(`command.upgrade(cfg, "head")`, gated by `ENABLE_DB_MIGRATIONS`); `db.py` itself contains no
migration logic. See [sqlalchemy.md](./sqlalchemy.md) for the Alembic env/util details.

## 5. Engines, Pooling & URL Handling

- **URL prep.** `extract_ssl_params_from_url` / `reattach_ssl_params_to_url` normalize SSL query
  params into canonical libpq form for the **sync** (psycopg2) engine; `_make_async_url` maps
  the URL to the async driver: `sqlite://`→`sqlite+aiosqlite://`, `postgresql(+psycopg2)://`/
  `postgres://`→`postgresql+psycopg://` (psycopg v3), and **raises `ValueError`** for
  `sqlite+sqlcipher://` (unsupported on the async engine).
- **Sync engine** branches: SQLCipher (dummy `sqlite://` + `create_sqlcipher_connection`,
  `NullPool` by default — a deliberate guard against `SingletonThreadPool` segfaults),
  SQLite (`check_same_thread=False` + a `connect` listener applying the WAL/PRAGMA settings),
  else server DB (`QueuePool` when `DATABASE_POOL_SIZE > 0`, `NullPool` when `== 0`, library
  default when unset). `pool_pre_ping=True` throughout.
- **Async engine** mirrors that logic, with a SQLite-specific twist: when no positive
  `DATABASE_POOL_SIZE` is set it uses a generous **512** pool size (async coroutines without
  session sharing create high connection demand). On Windows + Postgres it switches to
  `WindowsSelectorEventLoopPolicy` at import.

## 6. Sessions

- **Sync:** `SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine, expire_on_commit=False)`;
  `ScopedSession = scoped_session(SessionLocal)`; `get_session()` generator (+ `get_db =
  contextmanager(get_session)`) — reserved for startup/config work, **not** request handling.
- **Async (the runtime path):** `AsyncSessionLocal = async_sessionmaker(bind=async_engine, class_=AsyncSession, ...)`;
  `get_async_session()` (FastAPI `Depends`), `get_async_db()` (`@asynccontextmanager`), and
  `get_async_db_context(db=None)` which reuses a passed `AsyncSession` only when
  `DATABASE_ENABLE_SESSION_SHARING` is true. There is no sync `get_db_context`.

## 7. Schema / Metadata

`metadata_obj = MetaData(schema=DATABASE_SCHEMA)` and `Base = declarative_base(metadata=metadata_obj)` —
`DATABASE_SCHEMA` (default `None`) namespaces all model tables for schema-scoped Postgres
deployments.

## 8. Engine Selection Summary

Selection is by URL scheme (SQLCipher / SQLite / server DB) and whether `DATABASE_POOL_SIZE` is
an explicit int (`>0` → QueuePool, `0` → NullPool, unset → library default / 512 for async
SQLite). `pool_pre_ping` is always on. See [sqlalchemy.md](./sqlalchemy.md) for the full env-var
table and [env-configuration.md](./env-configuration.md) for where these are parsed.

---

## Verification Recipe

Run from the repo root. Symbol resolution for manual `git log -L` uses the overrides in
`docs/DOCUMENTATION_STANDARD.md`.

```bash
# Peewee is gone (prove absence — Directive 3)
grep -rn "peewee_migrate\|register_connection\|handle_peewee_migration" backend/open_webui/internal/db.py || echo "no peewee (expected)"
ls backend/open_webui/internal/wrappers.py 2>/dev/null || echo "wrappers.py absent (expected)"
ls -d backend/open_webui/internal/migrations 2>/dev/null || echo "internal/migrations absent (expected)"

# Dual engine + async sessions; sync session is ScopedSession
grep -rn "create_async_engine\|AsyncSessionLocal\|ScopedSession = scoped_session\|def get_async_db_context" backend/open_webui/internal/db.py
grep -rn "def get_db_context" backend/open_webui/internal/db.py || echo "no sync get_db_context (expected)"

# JSONField is UnicodeText-backed, no Peewee db_value/python_value
grep -rn "class JSONField\|impl = types.UnicodeText" backend/open_webui/internal/db.py
grep -rn "def db_value\|def python_value" backend/open_webui/internal/db.py || echo "no peewee methods (expected)"

# URL handling: SSL normalization + async driver mapping (incl. sqlcipher ValueError)
grep -rn "def extract_ssl_params_from_url\|def _make_async_url\|sqlite+aiosqlite\|postgresql+psycopg\|SQLCipher" backend/open_webui/internal/db.py

# Migrations live in config.py now
grep -rn "def run_migrations\|command.upgrade" backend/open_webui/config.py
```
