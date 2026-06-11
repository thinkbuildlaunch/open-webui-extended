---
# Machine-readable anchor block — see Directive 8 / Directive 11.
covers_files:
  - backend/open_webui/utils/payload.py
  - backend/open_webui/utils/misc.py
  - backend/open_webui/utils/task.py
covers_symbols:
  - { symbol: apply_system_prompt_to_body, file: backend/open_webui/utils/payload.py }
  - { symbol: apply_model_params_to_body_openai, file: backend/open_webui/utils/payload.py }
  - { symbol: apply_model_params_to_body_ollama, file: backend/open_webui/utils/payload.py }
  - { symbol: remove_open_webui_params, file: backend/open_webui/utils/payload.py }
  - { symbol: convert_messages_openai_to_ollama, file: backend/open_webui/utils/payload.py }
  - { symbol: convert_payload_openai_to_ollama, file: backend/open_webui/utils/payload.py }
  - { symbol: convert_embedding_payload_openai_to_ollama, file: backend/open_webui/utils/payload.py }
  - { symbol: convert_embed_payload_openai_to_ollama, file: backend/open_webui/utils/payload.py }
verified_against_commit: e2fc46fd889d9736c7ba55747e6ba4176302d969
---

# Payload Transformation System (`utils/payload.py`)

`payload.py` adapts Open WebUI's internal OpenAI-shaped request bodies to each provider's
expectations: it injects the system prompt, casts/maps model parameters per provider
(OpenAI vs Ollama), strips Open WebUI-only params, and converts chat/embedding payloads
between OpenAI and Ollama formats.

> **What changed since the original guide.**
> - The system-prompt function was **renamed and made async**:
>   `apply_model_system_prompt_to_body(...)` → **`async def apply_system_prompt_to_body(system, form_data, metadata=None, user=None, replace=False)`**.
>   It now `await`s `prompt_template(system, user)` with the **full `user` object** (matching
>   the current `utils/task.py`; see [task-templates.md](./task-templates.md)) instead of
>   building `user_name`/`user_location` kwargs, and adds a `replace` mode.
> - There is a whole **Ollama parameter mapper** (`apply_model_params_to_body_ollama`) the
>   original omitted, plus a second embeddings converter (`convert_embed_payload_openai_to_ollama`).
> - `remove_open_webui_params` strips more keys; `convert_messages_openai_to_ollama` now
>   preserves a `thinking` field; and `convert_payload_openai_to_ollama` does far more than the
>   original's "... additional processing logic" placeholder.

---

## 1. Overview

All functions are pure-ish transforms on a `form_data`/payload dict (several are documented
as **in-place**). Responsibilities: system-prompt injection, parameter casting + provider
name mapping, Open WebUI param cleanup, and OpenAI⇄Ollama payload/message/embedding
conversion.

## 2. Imports & Dependencies

`copy`, `json`, `typing.{Callable, Optional}`; from `utils/misc`:
`add_or_update_system_message`, `deep_update`, **`replace_system_message_content`**; from
`utils/task`: `prompt_template`, `prompt_variables_template`.

> Corrected: the original's import list omitted `copy` and `replace_system_message_content`.

## 3. System Prompt Injection (`apply_system_prompt_to_body`)

`async def apply_system_prompt_to_body(system, form_data, metadata=None, user=None, replace=False)`:

1. No-op if `system` is empty.
2. If `metadata["variables"]` exist, expand them via `prompt_variables_template`.
3. `system = await prompt_template(system, user)` — temporal + full user-variable expansion
   (`{{USER_*}}`, `{{CURRENT_*}}`); resolving `{{USER_GROUPS}}` is why this is async.
4. Inject into `form_data["messages"]`: `replace_system_message_content` when `replace=True`,
   otherwise `add_or_update_system_message`.

> Corrected vs. original: it's `async`, renamed, has a `replace` flag, and passes the whole
> `user` to `prompt_template` (no `user_name`/`user_location` kwargs).

## 4. Parameter Mapping & Type Conversion

- **`apply_model_params_to_body(params, form_data, mappings)`** — for each non-`None`
  param, apply `mappings[key]` (a cast `Callable`) if present, else copy through. In-place.
- **`remove_open_webui_params(params)`** — strips Open WebUI-only keys before forwarding to a
  provider. The current set is **`stream_response`, `stream_delta_chunk_size`,
  `function_calling`, `reasoning_tags`, `system`** (the original listed only three).
- **`apply_model_params_to_body_openai(params, form_data)`** — `remove_open_webui_params`,
  then the custom-param merge (§5), then casts:
  `temperature/top_p/min_p`→`float`, `max_tokens`→`int`, `frequency_penalty/presence_penalty`→`float`,
  `reasoning_effort`→`str`, `seed`/`logit_bias`→identity,
  `stop`→unicode-unescaped list, `response_format`→`dict`.
- **`apply_model_params_to_body_ollama(params, form_data)`** *(not in the original)* —
  `remove_open_webui_params` + custom-param merge, then:
  - **Name remap**: `max_tokens` → `num_predict`.
  - **Root-lift**: `format`, `keep_alive`, `think` are pulled out to `form_data` top-level
    (with `format`/`keep_alive` JSON-parsed via a local `parse_json`).
  - Remaining params are cast with an **Ollama-specific** mapping (`mirostat*`, `num_ctx`,
    `num_batch`, `num_keep`, `num_predict`, `repeat_last_n`, `top_k`, `repeat_penalty`,
    `num_gpu`, `use_mmap`/`use_mlock`→`bool`, `num_thread`, …) and placed under
    **`form_data["options"]`** (Ollama doesn't take these at the body root).

## 5. Custom Parameter Handling

Both provider mappers `params.pop("custom_params", {})` and, for each string value, try
`json.loads` (keeping the original string on `JSONDecodeError`), then `deep_update(params,
custom_params)` so custom params merge over (and can override) the defaults before casting.

## 6. Message Conversion (`convert_messages_openai_to_ollama`)

Per message: copies `role`; **preserves a native `thinking` field if present** (reasoning
models / filter inlets — *new vs. the original*); then:

- **String content** (no tool calls) → `content` (plus `tool_call_id` if present).
- **Tool calls** → Ollama tool-call structs (`index`/`id`/`function.name`, `arguments`
  `json.loads`'d) with `content = ""`.
- **List content** → concatenates `text` parts into `content`, and collects `image_url`s into
  `images` (stripping `data:` base64 prefixes to the raw payload).

## 7. Chat Payload Conversion (`convert_payload_openai_to_ollama`)

Builds an Ollama chat payload from an OpenAI one (richer than the original's sketch):

- **Safe copy**: deep-copies everything except `metadata` (which may hold non-picklable
  objects), then re-attaches a shallow `dict(metadata)`.
- Maps `model`, `messages` (via §6), `stream`, and `tools`.
- Root `max_tokens` → `num_predict`.
- If `options` exist: **root-lifts** `format`/`keep_alive`/`think` (JSON-parsing the first
  two), remaps `options.max_tokens` → `options.num_predict`, and lifts `options.system` up to
  a top-level `system` (Ollama has no system option).
- Root `stop` → `options.stop`; forwards `metadata`.
- **`response_format`** → `format`: reads `response_format[type]` then its `.schema`
  (`{"type": "json_schema", "json_schema": {"schema": {...}}}` → `format`).

## 8. Embedding Payload Conversion

Two converters for the two Ollama embedding endpoints:

- **`convert_embedding_payload_openai_to_ollama`** (legacy `/api/embeddings`): sets `model`,
  normalizes `input` to a **list** and also provides a single `prompt` string (joined with
  `\n` for list input), and forwards optional `options`/`truncate`/`keep_alive`.
- **`convert_embed_payload_openai_to_ollama`** *(not in the original)*: targets the newer
  **`/api/embed`** endpoint, which takes `input` as a string **or** list natively (no `prompt`
  field), forwarding optional `truncate`/`options`/`keep_alive`.

---

## Verification Recipe

Run from the repo root. Symbol resolution for manual `git log -L` uses the overrides in
`docs/DOCUMENTATION_STANDARD.md`.

```bash
# System prompt: async, renamed, replace flag, full-user prompt_template
grep -rn "async def apply_system_prompt_to_body\|replace: bool = False\|await prompt_template(system, user)\|replace_system_message_content" backend/open_webui/utils/payload.py

# remove_open_webui_params strips the current key set
grep -rn "stream_delta_chunk_size\|reasoning_tags\|function_calling\|stream_response" backend/open_webui/utils/payload.py

# Ollama param mapper exists (root-lift + options)
grep -rn "def apply_model_params_to_body_ollama\|num_predict\|ollama_root_params\|form_data\['options'\]" backend/open_webui/utils/payload.py

# Message conversion keeps 'thinking'
grep -rn "def convert_messages_openai_to_ollama\|'thinking' in message" backend/open_webui/utils/payload.py

# Chat payload: deepcopy-except-metadata, root-lifts, response_format->format
grep -rn "def convert_payload_openai_to_ollama\|copy.deepcopy\|ollama_payload\['system'\]\|ollama_payload\['format'\]" backend/open_webui/utils/payload.py

# Both embedding converters
grep -rn "def convert_embedding_payload_openai_to_ollama\|def convert_embed_payload_openai_to_ollama" backend/open_webui/utils/payload.py

# OpenAI mapper casts
grep -rn "def apply_model_params_to_body_openai\|'response_format': dict\|unicode_escape" backend/open_webui/utils/payload.py
```
