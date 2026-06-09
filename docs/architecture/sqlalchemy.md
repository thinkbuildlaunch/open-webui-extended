---
# Machine-readable anchor block — see Directive 8.
covers_files:
  - backend/open_webui/internal/db.py
  - backend/open_webui/env.py
  - backend/open_webui/config.py
  - backend/open_webui/main.py
  - backend/open_webui/migrations/env.py
  - backend/open_webui/migrations/util.py
  - backend/open_webui/models/users.py
  - backend/open_webui/retrieval/vector/dbs/pgvector.py
  - backend/open_webui/retrieval/vector/dbs/mariadb_vector.py
  - backend/open_webui/retrieval/vector/dbs/opengauss.py
covers_symbols:
  - { symbol: JSONField, file: backend/open_webui/internal/db.py }
  - { symbol: _make_async_url, file: backend/open_webui/internal/db.py }
  - { symbol: get_session, file: backend/open_webui/internal/db.py }
  - { symbol: get_async_db, file: backend/open_webui/internal/db.py }
  - { symbol: get_async_db_context, file: backend/open_webui/internal/db.py }
  - { symbol: SessionLocal, file: backend/open_webui/internal/db.py }
  - { symbol: AsyncSessionLocal, file: backend/open_webui/internal/db.py }
  - { symbol: run_migrations, file: backend/open_webui/config.py }
  - { symbol: get_existing_tables, file: backend/open_webui/migrations/util.py }
  - { symbol: get_revision_id, file: backend/open_webui/migrations/util.py }
verified_against_commit: 304d2d673749691abad905b96230b30ddb77e145
---

# SQLAlchemy

SQLAlchemy is the ORM and database abstraction layer for Open WebUI Extended. It
manages connection pooling, session lifecycle, schema migrations, and a declarative
model layer for all persistent data.

> **Read this first — dual-engine architecture.** `internal/db.py` builds **two**
> engines: a **sync** `engine` used *only* for startup work (Alembic migrations, import-
> time config loading, health checks) and an **async** `async_engine` used for **all
> runtime database operations**. The async engine and its `AsyncSession` factory are the
> path that request handlers, socket handlers, and model methods actually use. Any
> description that assumes a single sync engine (or that runtime code wraps sync calls in
> `asyncio.to_thread()`) describes a previous version of this codebase.

---

## Relevant Files

### Core database

| File | Subject (grep for these symbols) |
|---|---|
| `backend/open_webui/internal/db.py` | `engine`, `async_engine`, `SessionLocal`, `AsyncSessionLocal`, `get_async_db`, `get_async_db_context`, `JSONField`, `_make_async_url`, `Base` |
| `backend/open_webui/env.py` | `DATABASE_*` env vars |
| `backend/open_webui/config.py` | `run_migrations` — Alembic invocation at import time |
| `backend/open_webui/main.py` | `app.state.main_loop` (sync→async bridge for e.g. embedding generation) |

> There is **no** `internal/wrappers.py` and **no** `internal/migrations/` directory at
> time of writing — the legacy Peewee connection wrapper and Peewee migration set have
> been removed (confirm with the verification recipe; per Directive 3, prove absence with
> a root-level `find`, not a single failed lookup).

### Models

Data-access lives in `backend/open_webui/models/*.py` (25 model modules at time of
writing — confirm the count with the recipe rather than trusting this number). Each
module pairs a SQLAlchemy table, a Pydantic schema, and an async "Table" data-access
class. Notable modules include `users.py`, `auths.py`, `chats.py`, `chat_messages.py`,
`messages.py`, `channels.py`, `groups.py`, `access_grants.py`, `files.py`,
`knowledge.py`, `skills.py`, `tools.py`, `functions.py`, `prompts.py`, `tags.py`,
`folders.py`, `memories.py`, `notes.py`, `feedbacks.py`, `prompt_history.py`,
`oauth_sessions.py`, `models.py`, plus `automations.py`, `calendar.py`, and
`shared_chats.py`.

### Migrations (Alembic only)

| File | Purpose |
|---|---|
| `backend/open_webui/migrations/env.py` | Alembic env: offline/online modes, SQLCipher creator, `NullPool` |
| `backend/open_webui/migrations/util.py` | `get_existing_tables()`, `get_revision_id()` |
| `backend/open_webui/migrations/versions/*.py` | Versioned migrations; initial schema is `7e5b5dc7342b_init.py` |

### Vector database engines (separate SQLAlchemy engines)

Of the vector backends under `retrieval/vector/dbs/`, only three build their own
SQLAlchemy engine (the rest use native clients): `pgvector.py`, `mariadb_vector.py`,
`opengauss.py`. (Confirm with the `create_engine` grep in the recipe.)

---

## Engine Configuration (`internal/db.py`)

Both engines are constructed at import time. Selection is by URL scheme and by whether
`DATABASE_POOL_SIZE` is an explicit int. `pool_pre_ping=True` is set on every
explicitly-configured engine.

### Sync engine (`engine`) — startup/migrations/config only

Branches, in order (check the `if/elif/else` chain around `SQLALCHEMY_DATABASE_URL`):

1. **SQLCipher** (`sqlite+sqlcipher://`): built on a dummy `"sqlite://"` URL with a
   custom `creator` (`create_sqlcipher_connection`, which opens via `sqlcipher3` and runs
   `PRAGMA key`). Uses `QueuePool` when `DATABASE_POOL_SIZE` is an int `> 0`, otherwise
   `NullPool`.
   > **Directive 6 — intentional, do not "fix".** `NullPool` is the deliberate default
   > here. The dummy `sqlite://` URL would otherwise make SQLAlchemy pick
   > `SingletonThreadPool`, which can non-deterministically close in-use connections when
   > the thread count exceeds the pool size — segfaulting the native `sqlcipher3` C
   > library. Requires `DATABASE_PASSWORD` (raises `ValueError` if unset).
2. **SQLite** (URL contains `sqlite`): `create_engine(..., connect_args={"check_same_thread": False})`,
   with a `connect` event listener (`_apply_sqlite_pragmas`) that sets `journal_mode`
   (WAL or DELETE per `DATABASE_ENABLE_SQLITE_WAL`) plus the configurable PRAGMAs
   (`synchronous`, `busy_timeout`, `cache_size`, `temp_store`, `mmap_size`,
   `journal_size_limit`).
3. **Server DB** (Postgres/MariaDB/etc.): `QueuePool` when `DATABASE_POOL_SIZE > 0`,
   `NullPool` when `== 0`, and SQLAlchemy's default pool when the var is unset.

### Async engine (`async_engine`) — all runtime operations

The runtime URL is derived by `_make_async_url(SQLALCHEMY_DATABASE_URL)`:

- `sqlite://` → `sqlite+aiosqlite://`
- `postgresql://` / `postgres://` / `postgresql+psycopg2://` → `postgresql+psycopg://`
  (psycopg v3, which speaks libpq natively — no SSL-param translation needed)
- `sqlite+sqlcipher://` → **raises `ValueError`**; SQLCipher is not supported on the
  async engine.

Pooling mirrors the sync logic with one SQLite-specific twist:

> **Directive 5/6 — surprising default with a reason.** For SQLite the async engine uses
> `pool_size = DATABASE_POOL_SIZE` when that is a positive int, otherwise a generous
> hard-coded `512` (the literal in `db.py` at time of writing). Async coroutines without
> session sharing create high concurrent connection demand, so the default is sized far
> above the usual server-DB pool. Server DBs use `QueuePool` (`pool_size > 0`), `NullPool`
> (`== 0`), or the library default (unset).

On Windows with a Postgres URL, `db.py` switches the event loop to
`WindowsSelectorEventLoopPolicy` at import time, because psycopg v3 async cannot run on
the default `ProactorEventLoop`.

### SSL URL normalization

`extract_ssl_params_from_url()` / `reattach_ssl_params_to_url()` strip and re-emit SSL
query params (`sslmode`, `sslrootcert`, …) in canonical libpq form for the **sync**
engine (psycopg2). The async engine (psycopg v3) needs no translation and receives the
URL as-is.

---

## Connection Pooling

| Pool type | When used (per the branch logic above) | Behavior |
|---|---|---|
| `QueuePool` | `DATABASE_POOL_SIZE > 0` on a server DB or SQLCipher | Fixed-size pool; callers wait up to `pool_timeout` for a connection |
| `NullPool` | `DATABASE_POOL_SIZE == 0`, or SQLCipher without an explicit positive pool size | New connection per checkout, closed on return; no pooling |
| Library default | `DATABASE_POOL_SIZE` unset (server DB) / SQLite | SQLAlchemy decides |

Pool parameters (env var → symbol; defaults are the fallbacks in `env.py` **at time of
writing**, with the symbol as source of truth):

| Symbol | Env var | Default | Meaning |
|---|---|---|---|
| `DATABASE_POOL_SIZE` | `DATABASE_POOL_SIZE` | `None` | Persistent pool size; `None` means library default |
| `DATABASE_POOL_MAX_OVERFLOW` | `DATABASE_POOL_MAX_OVERFLOW` | `0` | Extra connections beyond `pool_size` at peak |
| `DATABASE_POOL_TIMEOUT` | `DATABASE_POOL_TIMEOUT` | `30` | Seconds to wait for a pooled connection |
| `DATABASE_POOL_RECYCLE` | `DATABASE_POOL_RECYCLE` | `3600` | Seconds before a connection is recycled |

**`pool_pre_ping`** is always `True` on configured engines: SQLAlchemy issues a cheap
liveness check before handing out a connection and transparently discards dead ones
(server restart, idle timeout, network blip), avoiding "server closed the connection
unexpectedly" errors at the cost of minimal latency.

---

## Session Management

### Sync (`SessionLocal` / `ScopedSession` / `get_db`)

`SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine, expire_on_commit=False)`.
`expire_on_commit=False` keeps attributes usable after commit (no surprise lazy-load
queries). `ScopedSession = scoped_session(SessionLocal)` gives thread-local sessions
(SQLAlchemy sessions are not thread-safe). `get_session()` is a generator that closes
the session in `finally`; `get_db = contextmanager(get_session)`. **These are reserved
for startup/config-time work**, not request handling.

### Async (`AsyncSessionLocal` / `get_async_db` / `get_async_db_context`) — the runtime path

`AsyncSessionLocal = async_sessionmaker(bind=async_engine, class_=AsyncSession, autocommit=False, autoflush=False, expire_on_commit=False)`.

- `get_async_session()` — async generator for FastAPI `Depends()`.
- `get_async_db()` — `@asynccontextmanager` for use outside dependency injection.
- `get_async_db_context(db=None)` — reuses an existing `AsyncSession` when one is passed
  **and** `DATABASE_ENABLE_SESSION_SHARING` is true; otherwise opens a fresh
  `get_async_db()`. This is the contract model methods rely on for optional transactional
  session reuse.

> There is no sync `get_db_context` at time of writing — only the async
> `get_async_db_context`. Session sharing is an **async-only** feature now.

---

## `JSONField` Type Decorator

A `TypeDecorator` that stores arbitrary Python objects as JSON-encoded text, for
portability across SQLite and Postgres rather than relying on native JSON columns.

- `impl = types.UnicodeText` (note: text-backed, **not** `types.Text`); `cache_ok = True`.
- `process_bind_param`: `json.dumps(value)` on write, but `None` passes through as `None`.
- `process_result_value`: `json.loads(value)` on read, `None` stays `None`.
- Defines `copy()` so the type can be cloned during DDL operations.

Used for nested/complex columns (chat message content, model configs, function valves,
etc.).

---

## Migration System (Alembic only)

The Peewee/dual-migration system has been removed. Migrations are pure Alembic and run
**at import time from `config.py`**, not from `db.py`:

- `config.py` defines `run_migrations()`, which builds an `alembic.config.Config` from
  `alembic.ini`, sets `script_location` to the migrations path, and calls
  `command.upgrade(alembic_cfg, "head")`.
- It is gated by `ENABLE_DB_MIGRATIONS` (default `True`): `if ENABLE_DB_MIGRATIONS: run_migrations()`.

**Alembic env** (`migrations/env.py`): supports both `run_migrations_offline()` and
`run_migrations_online()`, targets the project metadata, and handles
`sqlite+sqlcipher://` URLs via a custom `sqlcipher3` creator. It uses `pool.NullPool`
for the migration connection.

**Migration utilities** (`migrations/util.py`):
- `get_existing_tables()` — returns existing table names via SQLAlchemy `inspect(conn).get_table_names()`.
- `get_revision_id()` — returns a **short** id: `uuid.uuid4().hex[:12]` (not a full UUID).

**Versions** (`migrations/versions/`): ~44 migration files at time of writing; the
initial schema is `7e5b5dc7342b_init.py`.

---

## Environment Variables

Defaults are the fallbacks in `env.py` **at time of writing**; the symbols are the
source of truth.

| Variable | Default | Description |
|---|---|---|
| `DATABASE_URL` | `sqlite:///{DATA_DIR}/webui.db` | SQLAlchemy connection URL |
| `DATABASE_TYPE` | `None` | DB type for URL construction (e.g. `postgresql`, `sqlite+sqlcipher`, `mariadb`) |
| `DATABASE_USER` / `DATABASE_PASSWORD` | `None` | Credentials (password also used for the SQLCipher `PRAGMA key`) |
| `DATABASE_HOST` / `DATABASE_PORT` / `DATABASE_NAME` | `None` | Components for URL construction |
| `DATABASE_SCHEMA` | `None` | Schema name (applied to `MetaData`) |
| `DATABASE_POOL_SIZE` | `None` | Pool size (int) or `None` for library default |
| `DATABASE_POOL_MAX_OVERFLOW` | `0` | Extra connections beyond `pool_size` |
| `DATABASE_POOL_TIMEOUT` | `30` | Seconds to wait for a pooled connection |
| `DATABASE_POOL_RECYCLE` | `3600` | Seconds before recycling a connection |
| `DATABASE_ENABLE_SQLITE_WAL` | `True` | WAL journal mode for SQLite (else `DELETE`) |
| `DATABASE_SQLITE_PRAGMA_SYNCHRONOUS` | `NORMAL` | `PRAGMA synchronous` (empty string skips it) |
| `DATABASE_SQLITE_PRAGMA_BUSY_TIMEOUT` | `5000` | `PRAGMA busy_timeout` (ms) |
| `DATABASE_SQLITE_PRAGMA_CACHE_SIZE` | `-65536` | `PRAGMA cache_size` (negative = KiB; ≈64 MB) |
| `DATABASE_SQLITE_PRAGMA_TEMP_STORE` | `MEMORY` | `PRAGMA temp_store` |
| `DATABASE_SQLITE_PRAGMA_MMAP_SIZE` | `268435456` | `PRAGMA mmap_size` (bytes; ≈256 MB) |
| `DATABASE_SQLITE_PRAGMA_JOURNAL_SIZE_LIMIT` | `67108864` | `PRAGMA journal_size_limit` (bytes; ≈64 MB) |
| `DATABASE_USER_ACTIVE_STATUS_UPDATE_INTERVAL` | `None` | Throttle interval (seconds, float) for `last_active_at` updates |
| `DATABASE_ENABLE_SESSION_SHARING` | `False` | Allow `get_async_db_context()` to reuse a passed session |
| `ENABLE_DB_MIGRATIONS` | `True` | Run Alembic migrations at startup |

> **`DATABASE_ENABLE_SQLITE_WAL` defaults to `True`** (the SQLite PRAGMA tuning is built
> around WAL mode). A prior version of this doc claimed `False` — verify against `env.py`.

### URL construction

When `DATABASE_TYPE`, credentials, `DATABASE_HOST`, `DATABASE_PORT`, and `DATABASE_NAME`
are **all** set (`all(DB_VARS.values())`), the URL is built as:

```
{DATABASE_TYPE}://{user[:password]}@{DATABASE_HOST}:{DATABASE_PORT}/{DATABASE_NAME}
```

`postgres://` URLs are rewritten to `postgresql://` in `env.py` for SQLAlchemy
compatibility (and `db.py`/`_make_async_url` further map to the psycopg v3 driver).

---

## Model Pattern

Each model module defines three layers. The data-access layer is **async** (it awaits
`get_async_db_context`); there is no `with get_db()` in the model layer at time of
writing.

```python
# 1. SQLAlchemy declarative table
class User(Base):
    __tablename__ = "user"
    id = Column(String, primary_key=True)
    # ...

# 2. Pydantic schema for API serialization
class UserModel(BaseModel):
    id: str
    # ...
    model_config = ConfigDict(from_attributes=True)

# 3. Async data-access "Table" class
class UsersTable:
    async def get_user_by_id(self, id, db=None):
        async with get_async_db_context(db) as session:
            ...
```

(Illustrative shape — grep the real `User` / `UserModel` / `UsersTable` in
`models/users.py`.)

---

## Vector Database Engines

Three backends maintain their own SQLAlchemy engine, separate from the main
sync/async engines:

- **pgvector** (`retrieval/vector/dbs/pgvector.py`) — own engine + `scoped_session`;
  uses the `pgvector` extension for similarity search; optional pgcrypto encryption.
- **MariaDB vector** (`retrieval/vector/dbs/mariadb_vector.py`) — `QueuePool`; raw DBAPI
  cursor for binary vector binding; context-managed connection lifecycle.
- **OpenGauss** (`retrieval/vector/dbs/opengauss.py`) — custom dialect registration;
  pooling that mirrors the main DB patterns.

---

## Interaction with Other Components

- **Async runtime, not thread-pooling** — runtime DB access goes through `async_engine`
  + `AsyncSession` and is awaited directly; it does **not** route through
  `asyncio.to_thread()`. The sync engine exists only for import-time startup work. (This
  reverses the previous "all sync ops go through `to_thread`" claim.)
- **WebSockets** — socket handlers call async model methods directly (e.g.
  `await Chats.upsert_message_to_chat_by_id_and_message_id(...)`), backed by the async
  engine. See [heartbeats.md](./heartbeats.md).
- **Heartbeats** — the `heartbeat` handler awaits `Users.update_last_active_by_id()`,
  which persists `last_active_at` via `AsyncSession`. See [heartbeats.md](./heartbeats.md).
- **Redis** — Redis holds ephemeral state (sessions, locks, pub/sub); SQLAlchemy holds
  persistent state. `AppConfig` (in `internal/config.py`, **not** `config.py`) bridges
  both: live values cached in Redis, durable values in the database. See
  [redis.md](./redis.md).

---

## Verification Recipe

Run from the repo root. If any line's expectation is violated, the doc is stale and must
be re-audited before it is trusted.

```bash
# Dual engine + async session factory
grep -rn "^engine = \|create_async_engine\|async_engine =\|AsyncSessionLocal\|SessionLocal =" backend/open_webui/internal/db.py
grep -rn "def get_async_db\b\|def get_async_db_context\|def _make_async_url" backend/open_webui/internal/db.py

# JSONField is UnicodeText-backed
grep -rn "class JSONField\|impl = types.UnicodeText" backend/open_webui/internal/db.py

# SQLCipher NullPool rationale (intentional code)
grep -rn "SingletonThreadPool\|poolclass=NullPool" backend/open_webui/internal/db.py

# Migrations are Alembic-only, invoked from config.py
grep -rn "def run_migrations\|command.upgrade\|ENABLE_DB_MIGRATIONS" backend/open_webui/config.py
grep -rn "def get_existing_tables\|def get_revision_id\|hex\[:12\]" backend/open_webui/migrations/util.py
ls backend/open_webui/migrations/versions/7e5b5dc7342b_init.py

# Peewee system is GONE (prove absence — Directive 3)
ls backend/open_webui/internal/wrappers.py 2>/dev/null || echo "wrappers.py absent (expected)"
ls -d backend/open_webui/internal/migrations 2>/dev/null || echo "internal/migrations absent (expected)"

# Counts (compare to the numbers in this doc)
ls backend/open_webui/models/*.py | grep -v __init__ | wc -l                # expect ~25
ls backend/open_webui/migrations/versions/*.py | grep -v __init__ | wc -l   # expect ~44

# Env vars + WAL default
grep -rn "DATABASE_ENABLE_SQLITE_WAL\|DATABASE_SQLITE_PRAGMA_\|DATABASE_ENABLE_SESSION_SHARING\|DATABASE_POOL_" backend/open_webui/env.py

# Model layer is async
grep -rln "get_async_db" backend/open_webui/models/*.py | wc -l             # expect > 0
grep -rln "with get_db()" backend/open_webui/models/*.py | wc -l            # expect 0

# Only three vector backends build a SQLAlchemy engine
grep -rln "create_engine" backend/open_webui/retrieval/vector/dbs/

# main_loop bridge
grep -rn "app.state.main_loop" backend/open_webui/main.py
```
