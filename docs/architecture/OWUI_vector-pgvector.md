---
# Machine-readable anchor block — see I.8 / Part II.
covers_files:
  - backend/open_webui/retrieval/vector/main.py
  - backend/open_webui/retrieval/vector/dbs/pgvector.py
  - backend/open_webui/config.py
  - backend/open_webui/retrieval/vector/utils.py
  - backend/open_webui/utils/misc.py
covers_symbols:
  - { symbol: VectorDBBase, file: backend/open_webui/retrieval/vector/main.py }
  - { symbol: SearchResult, file: backend/open_webui/retrieval/vector/main.py }
  - { symbol: PgvectorClient, file: backend/open_webui/retrieval/vector/dbs/pgvector.py }
  - { symbol: DocumentChunk, file: backend/open_webui/retrieval/vector/dbs/pgvector.py }
  - { symbol: _vector_index_configuration, file: backend/open_webui/retrieval/vector/dbs/pgvector.py }
  - { symbol: _ensure_vector_index, file: backend/open_webui/retrieval/vector/dbs/pgvector.py }
  - { symbol: check_vector_length, file: backend/open_webui/retrieval/vector/dbs/pgvector.py }
  - { symbol: adjust_vector_length, file: backend/open_webui/retrieval/vector/dbs/pgvector.py }
  - { symbol: search, file: backend/open_webui/retrieval/vector/dbs/pgvector.py }
  - { symbol: upsert, file: backend/open_webui/retrieval/vector/dbs/pgvector.py }
  - { symbol: pgcrypto_decrypt, file: backend/open_webui/retrieval/vector/dbs/pgvector.py }
  - { symbol: PGVECTOR_USE_HALFVEC, file: backend/open_webui/config.py }
verified_against_commit: 5d70c391f36c31b6629b85c89f3d3b86b5a7f1e9
---

# Vector Database: pgvector

The pgvector backend (`PgvectorClient`) stores RAG document chunks and their embeddings in
PostgreSQL via the `pgvector` extension, behind the pluggable `VectorDBBase` interface.
It supports cosine-similarity search over single or batched query vectors, metadata
filtering, optional pgcrypto encryption of text/metadata, and **two index families**
(IVFFLAT and HNSW, the latter paired with the `halfvec` column type).

> **What changed since the original guide.** This doc was reconciled against the code.
> The biggest correction: indexing is no longer "IVFFLAT with `lists = 100`, full stop."
> The client now selects between **IVFFLAT and HNSW** (`_vector_index_configuration`),
> uses the **`halfvec`** column type when `PGVECTOR_USE_HALFVEC` is set, and **refuses to
> auto-rebuild** an index whose method no longer matches (`_ensure_vector_index`). Other
> corrections: `search` takes a `filter` argument; extension creation is gated and
> permission-safe; the shared session is `ScopedSession`; and inserts/upserts run text and
> metadata through `sanitize_text_for_db` / `process_metadata`.

---

## Relevant Files

| File | Subject (grep these symbols) |
|---|---|
| `backend/open_webui/retrieval/vector/main.py` | `VectorDBBase` (abstract interface), `VectorItem`, `GetResult`, `SearchResult` |
| `backend/open_webui/retrieval/vector/dbs/pgvector.py` | `PgvectorClient`, `DocumentChunk`, `_vector_index_configuration`, `_ensure_vector_index`, `check_vector_length`, `adjust_vector_length`, `search`, `insert`, `upsert`, `query`, `get`, `delete`, `pgcrypto_encrypt`/`pgcrypto_decrypt` |
| `backend/open_webui/config.py` | `PGVECTOR_*` env vars |
| `backend/open_webui/retrieval/vector/utils.py` | `process_metadata` (non-encrypted metadata coercion) |
| `backend/open_webui/utils/misc.py` | `sanitize_text_for_db` (strip null bytes/surrogates) |

---

## 1. Abstract Interface (`VectorDBBase`, `main.py`)

`VectorDBBase(ABC)` defines the backend contract every vector DB implements. Abstract
methods: `has_collection`, `delete_collection`, `insert`, `upsert`, `search`, `query`,
`get`, `delete`, `reset`.

> **`search` signature (corrected).** It is
> `search(collection_name, vectors, filter=None, limit=10)` — the original doc dropped the
> `filter` argument and showed `limit` without a default. Metadata filtering is now part of
> the similarity-search path, not only `query`.

## 2. Data Models (`main.py`)

- `VectorItem` — `id: str`, `text: str`, `vector: List[float | int]`, `metadata: Any`.
- `GetResult` — `ids`, `documents`, `metadatas`, each `Optional[List[List[...]]]`.
- `SearchResult(GetResult)` — adds `distances: Optional[List[List[float | int]]]`.

The nested `List[List[...]]` shape is per-query: index 0 of each list corresponds to the
first query vector, enabling batched search.

## 3. Schema (`DocumentChunk`, `pgvector.py`)

`DocumentChunk` (`__tablename__ = "document_chunk"`):

- `id: Text` primary key, `collection_name: Text` (indexed), and a vector column.
- **Vector column type is dynamic**: `Column(VECTOR_TYPE_FACTORY(dim=VECTOR_LENGTH))`, where
  `VECTOR_TYPE_FACTORY = HALFVEC if USE_HALFVEC else Vector` and
  `VECTOR_LENGTH = PGVECTOR_INITIALIZE_MAX_VECTOR_LENGTH`. (The original's hard-coded
  `Vector(dim=…)` no longer holds.)
- `text` / `vmetadata` columns switch on `PGVECTOR_PGCRYPTO`: `LargeBinary` (BYTEA) when
  encryption is on, else `Text` and `MutableDict.as_mutable(JSONB)`.

## 4. Initialization (`PgvectorClient.__init__`)

Contract (read the constructor; it is wrapped in `try/except` that rolls back and re-raises):

1. **Session.** If `PGVECTOR_DB_URL` is falsy, reuse the app's sync `ScopedSession`
   (`from open_webui.internal.db import ScopedSession`). Otherwise build a **dedicated
   engine** on `PGVECTOR_DB_URL` and a `scoped_session` over it. (Note: `PGVECTOR_DB_URL`
   defaults to `DATABASE_URL`, so the dedicated-engine path is the default.)
2. **Extensions, permission-safe.** When `PGVECTOR_CREATE_EXTENSION` is true, run a
   `DO $$ … IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='vector') … $$` block
   (the conditional guard avoids permission errors on managed Postgres, e.g. Azure) — not a
   bare `CREATE EXTENSION`. The same pattern installs `pgcrypto` when `PGVECTOR_PGCRYPTO`
   is on, which additionally **requires** `PGVECTOR_PGCRYPTO_KEY` (else `ValueError`).
3. `check_vector_length()` (see §5), then `Base.metadata.create_all(...)`.
4. **Index** via `_vector_index_configuration()` + `_ensure_vector_index()` (see §6), plus a
   plain B-tree index `idx_document_chunk_collection_name` on `collection_name`.

## 5. Vector Dimension Handling

- `check_vector_length()` reflects the existing `document_chunk` table (returns early via
  `NoSuchTableError` if absent) and raises if the `vector` column's type isn't the
  **expected** type (`HALFVEC` vs `Vector`, per `USE_HALFVEC`) or its `dim` differs from
  `VECTOR_LENGTH` — vector size cannot change post-init without data migration.
- `adjust_vector_length(vector)` zero-pads short vectors and truncates long ones to
  `VECTOR_LENGTH`; applied to every inserted and queried vector.

## 6. Indexing Strategy (IVFFLAT **and** HNSW)

> **I.6 — intentional: index method is chosen, and mismatches are NOT auto-fixed.**

`_vector_index_configuration()` returns `(index_method, index_options)`:

- If `PGVECTOR_INDEX_METHOD` is set, use it verbatim.
- Else if `USE_HALFVEC`, use `hnsw`.
- Else use `ivfflat`.
- Options: HNSW → `WITH (m = PGVECTOR_HNSW_M, ef_construction = PGVECTOR_HNSW_EF_CONSTRUCTION)`;
  IVFFLAT → `WITH (lists = PGVECTOR_IVFFLAT_LISTS)`. The operator class is
  `VECTOR_OPCLASS` = `halfvec_cosine_ops` (halfvec) or `vector_cosine_ops`.

`_ensure_vector_index()` reads the existing `idx_document_chunk_vector` definition from
`pg_indexes`. If an index exists with a **different** method than the configured one, it
**raises `RuntimeError`** rather than rebuilding — rebuilding a vector index is a
long/expensive maintenance operation, so it must be done deliberately by an operator
(drop + recreate). It only creates the index when none exists.

## 7. Vector Operations

- **`search(collection_name, vectors, filter=None, limit=10)`** — pads query vectors, builds
  a `VALUES (qid, q_vector)` table, and for each query runs a `LATERAL` subquery ordered by
  `DocumentChunk.vector.cosine_distance(q_vector)`, limited to `limit`. `filter` supports
  equality (`{"field": "value"}`) and `$in` (`{"field": {"$in": [...]}}`) against
  `vmetadata` (decrypted first when pgcrypto is on). Results are grouped per `qid`. Raw
  pgvector cosine distance is **normalized to a [0,1] score** via `(2.0 - distance) / 2.0`.
  The transaction is rolled back at the end (read-only); returns empty per-query lists when
  nothing matches, or `None` on error.
- **`insert` / `upsert`** — both `adjust_vector_length` each item.
  - *Encrypted path*: raw SQL with `pgp_sym_encrypt(:text, :key)` / `pgp_sym_encrypt(:metadata_text, :key)`;
    `text` and `json.dumps(metadata)` are passed through **`sanitize_text_for_db`** first.
    `insert` uses `ON CONFLICT (id) DO NOTHING`; `upsert` uses `ON CONFLICT (id) DO UPDATE`.
  - *Plain path*: `insert` builds `DocumentChunk` rows and `bulk_save_objects`; `upsert`
    queries by id then updates or adds. Metadata goes through **`process_metadata`** (not
    stored raw).
- **`query` / `get`** — metadata-filtered / full-collection reads; both decrypt under
  pgcrypto and roll back (read-only). `get` accepts an optional `limit`.
- **`delete(collection_name, ids=None, filter=None)`**, **`reset()`** (deletes all rows),
  **`has_collection`**, **`delete_collection`** (delegates to `delete`), **`close()`** (no-op).

## 8. Encryption (pgcrypto)

When `PGVECTOR_PGCRYPTO=true` (requires `PGVECTOR_PGCRYPTO_KEY`):

- `text`/`vmetadata` are `LargeBinary` (BYTEA) holding `pgp_sym_encrypt(...)` ciphertext.
- Helpers: `pgcrypto_encrypt(val, key) = func.pgp_sym_encrypt(val, literal(key))` and
  `pgcrypto_decrypt(col, key, outtype='text') = func.cast(func.pgp_sym_decrypt(col, literal(key)), outtype)`.
- Reads/filters decrypt inline (e.g. `pgcrypto_decrypt(DocumentChunk.vmetadata, KEY, JSONB)[key].astext`),
  so metadata filtering still works on encrypted columns at the cost of per-row decryption.

## 9. Environment Variables (`config.py`)

Defaults are the `config.py` fallbacks **at time of writing**; the symbols are the source of
truth. (The original doc's "Performance Configuration" listed example values like
`PGVECTOR_POOL_SIZE = 10` as if they were defaults — they are not.)

| Variable | Default | Purpose |
|---|---|---|
| `PGVECTOR_DB_URL` | `DATABASE_URL` | pgvector connection URL; falsy ⇒ reuse the app `ScopedSession` |
| `PGVECTOR_INITIALIZE_MAX_VECTOR_LENGTH` | `1536` | Vector dimension (`VECTOR_LENGTH`) |
| `PGVECTOR_USE_HALFVEC` | `false` | Use `halfvec` column + (default) HNSW; required for dims > 2000 (a warning is logged otherwise) |
| `PGVECTOR_INDEX_METHOD` | `""` (auto) | Force `ivfflat` or `hnsw`; empty ⇒ derive from `USE_HALFVEC` |
| `PGVECTOR_IVFFLAT_LISTS` | `100` | IVFFLAT `lists` |
| `PGVECTOR_HNSW_M` | `16` | HNSW `m` |
| `PGVECTOR_HNSW_EF_CONSTRUCTION` | `64` | HNSW `ef_construction` |
| `PGVECTOR_CREATE_EXTENSION` | `true` | Run the guarded `CREATE EXTENSION` blocks |
| `PGVECTOR_PGCRYPTO` | `false` | Encrypt `text`/`vmetadata` with pgcrypto |
| `PGVECTOR_PGCRYPTO_KEY` | `None` | Symmetric key; **required** when pgcrypto is on |
| `PGVECTOR_POOL_SIZE` | `None` | Pool size (int); `None` ⇒ SQLAlchemy default; `>0` ⇒ `QueuePool`; `0` ⇒ `NullPool` |
| `PGVECTOR_POOL_MAX_OVERFLOW` | `0` | Overflow connections |
| `PGVECTOR_POOL_TIMEOUT` | `30` | Pool checkout timeout (s) |
| `PGVECTOR_POOL_RECYCLE` | `3600` | Connection recycle (s) |

Pool selection mirrors the main engine: only when a dedicated `PGVECTOR_DB_URL` engine is
built — `QueuePool` for `PGVECTOR_POOL_SIZE > 0`, `NullPool` for `== 0`, library default
when unset; always `pool_pre_ping=True`.

---

## Verification Recipe

Run from the repo root. Symbol resolution for manual `git log -L` uses the overrides in
`docs/DOCUMENTATION_STANDARD.md`.

```bash
# Abstract interface: search now takes a filter arg
grep -rn "class VectorDBBase\|def search(" backend/open_webui/retrieval/vector/main.py
grep -rn "filter: Optional\[Dict\] = None" backend/open_webui/retrieval/vector/main.py

# Dynamic vector column type (halfvec/vector) + opclass
grep -rn "VECTOR_TYPE_FACTORY\|VECTOR_OPCLASS\|HALFVEC if USE_HALFVEC" backend/open_webui/retrieval/vector/dbs/pgvector.py

# Index method selection + no-auto-rebuild guard (IVFFLAT and HNSW)
grep -rn "def _vector_index_configuration\|def _ensure_vector_index\|'hnsw'\|'ivfflat'\|Automatic rebuild is disabled" backend/open_webui/retrieval/vector/dbs/pgvector.py

# Guarded, permission-safe extension creation
grep -rn "PGVECTOR_CREATE_EXTENSION\|pg_extension WHERE extname" backend/open_webui/retrieval/vector/dbs/pgvector.py

# Shared session is ScopedSession; sanitize/process helpers
grep -rn "import ScopedSession\|sanitize_text_for_db\|process_metadata" backend/open_webui/retrieval/vector/dbs/pgvector.py
grep -rn "def process_metadata" backend/open_webui/retrieval/vector/utils.py
grep -rn "def sanitize_text_for_db" backend/open_webui/utils/misc.py

# search filter ($in / equality) + distance normalization
grep -rn "\$in\|2.0 - row.distance" backend/open_webui/retrieval/vector/dbs/pgvector.py

# pgcrypto wrappers
grep -rn "def pgcrypto_encrypt\|def pgcrypto_decrypt\|pgp_sym_encrypt" backend/open_webui/retrieval/vector/dbs/pgvector.py

# Env vars + defaults
grep -rn "PGVECTOR_USE_HALFVEC\|PGVECTOR_INDEX_METHOD\|PGVECTOR_HNSW_M\|PGVECTOR_IVFFLAT_LISTS\|PGVECTOR_CREATE_EXTENSION" backend/open_webui/config.py
```
