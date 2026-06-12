# CLAUDE.md — Open WebUI Extended

> Agent + developer bootstrap for the Open WebUI Extended backend. This file is intentionally
> free of code anchors and volatile counts; it points at anchored docs that carry both. Items
> marked **(confirm against repo)** were not yet read from the source scripts and must be
> verified before they are trusted — per `DOCUMENTATION_STANDARD.md` Directive 3.

## What This Is

Open WebUI Extended is an **async-first FastAPI + Socket.IO** application: a multi-provider LLM
chat platform with RAG, tools/functions, real-time streaming and collaborative editing, and an
extended feature set (calendar, automations, skills, analytics, evaluations, terminals, SCIM,
and an Anthropic provider path) layered on upstream Open WebUI. It runs as a single instance with
no external dependencies, or horizontally scaled behind Redis and PostgreSQL. The same code paths
serve both; the difference is *where shared state lives*, not *what the code does*.

Start with `ARCHITECTURE.md` for the system map and `DOCUMENTATION_INDEX.md` to route a task to
the right doc.

## Commands

The process entry point is the `open-webui` Typer CLI (`backend/open_webui/__init__.py`; see
`cli-entrypoint.md`):

- `open-webui serve` — production launch. Sets `FROM_INIT_PY`, generates/loads the secret key,
  optionally wires CUDA, then runs `uvicorn open_webui.main:app` with `UVICORN_WORKERS`.
- `open-webui dev` — development launch with `reload=True`. **Does not** do the secret-key/CUDA
  bootstrap that `serve` does.
- `open-webui --version` — prints the version and exits.

Other entry points exist as scripts in the tree and **(confirm against repo)** before relying on
exact invocations: `backend/dev.sh`, `backend/start.sh`, the root `package.json` (SvelteKit
frontend dev/build), `pyproject.toml`, and the `docker-*.sh` helpers. There is **no documented
backend test suite** at present (see "Things That Will Bite You").

## Session Orientation

At the start of a session that touches an unfamiliar area:

1. Read `ARCHITECTURE.md` for the layer map and the cross-cutting invariants.
2. Read `DOCUMENTATION_INDEX.md` and jump to the relevant component doc.
3. If you hit an unfamiliar or easily-confused term (`SESSION_POOL` vs `USAGE_POOL`,
   `env.py` vs `config.py`, `tasks.py` vs `utils/task.py`, pipe vs filter vs function vs tool),
   check `DOMAIN_GLOSSARY.md` before guessing.
4. Trust each component doc's anchor block + verification recipe over this file or any overview.

## Architecture Invariants (NEVER VIOLATE)

These hold across the whole backend. If code or a doc seems to contradict one, re-verify against
the code before acting — do not "fix" the code to match a stale belief.

- **Async-first runtime.** The request and socket paths are `async` end-to-end. Genuinely blocking
  synchronous work (LDAP, audio, reranking, a few vector clients) is offloaded with
  `asyncio.to_thread` / `ThreadPoolExecutor` under the AnyIO limiter. (`threadpooling.md`)
- **Runtime database access is NOT thread-pooled.** Queries use the **async** SQLAlchemy engine and
  `AsyncSession`, awaited directly. The sync engine is startup-only (Alembic, import-time config,
  health checks). Do **not** wrap DB calls in `asyncio.to_thread`. DB concurrency is bounded by the
  async engine's pool (`DATABASE_POOL_SIZE`/overflow), independently of `THREAD_POOL_SIZE`.
  (`sqlalchemy.md`, `database-infrastructure.md`)
- **`env.py` ≠ `config.py`.** `env.py` = plain, read-at-import infra settings. The large catalog of
  user-facing settings (AI providers, RAG, OAuth, web search, most feature flags) lives in
  `config.py` as DB-backed `ConfigVar`s, editable from the Admin UI via `AppConfig`
  (`internal/config.py`). Do not expect `THREAD_POOL_SIZE`, `JWT_EXPIRES_IN`, `CORS_ALLOW_ORIGIN`,
  or RAG/OAuth vars in `env.py`. (`env-configuration.md`)
- **There is no `USER_POOL`.** Pools are `SESSION_POOL`, `USAGE_POOL`, `MODELS`. Per-user fan-out
  uses a Socket.IO **room** (`user:{id}`); the streaming event is **`events`** (channels use
  `events:channel` / `events:chat`). (`socket-realtime.md`, `websockets.md`)
- **Vector reads go through `ASYNC_VECTOR_DB_CLIENT`**, an async wrapper over the sync
  `VECTOR_DB_CLIENT`. The store is pluggable behind `VectorDBBase`; pgvector is the documented
  backend. (`retrieval-utils.md`, `vector-pgvector.md`)
- **Resources are initialized in the `lifespan` context manager**, not `@app.on_event("startup")`.
  `app.state` holds `MODELS`/`BASE_MODELS`, `EMBEDDING_FUNCTION`/`RERANKING_FUNCTION` (note:
  `RERANKING_FUNCTION`, not `RERANKER_FUNCTION`), `ef`/`rf`, `redis`, OAuth managers, tool/terminal
  servers. (`main-entrypoint.md`)
- **State location is the single/multi-instance difference.** With Redis configured, the
  pools/locks/task-registry move from in-process Python objects to Redis hashes and pub/sub.

## Things That Will Bite You

- **`tasks.py` is not `utils/task.py`.** `tasks.py` = the runtime `asyncio` task registry
  (cancel long-running ops, cross-instance via Redis pub/sub). `utils/task.py` = prompt **templates**
  for automated features (title/tags/RAG/autocomplete). Different files, different jobs.
  (`task-management.md`, `task-templates.md`)
- **Middleware is pure-ASGI classes via `app.add_middleware(...)`**, not `@app.middleware("http")`
  decorators. The old `check_url` / `commit_session_after_request` functions are gone, replaced by
  `AuthTokenMiddleware` / `CommitSessionMiddleware` in `utils/asgi_middleware.py`. (`main-entrypoint.md`)
- **Peewee is entirely removed.** Migrations are pure **Alembic**, run from `config.py`'s
  `run_migrations()` (gated by `ENABLE_DB_MIGRATIONS`). There is no `internal/wrappers.py` and no
  `internal/migrations/`. Prove absence from the repo root before claiming any of these is back.
  (`database-infrastructure.md`, `DIRECTIVE_database_migration.md`)
- **`RedisDict` bulk-set deliberately never `DELETE`s the hash** — it `HSET`s new values then `HDEL`s
  stale keys, specifically so concurrent readers never observe an empty dict. Do **not** refactor it
  to "atomic `DELETE` + `HSET`"; that reintroduces the race. (`redis.md`, `DOCUMENTATION_STANDARD.md`
  Directive 6)
- **Pipelines are legacy.** A Pipeline pipe → use a **Pipe Function**; a Pipeline filter → use a
  **Filter Function**. Don't build new features on Pipelines. (Project knowledge: official Filters /
  Functions docs.)
- **Windows + Postgres async** uses `WindowsSelectorEventLoopPolicy` / `loop="none"` — psycopg v3 async
  is incompatible with the default `ProactorEventLoop`. (`cli-entrypoint.md`, `database-infrastructure.md`)
- **Do not read the largest files or docs in full.** `config.py` and `main.py` are large; read targeted
  ranges. Among the reference docs, the official **Tools** capture is very large — read selectively.
  Authoritative size/token tiers live in `FILE_TREE.md` once generated.
- **The dominant source of drift is the upstream merge, not your edits.** After merging upstream, run
  the staleness check and treat its STALE list as the doc-reconciliation worklist for that merge
  (`DOCUMENTATION_DRIFT_AUTOMATION.md`).

## Documentation Conventions (binding)

All architecture/component docs follow `DOCUMENTATION_STANDARD.md`. The rules an agent breaks most
often:

- **Anchor, don't transcribe.** Cite symbols (`grep`-able), never line numbers. Describe the contract
  and the *why*; never paste implementation that will rot (Directives 1, 4).
- **One source of truth per number.** Name the symbol; mark the value as "at time of writing." Aggregate
  counts (routers, models, migrations, LOC) live **only** in the dated `FILE_TREE.md`, never in prose
  (Directive 5, III.4).
- **Every doc opens with an anchor block and closes with a verification recipe** (Directives 8, 10).
- **Advance a marker only as the output of a re-read** — never silent-bump, bump-to-green, or batch-bump
  (Directive 11.3).
- **Prove absence from the repo root before deleting any reference** (Directive 3).
- **Flag deliberate-but-surprising code loudly** so the next agent doesn't "fix" it into a bug
  (Directive 6).

## Code Conventions (from the corpus; confirm before extending)

- Request handlers are `async def` and take `db: AsyncSession = Depends(get_async_session)`; model
  calls are awaited (`await Chats.get_chat_by_id_and_user_id(...)`).
- New settings: decide `env.py` (read-at-import infra) vs `config.py` `ConfigVar` (user-facing,
  DB-backed, Admin-UI editable) — see the invariant above.
- New DB tables/migrations: follow `DIRECTIVE_database_migration.md` (Alembic, `models/`, `JSONField`
  for nested JSON, the sync engine for DDL).
- Access control for chats/files/resources goes through `AccessGrants` / `has_access_to_file` /
  `Knowledges.check_access_by_user_id` — not ad-hoc checks. (`routers.md`, `socket-realtime.md`)
- A new vector backend is registered behind `VectorDBBase` via the factory; a new web-search provider
  lives under `retrieval/web/`. These are the high-churn edges — cover them at directory/`whole_file`
  granularity in docs (Standard III.2), not per-symbol.

## After Every Task

1. If you added, removed, or renamed files: update `FILE_TREE.md` (it carries the date and all volatile
   counts).
2. If you changed code a doc covers: re-read the affected doc and **advance its marker as the output of
   that re-read** (Standard 11.3) — fix prose and `covers_symbols` together, or record the affirmation.
3. If the change is architecturally significant: note it where the project tracks change history.
4. If you discovered a convention an agent gets wrong repeatedly: add a concise line here; if a line here
   no longer applies, delete it.
5. Do **not** add volatile counts to this file — they belong in the dated `FILE_TREE.md`.
