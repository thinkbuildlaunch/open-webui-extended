---
# Machine-readable anchor block — see Directive 8 / Directive 11.
covers_files:
  - backend/open_webui/routers/chats.py
  - backend/open_webui/routers/files.py
  - backend/open_webui/routers/retrieval.py
  - backend/open_webui/routers/utils.py
  - backend/open_webui/utils/access_control/files.py
  - backend/open_webui/retrieval/vector/async_client.py
covers_symbols:
  - { symbol: create_new_chat, file: backend/open_webui/routers/chats.py }
  - { symbol: search_user_chats, file: backend/open_webui/routers/chats.py }
  - { symbol: update_chat_message_by_id, file: backend/open_webui/routers/chats.py }
  - { symbol: send_chat_message_event_by_id, file: backend/open_webui/routers/chats.py }
  - { symbol: upload_file_handler, file: backend/open_webui/routers/files.py }
  - { symbol: delete_file_by_id, file: backend/open_webui/routers/files.py }
  - { symbol: delete_all_files, file: backend/open_webui/routers/files.py }
  - { symbol: has_access_to_file, file: backend/open_webui/utils/access_control/files.py }
  - { symbol: save_docs_to_vector_db, file: backend/open_webui/routers/retrieval.py }
  - { symbol: get_ef, file: backend/open_webui/routers/retrieval.py }
  - { symbol: get_rf, file: backend/open_webui/routers/retrieval.py }
  - { symbol: search_web, file: backend/open_webui/routers/retrieval.py }
  - { symbol: process_web_search, file: backend/open_webui/routers/retrieval.py }
  - { symbol: process_files_batch, file: backend/open_webui/routers/retrieval.py }
  - { symbol: query_doc_handler, file: backend/open_webui/routers/retrieval.py }
  - { symbol: reset_vector_db, file: backend/open_webui/routers/retrieval.py }
  - { symbol: update_embedding_config, file: backend/open_webui/routers/retrieval.py }
  - { symbol: execute_code, file: backend/open_webui/routers/utils.py }
  - { symbol: download_chat_as_pdf, file: backend/open_webui/routers/utils.py }
  - { symbol: download_db, file: backend/open_webui/routers/utils.py }
verified_against_commit: 60f7eb84920d498a04adb771cc39eaa702837411
---

# Routers: chats, files, retrieval, utils

These four FastAPI routers form the REST surface for chats, file management, RAG/retrieval,
and small utilities. They share access control, real-time events, and the vector-DB layer.

> **What changed since the original guide (it was badly stale).**
> - **Async everywhere.** Handlers are `async def` and take `db: AsyncSession = Depends(get_async_session)`;
>   model calls are awaited (`await Chats.get_chat_by_id_and_user_id(...)`). The original's
>   sync `def upload_file` / `def process_file` / `Chats.insert_new_chat(...)` are obsolete.
> - **Async vector client.** Vector ops in the files/retrieval routers go through
>   **`ASYNC_VECTOR_DB_CLIENT`** (`retrieval/vector/async_client.py`, an async wrapper around
>   the sync `VECTOR_DB_CLIENT`), e.g. `await ASYNC_VECTOR_DB_CLIENT.delete(...)`.
> - **Access control via `AccessGrants`.** Chat/file sharing is checked with
>   `AccessGrants.has_access(...)`, and **`has_access_to_file` now lives in
>   `utils/access_control/files.py`**, not in `routers/files.py`.
> - **Moved utilities.** `execute_code_jupyter` is imported from `utils/code_interpreter.py`
>   and `PDFGenerator` from `utils/pdf_generator.py`; they are **not defined in** `routers/utils.py`.
> - **Many new endpoints** the original omitted: chat sharing & shared-access grants, usage/
>   export stats, pinning, clone, folders; file search, process-status, html/data-content,
>   rename; retrieval `config`/`config/update`, `process/text`, `process/youtube`, `process/web`.
> The endpoint inventory below is illustrative — confirm the live set with the recipe greps.

---

## 1. Chats Router (`routers/chats.py`)

CRUD + organization for chats. Representative endpoints (all `async`, most take a `db`):

- **Lifecycle**: `POST /new` (`create_new_chat`), `GET /{id}` (`get_chat_by_id`),
  `POST /{id}` (`update_chat_by_id`), `DELETE /{id}` (`delete_chat_by_id`),
  `POST /{id}/clone`, `POST /import`.
- **Messages & events**: `POST /{id}/messages/{message_id}` (`update_chat_message_by_id`)
  upserts a message and emits a `chat:message` event; `POST /{id}/messages/{message_id}/event`
  (`send_chat_message_event_by_id`) forwards an arbitrary `EventForm`.
- **Lists/search**: `GET /` & `GET /list`, `GET /search` (`search_user_chats`),
  `GET /folder/{folder_id}`, `GET /pinned`, `GET /archived`, `GET /all/db`
  (`get_all_user_chats_in_db`, admin + `ENABLE_ADMIN_EXPORT`).
- **Sharing** *(new)*: `POST /{id}/share`, `GET /share/{share_id}`, `DELETE /{id}/share`,
  `POST /shared/{id}/access/update`, `GET /shared/{id}/access` — backed by `AccessGrants`.
- **Stats** *(new)*: `GET /stats/usage`, `GET /stats/export`, `GET /stats/export/{chat_id}`.
- **Tags**: `GET/POST/DELETE /{id}/tags`, `POST /tags` (list by tag), `GET /all/tags`.
- **Pin/archive/folder**: `POST /{id}/pin`, `POST /{id}/archive`, `POST /{id}/folder`,
  `POST /archive/all`, `POST /unarchive/all`.

**Pagination** — list endpoints page in blocks of `limit = 60`.

**Access model** — owner-or-admin for mutation; read access also granted via
`AccessGrants.has_access(user_id, "chat", id, "read")` for shared chats. `search_user_chats`
keeps the old behavior of pruning an orphaned `tag:`-only search tag when it returns nothing.

## 2. Files Router (`routers/files.py`)

- **Upload** — `POST /` (`upload_file` → `upload_file_handler`). Validates the extension
  against `ALLOWED_FILE_EXTENSIONS` (unless `internal`), stores via the `Storage` abstraction
  with `OpenWebUI-*` object tags, inserts a `Files` row, and (when `process=True`) runs the
  content pipeline: STT transcription for `STT_SUPPORTED_CONTENT_TYPES`, else document
  extraction via `process_file` (skipping images/video unless the extraction engine is external).
- **Serving** — `GET /{id}` (metadata), `GET /{id}/content` and `GET /{id}/content/{file_name}`
  (bytes; RFC 5987 `filename*` encoding, inline for PDFs), `GET /{id}/content/html`,
  `GET /{id}/data/content` / `POST /{id}/data/content/update`, `GET /{id}/process/status`,
  `POST /{id}/rename`, `GET /search` *(all new vs. the original)*.
- **Deletion** — `DELETE /{id}` (`delete_file_by_id`) removes the DB row + `Storage` object,
  then **`await ASYNC_VECTOR_DB_CLIENT.delete(...)`** for both the per-file collection
  (`file-{id}`) and any owning knowledge collection (`filter={"file_id": id}` / `{"hash": …}`).
  `DELETE /all` (`delete_all_files`, admin) also calls `await ASYNC_VECTOR_DB_CLIENT.reset()`.

## 3. Access Control & Permissions

- **Roles**: `Depends(get_verified_user)` vs `Depends(get_admin_user)`; admin export gated by
  `ENABLE_ADMIN_EXPORT`; bulk deletes also check `has_permission(user.id, "chat.delete", …)`.
- **Resource sharing**: `AccessGrants.has_access(user_id, resource_type, resource_id, permission)`
  (e.g. `"chat"`/`"read"`). This replaced the original's owner/admin-only checks.
- **File access**: `has_access_to_file(file_id, access_type, user)` in
  **`utils/access_control/files.py`** (async) — resolves access through the file's owning
  knowledge base / grants, not a function in the files router.

## 4. Real-Time Events

`get_event_emitter(request_info, update_db=…)` is **async** (`await get_event_emitter(...)`)
and returns an emitter (or `None`). `update_chat_message_by_id` emits
`{"type": "chat:message", "data": {chat_id, message_id, content}}`; `send_chat_message_event_by_id`
forwards a client-supplied `EventForm{type, data}`. Emission is wrapped so a missing socket
degrades gracefully. See [websockets.md](./websockets.md).

## 5. Retrieval Router (`routers/retrieval.py`) — RAG pipeline

- **`save_docs_to_vector_db(request, docs, collection_name, metadata=None, overwrite=False, split=True, add=False, user=None)`**
  — optional SHA-256 hash dedup via `VECTOR_DB_CLIENT.query(filter={"hash": …})`; text
  splitting by `TEXT_SPLITTER` (`character`/`token`/`markdown_header`, the last preserving a
  `headings` list); batched embeddings via `get_embedding_function` (imported from
  `retrieval.utils`); then `VECTOR_DB_CLIENT.insert(...)`.
- **Embedding/reranking config** — `get_ef(...)` / `get_rf(...)` build the embedding and
  reranking models (CrossEncoder, ColBERT, or an external reranker). `update_embedding_config`
  (`POST /embedding/update`, admin) hot-swaps `app.state.ef` / `app.state.EMBEDDING_FUNCTION`
  at runtime; `GET/POST /config` manage the broader RAG config.
- **Web search** — `search_web(request, engine, query, user=None)` *(now async)* dispatches to
  the `search_*` providers in `retrieval/web/*` (SearXNG, Brave, Google PSE, DuckDuckGo, Kagi,
  Tavily, Exa, Firecrawl, external, …). `process_web_search` (`POST /process/web/search`) runs
  queries concurrently, dedupes URLs, then either returns snippets/docs directly (bypass flags)
  or saves them to a `web-search-{sha}` collection via `save_docs_to_vector_db`.
- **File/document processing** — `process_file` (`POST /process/file`) and `process_files_batch`
  (`POST /process/files/batch`) extract content (engine = `CONTENT_EXTRACTION_ENGINE`: Tika,
  Docling, Datalab, Document Intelligence, Mistral OCR, …), hash it, and store vectors under
  `file-{id}` or a target collection (unless `BYPASS_EMBEDDING_AND_RETRIEVAL`).
- **Query** — `query_doc_handler` (`POST /query/doc`) and `query_collection_handler`
  (`POST /query/collection`) run pure-vector or **hybrid (BM25 + vector + optional rerank)**
  search when `ENABLE_RAG_HYBRID_SEARCH`, parameterized by `TOP_K`, `TOP_K_RERANKER`,
  `RELEVANCE_THRESHOLD`, `HYBRID_BM25_WEIGHT`.
- **Admin/maintenance** — `reset_vector_db` (`POST /reset/db`: `VECTOR_DB_CLIENT.reset()` +
  `Knowledges.delete_all_knowledge()`), `delete_entries_from_collection` (`POST /delete`, by
  hash), `reset_upload_dir` (`POST /reset/uploads`).

## 6. Utils Router (`routers/utils.py`)

Small, focused endpoints (note the imported helpers, not local definitions):

- `POST /code/execute` (`execute_code`) — runs code only when `CODE_EXECUTION_ENGINE == "jupyter"`,
  delegating to **`execute_code_jupyter`** (from `utils/code_interpreter.py`); otherwise 400.
- `POST /code/format` (`format_code`, admin) — `black.format_str(...)`.
- `POST /pdf` (`download_chat_as_pdf`) — **`PDFGenerator(form_data).generate_chat_pdf()`**
  (from `utils/pdf_generator.py`).
- `GET /gravatar` (`get_gravatar`) — `get_gravatar_url` from `utils/misc`.
- `GET /db/download` (`download_db`, admin) — gated by `ENABLE_ADMIN_EXPORT`; lazily imports the
  sync `engine` and only serves the file when `engine.name == "sqlite"`.

> Corrected: the original placed `execute_code_jupyter` and `PDFGenerator` inside this router
> and listed markdown/LiteLLM-config endpoints that are not here.

## 7. Vector DB Integration (collection conventions)

- **Per-file** collection: `file-{file_id}` (created on processing, deleted with the file).
- **Knowledge base** collections: keyed by the knowledge id; files within filter by
  `{"file_id": …}`.
- **Web search**: `web-search-{sha256(queries)}` (truncated).
- The **files & retrieval routers await `ASYNC_VECTOR_DB_CLIENT`**; some module-level retrieval
  helpers still use the sync `VECTOR_DB_CLIENT` (e.g. inside `save_docs_to_vector_db`). See
  [vector-pgvector.md](./vector-pgvector.md) and [sqlalchemy.md](./sqlalchemy.md).

---

## Verification Recipe

Run from the repo root. Symbol resolution for manual `git log -L` uses the overrides in
`docs/DOCUMENTATION_STANDARD.md`.

```bash
# Async handlers + async session injection
grep -rn "async def create_new_chat\|async def upload_file\|async def process_file\|get_async_session" backend/open_webui/routers/chats.py backend/open_webui/routers/files.py backend/open_webui/routers/retrieval.py | head

# Async vector client used by files/retrieval routers
grep -rn "ASYNC_VECTOR_DB_CLIENT" backend/open_webui/routers/files.py
grep -rn "ASYNC_VECTOR_DB_CLIENT =" backend/open_webui/retrieval/vector/async_client.py

# Access control: AccessGrants + relocated has_access_to_file
grep -rn "AccessGrants.has_access" backend/open_webui/routers/chats.py
grep -rn "async def has_access_to_file" backend/open_webui/utils/access_control/files.py

# chat:message event
grep -rn "'type': 'chat:message'\|await get_event_emitter" backend/open_webui/routers/chats.py

# Retrieval core functions
grep -rn "def save_docs_to_vector_db\|def get_ef\|def get_rf\|async def search_web\|async def process_web_search\|async def process_files_batch\|def query_doc_handler\|async def reset_vector_db" backend/open_webui/routers/retrieval.py
grep -rn "from open_webui.retrieval.utils import\|get_embedding_function" backend/open_webui/routers/retrieval.py | head

# Utils router delegates to imported helpers (not local defs)
grep -rn "from open_webui.utils.code_interpreter import execute_code_jupyter\|from open_webui.utils.pdf_generator import PDFGenerator" backend/open_webui/routers/utils.py
grep -rn "def has_access_to_file\|class PDFGenerator\|def execute_code_jupyter" backend/open_webui/routers/utils.py || echo "not defined in utils router (expected)"
```
