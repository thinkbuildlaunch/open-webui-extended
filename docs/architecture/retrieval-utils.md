---
# Machine-readable anchor block — see Directive 8 / Directive 11.
covers_files:
  - backend/open_webui/retrieval/utils.py
  - backend/open_webui/retrieval/vector/async_client.py
  - backend/open_webui/utils/access_control/files.py
  - backend/open_webui/utils/headers.py
covers_symbols:
  - { symbol: VectorSearchRetriever, file: backend/open_webui/retrieval/utils.py }
  - { symbol: RerankCompressor, file: backend/open_webui/retrieval/utils.py }
  - { symbol: get_embedding_function, file: backend/open_webui/retrieval/utils.py }
  - { symbol: generate_embeddings, file: backend/open_webui/retrieval/utils.py }
  - { symbol: get_reranking_function, file: backend/open_webui/retrieval/utils.py }
  - { symbol: get_sources_from_items, file: backend/open_webui/retrieval/utils.py }
  - { symbol: filter_accessible_collections, file: backend/open_webui/retrieval/utils.py }
  - { symbol: query_collection_with_hybrid_search, file: backend/open_webui/retrieval/utils.py }
  - { symbol: query_doc_with_hybrid_search, file: backend/open_webui/retrieval/utils.py }
  - { symbol: merge_and_sort_query_results, file: backend/open_webui/retrieval/utils.py }
  - { symbol: get_enriched_texts, file: backend/open_webui/retrieval/utils.py }
  - { symbol: get_model_path, file: backend/open_webui/retrieval/utils.py }
verified_against_commit: 1cec43d3bcbc5ebed43d36e6e3499f7dbf9e02ea
---

# Retrieval & Knowledge Utilities (`retrieval/utils.py`)

This module is the RAG core: it gathers content from many item types, runs vector / BM25 /
hybrid search with optional neural reranking, generates embeddings across providers, and
enforces per-collection access control.

> **What changed since the original guide (it was heavily stale).**
> - **Async-first.** The real work moved to async methods/functions: `VectorSearchRetriever._aget_relevant_documents`
>   (the sync `_get_relevant_documents` now returns `[]`), `RerankCompressor.acompress_documents`,
>   `query_doc_with_hybrid_search`, `query_collection`, `query_collection_with_hybrid_search`,
>   `get_sources_from_items`, and `get_embedding_function` (returns an **async** function).
>   Runtime vector reads use **`ASYNC_VECTOR_DB_CLIENT`** (`retrieval/vector/async_client.py`).
> - **New collection access-control layer** (`filter_accessible_collections`) — the original
>   had nothing like it.
> - **Changed signatures**: `get_reranking_function(... reranking_batch_size=32)` returns a
>   `(query, documents, user=None)` callable; `get_embedding_function(... enable_async, concurrent_requests)`.
> - **Imports** differ: `langchain_classic.retrievers` (not `langchain.retrievers`),
>   `AccessGrants` + `has_access_to_file` (not a single `has_access`), `include_user_info_headers`;
>   there is **no** `pycrdt`/`Y` import.
> Code snippets below are illustrative contracts — confirm against the symbols via the recipe.

---

## 1. Imports & Infrastructure

LangChain retrieval primitives come from `langchain_classic.retrievers`
(`ContextualCompressionRetriever`, `EnsembleRetriever`) and `langchain_community`
(`BM25Retriever`). Vector access is split: the **async** `ASYNC_VECTOR_DB_CLIENT` for runtime
reads and the **sync** `VECTOR_DB_CLIENT` for a few blocking helpers (offloaded with
`asyncio.to_thread`). Access control pulls in `AccessGrants`, `has_access_to_file`
(`utils/access_control/files.py`), and `Knowledges.check_access_by_user_id`; user-info header
forwarding uses `include_user_info_headers` (`utils/headers.py`).

## 2. Custom Retrievers

- **`VectorSearchRetriever(BaseRetriever)`** — `collection_name`, `embedding_function`,
  `top_k`. The sync `_get_relevant_documents` is a no-op (`return []`); the live path is
  **`_aget_relevant_documents`**, which `await`s the embedding function and
  `ASYNC_VECTOR_DB_CLIENT.search(...)`, stamping each result's metadata with a
  `CHUNK_HASH_KEY` (SHA-256 of the chunk) for RRF dedup.
- **`query_doc(collection_name, query_embedding, k, user=None)`** — sync, single-collection
  `VECTOR_DB_CLIENT.search`. `get_doc` is the `.get(...)` analog.

## 3. Hybrid Search

- **`query_doc_with_hybrid_search(collection_name, collection_result, query, embedding_function, k, reranking_function, k_reranker, r, hybrid_bm25_weight, enable_enriched_texts=False)` — async.**
  Builds a `BM25Retriever` (optionally over **enriched** texts from `get_enriched_texts` —
  filename/title/headings/source/snippet appended to boost lexical recall) and a
  `VectorSearchRetriever`, combines them in an `EnsembleRetriever` weighted by
  `hybrid_bm25_weight` (0 → vector-only, ≥1 → BM25-only) with `id_key=CHUNK_HASH_KEY` so
  enriched BM25 text doesn't defeat reciprocal-rank-fusion dedup, wraps them in a
  `RerankCompressor` + `ContextualCompressionRetriever`, and `await`s `.ainvoke(query)`. Scores
  ride in `metadata["score"]`; results are cut to `min(k, k_reranker)`.
- **`query_collection(request, collection_names, queries, embedding_function, k)` — async.**
  When `request` is set and `ENABLE_RAG_HYBRID_SEARCH`, it tries
  `query_collection_with_hybrid_search` first and **falls back** to plain vector search on
  failure. The vector path embeds all queries once, fans `query_doc` out over a
  `ThreadPoolExecutor`, and merges via `merge_and_sort_query_results`. Empty/`None` queries are
  filtered out first.
- **`query_collection_with_hybrid_search(...)` — async.** Prefetches each collection's contents
  **concurrently** (`asyncio.gather` over `ASYNC_VECTOR_DB_CLIENT.get`), then runs every
  (collection × query) `query_doc_with_hybrid_search` in parallel; skips collections that failed
  to fetch; raises if all fail (so callers fall back).
- **`merge_and_sort_query_results(query_results, k)`** — SHA-256-hash dedups documents (keeping
  the better score), sorts by score desc, returns top-`k`. `merge_get_results` is the
  ids+docs+metadata concatenator used by `get_all_items_from_collections`.

## 4. Multi-Provider Embeddings

- **`get_embedding_function(embedding_engine, embedding_model, embedding_function, url, key, embedding_batch_size, azure_api_version=None, enable_async=True, concurrent_requests=0)`**
  returns an **async** callable `(query, prefix=None, user=None)`:
  - Engine `""` (local SentenceTransformers): runs `.encode(..., batch_size=…)` via
    `asyncio.to_thread` (CPU-bound). Raises if no local model is loaded.
  - Engines `ollama`/`openai`/`azure_openai`: batches list input by `embedding_batch_size` and,
    when `enable_async`, runs batches in parallel (`asyncio.gather`), optionally throttled by an
    `asyncio.Semaphore(concurrent_requests)` (0 = unlimited).
- **`generate_embeddings(engine, model, text, prefix=None, **kwargs)` — async dispatcher** to
  the per-provider async helpers. Each provider has a sync and an `a`-prefixed async batch
  function: `(a)generate_openai_batch_embeddings`, `(a)generate_azure_openai_batch_embeddings`
  (sync variant retries up to 5× on HTTP 429), `(a)generate_ollama_batch_embeddings` (Ollama
  `/api/embed`, `truncate: True`). All attach forwarded user headers via
  `include_user_info_headers` when `ENABLE_FORWARD_USER_INFO_HEADERS` and a `user` are set
  (the original inlined the `X-OpenWebUI-User-*` dict).
- `RAG_EMBEDDING_PREFIX_FIELD_NAME` controls whether the prefix is sent as a request field or
  string-prepended to the text.

## 5. Content Source Abstraction (`get_sources_from_items`)

`async def get_sources_from_items(request, items, queries, embedding_function, k, reranking_function, k_reranker, r, hybrid_bm25_weight, hybrid_search, full_context=False, user=None)`
walks heterogeneous `items` into a uniform `sources` list. Supported `type`s:

- `text` — raw content / temporary uploads (full or fallback to a `collection_name`).
- `note` — `await Notes.get_note_by_id`; access via admin / owner / `AccessGrants.has_access(..., "note", ..., "read")`.
- `chat` *(new)* — reconstructs the chat's message history (`get_message_list`) for owner/admin.
- `url` *(new)* — `get_content_from_url` (YouTube via `YoutubeLoader`, else web loader; binary
  bodies are downloaded and run through the configured `Loader`).
- `file` — full-content (owner / `has_access_to_file`) or chunked retrieval against `file-{id}`.
- `collection` — knowledge base: full-content (gather files) or chunked against the KB id;
  legacy KBs validate client-supplied `collection_names` against the KB's actual files.
- `docs` — pre-loaded web-search docs (bypass mode).
- bare `collection_name`/`collection_names` — only honored under `BYPASS_RETRIEVAL_ACCESS_CONTROL`.

Chunked retrieval calls `filter_accessible_collections` (§7) before searching, then
`query_collection`; full-context offloads `get_all_items_from_collections` via `asyncio.to_thread`.

## 6. Reranking (`RerankCompressor`, `get_reranking_function`)

- **`RerankCompressor(BaseDocumentCompressor)`** — `embedding_function`, `top_n`,
  `reranking_function`, `r_score`. `compress_documents` is a no-op (`return []`); the live path
  is **`acompress_documents`**: if a reranking function is set it scores via
  `await asyncio.to_thread(self.reranking_function, query, documents)`, else falls back to cosine
  similarity over query/document embeddings (`sentence_transformers.util.cos_sim`). It filters by
  `r_score`, sorts desc, keeps `top_n`, and writes each score into `metadata["score"]`.
- **`get_reranking_function(reranking_engine, reranking_model, reranking_function, reranking_batch_size=32)`**
  returns a `(query, documents, user=None)` callable that builds `(query, doc.page_content)` pairs
  and calls `reranking_function.predict(...)` — with `user=` for the `external` engine, else
  `batch_size=`. (The original's `lambda sentences, user=None: ...predict(sentences)` is obsolete.)

## 7. Access Control & Security

- **`filter_accessible_collections(collection_names, user, access_type="read")` — async** *(new).*
  Rejects names outside `[A-Za-z0-9_-]{1,255}` (`_is_safe_collection_name`) **before** the admin
  bypass; admins then pass. For non-admins: `knowledge-bases` (system meta) is denied; `file-*`
  → `has_access_to_file`; `user-memory-*` must equal the user's own; `web-search-*` (ephemeral)
  allowed; otherwise treated as a KB id and validated via `Knowledges.check_access_by_user_id`,
  with unknown names allowed only when `ENABLE_RETRIEVAL_UNSCOPED_COLLECTIONS` is set.
  > **Directive 6 — the unsafe-name rejection runs before the admin bypass on purpose**: a
  > malformed name must never reach the vector store (it could break out of a backend query
  > literal), even for an admin.
- **Item access** in `get_sources_from_items` uses `AccessGrants.has_access` (notes/knowledge),
  `has_access_to_file` (files), and owner/admin checks — not the original's
  `has_access(user.id, "read", x.access_control)`.
- **`get_model_path(model, update_model=False)`** resolves SentenceTransformer paths via
  `snapshot_download`, honoring `OFFLINE_MODE` / `local_files_only` and short-name →
  `sentence-transformers/<name>` expansion.

---

## Verification Recipe

Run from the repo root. Symbol resolution for manual `git log -L` uses the overrides in
`docs/DOCUMENTATION_STANDARD.md`.

```bash
# Async retrievers/compressor (real logic in the async methods)
grep -rn "async def _aget_relevant_documents\|async def acompress_documents\|ASYNC_VECTOR_DB_CLIENT" backend/open_webui/retrieval/utils.py

# Hybrid search: enriched texts + CHUNK_HASH_KEY RRF dedup, async invoke
grep -rn "def get_enriched_texts\|CHUNK_HASH_KEY\|id_key=CHUNK_HASH_KEY\|ainvoke(query)\|enable_enriched_texts" backend/open_webui/retrieval/utils.py

# Embedding factory is async with batching/concurrency; async dispatcher
grep -rn "def get_embedding_function\|enable_async\|concurrent_requests\|async def generate_embeddings\|/api/embed\|include_user_info_headers" backend/open_webui/retrieval/utils.py

# Reranking signature (query, documents, user)
grep -rn "def get_reranking_function\|reranking_batch_size\|doc.page_content) for doc in documents" backend/open_webui/retrieval/utils.py

# New collection access-control layer
grep -rn "def filter_accessible_collections\|_SAFE_COLLECTION_NAME_RE\|check_access_by_user_id\|ENABLE_RETRIEVAL_UNSCOPED_COLLECTIONS" backend/open_webui/retrieval/utils.py

# get_sources_from_items is async with new item types + AccessGrants
grep -rn "async def get_sources_from_items\|item.get('type') == 'chat'\|item.get('type') == 'url'\|AccessGrants.has_access" backend/open_webui/retrieval/utils.py

# langchain_classic import; no pycrdt
grep -rn "from langchain_classic.retrievers import" backend/open_webui/retrieval/utils.py
grep -rn "import pycrdt" backend/open_webui/retrieval/utils.py || echo "no pycrdt (expected)"
```
