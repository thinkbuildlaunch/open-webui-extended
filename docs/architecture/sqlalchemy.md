# SQLAlchemy

SQLAlchemy serves as the ORM and database abstraction layer for Open WebUI Extended. It manages connection pooling, session lifecycle, schema migrations, and provides a declarative model layer for all persistent data.

---

## Relevant Files

### Core Database
| File | Purpose |
|---|---|
| `backend/open_webui/internal/db.py` | Engine creation, session factory, connection pooling, `JSONField`, migration bootstrap |
| `backend/open_webui/internal/wrappers.py` | Legacy Peewee connection wrapper for pre-Alembic migrations |
| `backend/open_webui/env.py` (lines 328-416) | Database environment variables |
| `backend/open_webui/main.py` (line 608) | Stores `main_loop` reference for sync-to-async bridging |

### Models (22 core models)
| File | Model(s) |
|---|---|
| `backend/open_webui/models/users.py` | User accounts, OAuth, SCIM |
| `backend/open_webui/models/auths.py` | Authentication records |
| `backend/open_webui/models/chats.py` | Chat conversations |
| `backend/open_webui/models/chat_messages.py` | Individual chat messages |
| `backend/open_webui/models/messages.py` | Channel messages, user status |
| `backend/open_webui/models/channels.py` | Channel definitions, members |
| `backend/open_webui/models/groups.py` | User groups |
| `backend/open_webui/models/access_grants.py` | Access control permissions |
| `backend/open_webui/models/files.py` | File metadata |
| `backend/open_webui/models/knowledge.py` | RAG knowledge base |
| `backend/open_webui/models/skills.py` | Custom skills |
| `backend/open_webui/models/tools.py` | Tool definitions |
| `backend/open_webui/models/functions.py` | Custom functions with valves |
| `backend/open_webui/models/prompts.py` | Saved prompts |
| `backend/open_webui/models/tags.py` | Tagging system |
| `backend/open_webui/models/folders.py` | Chat folder organization |
| `backend/open_webui/models/memories.py` | User memories/context |
| `backend/open_webui/models/notes.py` | User notes |
| `backend/open_webui/models/feedbacks.py` | Chat feedback/ratings |
| `backend/open_webui/models/prompt_history.py` | Prompt usage history |
| `backend/open_webui/models/oauth_sessions.py` | OAuth session tracking |
| `backend/open_webui/models/models.py` | LLM model configurations |

### Migrations
| File | Purpose |
|---|---|
| `backend/open_webui/migrations/env.py` | Alembic configuration |
| `backend/open_webui/migrations/util.py` | Migration utilities |
| `backend/open_webui/migrations/versions/*.py` | 25+ versioned Alembic migrations |
| `backend/open_webui/internal/migrations/*.py` | 18 legacy Peewee migrations |

### Vector Database Implementations (Separate SQLAlchemy Engines)
| File | Purpose |
|---|---|
| `backend/open_webui/retrieval/vector/dbs/pgvector.py` | PostgreSQL with pgvector extension |
| `backend/open_webui/retrieval/vector/dbs/mariadb_vector.py` | MariaDB vector support |
| `backend/open_webui/retrieval/vector/dbs/opengauss.py` | OpenGauss vector support |

---

## Engine Configuration (`internal/db.py`)

The engine is configured differently based on the database backend:

### SQLite (Default)

```python
engine = create_engine(
    SQLALCHEMY_DATABASE_URL,
    connect_args={"check_same_thread": False}  # Required for SQLite with threads
)
```

- No connection pooling (SQLAlchemy's default `StaticPool` for SQLite)
- Optional WAL mode via `DATABASE_ENABLE_SQLITE_WAL`
- WAL journal mode set via `PRAGMA journal_mode=WAL` on each connection

### SQLCipher (Encrypted SQLite)

```python
# With explicit pool size
engine = create_engine(
    "sqlite://",                              # Dummy URL
    creator=create_sqlcipher_connection,       # Custom creator using sqlcipher3
    pool_size=DATABASE_POOL_SIZE,
    max_overflow=DATABASE_POOL_MAX_OVERFLOW,
    pool_timeout=DATABASE_POOL_TIMEOUT,
    pool_recycle=DATABASE_POOL_RECYCLE,
    pool_pre_ping=True,
    poolclass=QueuePool,
)

# Without pool size (safe default)
engine = create_engine(
    "sqlite://",
    creator=create_sqlcipher_connection,
    poolclass=NullPool,                       # No pooling for thread safety
)
```

The custom creator:
```python
def create_sqlcipher_connection():
    import sqlcipher3
    conn = sqlcipher3.connect(db_path, check_same_thread=False)
    conn.execute(f"PRAGMA key = '{database_password}'")
    return conn
```

**Important**: `NullPool` is the default for SQLCipher because `SingletonThreadPool` (SQLAlchemy's default for `sqlite://`) can non-deterministically close in-use connections in multi-threaded scenarios, causing segfaults in the native sqlcipher3 C library.

### PostgreSQL / MariaDB / Other Server Databases

```python
# With explicit pool size > 0: QueuePool
engine = create_engine(
    SQLALCHEMY_DATABASE_URL,
    pool_size=DATABASE_POOL_SIZE,
    max_overflow=DATABASE_POOL_MAX_OVERFLOW,
    pool_timeout=DATABASE_POOL_TIMEOUT,
    pool_recycle=DATABASE_POOL_RECYCLE,
    pool_pre_ping=True,
    poolclass=QueuePool,
)

# With pool size = 0: NullPool (no pooling)
engine = create_engine(
    SQLALCHEMY_DATABASE_URL,
    pool_pre_ping=True,
    poolclass=NullPool,
)

# With no pool size specified: SQLAlchemy defaults
engine = create_engine(
    SQLALCHEMY_DATABASE_URL,
    pool_pre_ping=True,
)
```

---

## Connection Pooling

### Pool Types

| Pool Type | When Used | Behavior |
|---|---|---|
| `QueuePool` | `DATABASE_POOL_SIZE > 0` on non-SQLite DBs, or explicitly for SQLCipher | Maintains a fixed-size pool of connections. Threads wait up to `pool_timeout` for a connection. |
| `NullPool` | `DATABASE_POOL_SIZE = 0`, or SQLCipher without explicit pool size | Creates a new connection per request, closes immediately after use. No pooling overhead. |
| SQLAlchemy default | `DATABASE_POOL_SIZE` not set | Library decides (typically `QueuePool` with defaults for server DBs, `StaticPool` for SQLite) |

### Pool Parameters

| Parameter | Env Variable | Default | Description |
|---|---|---|---|
| `pool_size` | `DATABASE_POOL_SIZE` | `None` (library default) | Maximum number of persistent connections in the pool |
| `max_overflow` | `DATABASE_POOL_MAX_OVERFLOW` | `0` | Additional connections allowed beyond `pool_size` during peak load |
| `pool_timeout` | `DATABASE_POOL_TIMEOUT` | `30` | Seconds to wait for a connection from the pool before raising `TimeoutError` |
| `pool_recycle` | `DATABASE_POOL_RECYCLE` | `3600` | Seconds after which a connection is recycled (closed and replaced). Prevents stale connections from server-side timeouts. |
| `pool_pre_ping` | Always `True` | `True` | Issue a `SELECT 1` before using a connection to detect and discard broken connections |

### `pool_pre_ping` Explained

Every connection checked out from the pool has a lightweight `SELECT 1` executed against it first. If the connection is dead (server restarted, network blip, idle timeout), it's silently discarded and a fresh one is created. This adds minimal latency but prevents `OperationalError: server closed the connection unexpectedly` errors.

---

## Session Management

### Session Factory

```python
SessionLocal = sessionmaker(
    autocommit=False,
    autoflush=False,
    bind=engine,
    expire_on_commit=False   # Prevents lazy-load queries after commit
)
```

### Scoped Session

```python
ScopedSession = scoped_session(SessionLocal)
```

`scoped_session` provides thread-local session management. Each thread gets its own session instance, preventing cross-thread session corruption. This is critical because SQLAlchemy sessions are **not thread-safe**.

### Session Lifecycle Functions

```python
def get_session():
    """Generator that yields a session and closes it when done."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

get_db = contextmanager(get_session)

@contextmanager
def get_db_context(db: Optional[Session] = None):
    """Reuses an existing session if session sharing is enabled."""
    if isinstance(db, Session) and DATABASE_ENABLE_SESSION_SHARING:
        yield db
    else:
        with get_db() as session:
            yield session
```

### Session Sharing

When `DATABASE_ENABLE_SESSION_SHARING=True`, `get_db_context()` reuses an existing session passed to it instead of creating a new one. This is useful for operations that need transactional consistency across multiple model calls.

---

## `JSONField` Type Decorator

A custom SQLAlchemy type that transparently serializes/deserializes JSON:

```python
class JSONField(types.TypeDecorator):
    impl = types.Text
    cache_ok = True

    def process_bind_param(self, value, dialect):
        return json.dumps(value)

    def process_result_value(self, value, dialect):
        if value is not None:
            return json.loads(value)
```

Used by models to store complex nested data (e.g., chat message content, model configurations, function valves) in a text column.

---

## Migration System

### Dual Migration Strategy

The codebase uses **two** migration systems in sequence:

1. **Peewee migrations** (legacy): Run first during module import
2. **Alembic migrations** (current): Run after Peewee migrations

```python
# db.py - runs at import time
if ENABLE_DB_MIGRATIONS:
    handle_peewee_migration(DATABASE_URL)
```

### Peewee Migrations (`internal/migrations/`)

- 18 migration files (001-018)
- Run via `peewee_migrate.Router`
- Handle legacy schema changes from before the SQLAlchemy transition
- Each migration is applied once and tracked in a Peewee migration table
- The database connection is properly closed after migration

### Alembic Migrations (`migrations/`)

**Configuration** (`migrations/env.py`):
- Supports both online and offline migration modes
- SQLCipher support via custom creator function
- Uses `NullPool` during migrations to avoid connection issues
- Target metadata from `Base.metadata`

**Utilities** (`migrations/util.py`):
- `get_existing_tables()`: Uses SQLAlchemy `Inspector` to discover existing tables
- `get_revision_id()`: Generates UUID-based revision IDs

**Versions** (`migrations/versions/`):
- 25+ versioned migration files
- Initial schema: `7e5b5dc7342b_init.py`
- Performance indexes: `018012973d35_add_indexes.py`
- Feature additions: channels, messages, knowledge, access grants, etc.

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `DATABASE_URL` | `sqlite:///data/webui.db` | SQLAlchemy connection URL |
| `DATABASE_TYPE` | `None` | DB type for URL construction: `postgres`, `sqlite+sqlcipher`, `mariadb`, `postgresql` |
| `DATABASE_USER` | `None` | Database username (for URL construction) |
| `DATABASE_PASSWORD` | `None` | Database password (for URL construction and SQLCipher PRAGMA key) |
| `DATABASE_HOST` | `None` | Database hostname (for URL construction) |
| `DATABASE_PORT` | `None` | Database port (for URL construction) |
| `DATABASE_NAME` | `None` | Database name (for URL construction) |
| `DATABASE_SCHEMA` | `None` | PostgreSQL schema name |
| `DATABASE_POOL_SIZE` | `None` | Connection pool size (int or None for library defaults) |
| `DATABASE_POOL_MAX_OVERFLOW` | `0` | Extra connections beyond pool_size |
| `DATABASE_POOL_TIMEOUT` | `30` | Seconds to wait for a pool connection |
| `DATABASE_POOL_RECYCLE` | `3600` | Seconds before recycling a connection |
| `DATABASE_ENABLE_SQLITE_WAL` | `False` | Enable WAL journal mode for SQLite |
| `DATABASE_ENABLE_SESSION_SHARING` | `False` | Allow `get_db_context()` to reuse existing sessions |
| `DATABASE_USER_ACTIVE_STATUS_UPDATE_INTERVAL` | `None` | Throttle interval for `last_active_at` updates (seconds) |
| `ENABLE_DB_MIGRATIONS` | `True` | Run migrations on startup |

### URL Construction

If individual `DATABASE_*` variables are all set, the URL is constructed automatically:

```
{DATABASE_TYPE}://{DATABASE_USER}:{DATABASE_PASSWORD}@{DATABASE_HOST}:{DATABASE_PORT}/{DATABASE_NAME}
```

`postgres://` URLs are automatically rewritten to `postgresql://` for SQLAlchemy compatibility.

---

## Model Pattern

All models follow a consistent pattern:

1. **SQLAlchemy declarative model** (table definition):
   ```python
   class User(Base):
       __tablename__ = "user"
       id = Column(String, primary_key=True)
       name = Column(String)
       email = Column(String)
       # ...
   ```

2. **Pydantic model** (API serialization):
   ```python
   class UserModel(BaseModel):
       id: str
       name: str
       email: str
       # ...
       model_config = ConfigDict(from_attributes=True)
   ```

3. **Table class** (data access layer):
   ```python
   class UsersTable:
       def get_user_by_id(self, id: str) -> Optional[UserModel]:
           with get_db() as db:
               user = db.get(User, id)
               return UserModel.model_validate(user) if user else None
   ```

---

## Vector Database Engines

Several vector database backends maintain their own separate SQLAlchemy engines:

### PgVector (`retrieval/vector/dbs/pgvector.py`)
- Separate engine with its own pool configuration
- Uses the `pgvector` PostgreSQL extension for vector similarity search
- `scoped_session` for thread-safe access
- Optional pgcrypto encryption

### MariaDB Vector (`retrieval/vector/dbs/mariadb_vector.py`)
- `QueuePool` for connection pooling
- Raw DBAPI cursor for binary vector binding
- Context manager for connection lifecycle

### OpenGauss (`retrieval/vector/dbs/opengauss.py`)
- Custom dialect registration
- Pool configuration matching main database patterns

---

## Interaction with Other Components

### SQLAlchemy + ThreadPooling
All synchronous SQLAlchemy operations called from async context use `asyncio.to_thread()`, which is governed by the AnyIO thread limiter. See [ThreadPooling](./threadpooling.md) for details on how these interact.

### SQLAlchemy + WebSockets
Socket event handlers that need database access delegate to `asyncio.to_thread()`:
```python
await asyncio.to_thread(Chats.upsert_message_to_chat_by_id_and_message_id, ...)
```

### SQLAlchemy + Heartbeats
Each heartbeat triggers `Users.update_last_active_by_id()` to persist the `last_active_at` timestamp.

### SQLAlchemy + Redis
Redis handles ephemeral state (sessions, locks, pub/sub), while SQLAlchemy handles persistent state (users, chats, notes). The `AppConfig` class in `config.py` bridges both: live values in Redis, backed by the database.
