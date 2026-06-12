---
# Machine-readable anchor block — see Directive 8 / Directive 11.
covers_files:
  - backend/open_webui/utils/task.py
  - backend/open_webui/config.py
  - backend/open_webui/utils/misc.py
  - backend/open_webui/models/groups.py
covers_symbols:
  - { symbol: get_task_model_id, file: backend/open_webui/utils/task.py }
  - { symbol: prompt_template, file: backend/open_webui/utils/task.py }
  - { symbol: prompt_variables_template, file: backend/open_webui/utils/task.py }
  - { symbol: replace_prompt_variable, file: backend/open_webui/utils/task.py }
  - { symbol: replace_messages_variable, file: backend/open_webui/utils/task.py }
  - { symbol: truncate_content, file: backend/open_webui/utils/task.py }
  - { symbol: apply_content_filter, file: backend/open_webui/utils/task.py }
  - { symbol: rag_template, file: backend/open_webui/utils/task.py }
  - { symbol: title_generation_template, file: backend/open_webui/utils/task.py }
  - { symbol: autocomplete_generation_template, file: backend/open_webui/utils/task.py }
  - { symbol: moa_response_generation_template, file: backend/open_webui/utils/task.py }
  - { symbol: tools_function_calling_generation_template, file: backend/open_webui/utils/task.py }
verified_against_commit: 1afa71080b0a92655898aca3bc19789560dfbb64
---

# Task Template Processing System

`backend/open_webui/utils/task.py` builds the prompts behind Open WebUI's automated
"task" features — title generation, follow-ups, tags, query/RAG, autocomplete, image
prompts, emoji, MOA aggregation, and tool function-calling. It does variable substitution,
length-aware truncation, user/temporal context injection, and light prompt-injection
hardening.

> **What changed since the original guide (it was ~6+ months stale).** The biggest shifts:
> `prompt_template` is now **async** and expands a much larger user-variable set
> (`{{USER_EMAIL}}`, `{{USER_BIO}}`, `{{USER_GENDER}}`, `{{USER_BIRTH_DATE}}`,
> `{{USER_AGE}}`, `{{USER_GROUPS}}`), resolving groups from the DB on demand;
> `replace_messages_variable` gained **per-message content filters** (`{{MESSAGES|mode:n}}`)
> backed by new helpers `truncate_content`/`apply_content_filter`; `rag_template` is
> **async** and its placeholder-protection restores the **original literal** token (not the
> query value); and **every task generator is now `async`** and forwards the full `user`
> object. There is no `SRC_LOG_LEVELS` import.

---

## 1. Overview

The module turns templates (admin-configurable strings with `{{…}}` / `[…]` placeholders)
into final prompt text. Responsibilities:

- Variable substitution: temporal (`{{CURRENT_DATE}}`…), user (`{{USER_*}}`), prompt and
  message expansion, task-specific tokens.
- Length management: start/end/middle truncation of the prompt and of message history.
- Context-aware RAG assembly with prompt-injection hardening.
- Model routing for task execution (`get_task_model_id`).

All template functions are pure string transforms except `prompt_template` (and the
generators that call it), which are `async` because resolving `{{USER_GROUPS}}` may hit the
database.

## 2. Imports & Module Structure

Actual imports: `logging`, `math`, `re`, `uuid`, `datetime.datetime`,
`typing.{Any, Optional}`; from the app, `DEFAULT_RAG_TEMPLATE` (config) and
`get_last_user_message` / `get_messages_content` (`utils/misc.py`). `Groups` is imported
**lazily inside `prompt_template`** only when `{{USER_GROUPS}}` is present.

> Corrected: the original listed `from open_webui.env import SRC_LOG_LEVELS` — that import
> is gone; the module just uses `log = logging.getLogger(__name__)`.

## 3. Model Selection & Task Routing (`get_task_model_id`)

`get_task_model_id(default_model_id, task_model, task_model_external, models)` returns which
model should run a background task:

- Starts at `default_model_id`.
- If that model's `connection_type == "local"`, prefer the configured **local** `task_model`
  (when present in `models`); otherwise prefer the **external** `task_model_external`.
- Uses `models.get(task_model_id, {}).get("connection_type")` — a safe lookup (the original
  `models[task_model_id]` would `KeyError` on an unknown default).

## 4. Variable Substitution Engine

- **`prompt_variables_template(template, variables)`** — naive `str.replace` of each
  `variable → value` pair; used for caller-supplied substitutions.
- **`prompt_template(template, user=None)` — `async`.** Injects temporal context
  (`{{CURRENT_DATE}}`, `{{CURRENT_TIME}}`, `{{CURRENT_DATETIME}}`, `{{CURRENT_WEEKDAY}}`) and
  a full user block. From a `user` (pydantic → `model_dump()`, or dict) it derives:
  `name`, `email`, `location` (from `user["info"]`), `bio`, `gender`, `birth_date`, computed
  `age` (from `date_of_birth`), and `groups`. Each maps to a `{{USER_*}}` token, defaulting
  to `"Unknown"` (groups defaults to empty string).
  > **Lazy, conditional DB access (Directive 6).** `{{USER_GROUPS}}` is the one variable that
  > requires a query (`Groups.get_groups_by_member_id`), so the lookup runs **only when the
  > template actually contains `{{USER_GROUPS}}`** — and is wrapped in `try/except` so a
  > failure degrades to empty rather than breaking prompt generation. Don't hoist it.

## 5. Message Processing & Truncation

- **`replace_prompt_variable(template, prompt)`** — case-insensitive (`(?i)`) substitution of
  `{{prompt}}`, `{{prompt:start:N}}`, `{{prompt:end:N}}`, `{{prompt:middletruncate:N}}`.
  Middle truncation keeps `ceil(N/2)` from the start and `floor(N/2)` from the end joined by
  `...`.
- **`truncate_content(content, max_chars, mode="middletruncate")`** *(new)* — single-string
  truncation with modes `start` / `end` / `middletruncate`.
- **`apply_content_filter(messages, filter_str)`** *(new)* — applies a `mode:N` filter (e.g.
  `middletruncate:500`) to **each message's content**, handling both string content and the
  list-of-parts (`{type: "text", text: …}`) shape; returns a new list (originals not mutated).
- **`replace_messages_variable(template, messages=None)` — rewritten.** Now supports an
  optional per-message content filter via a `|mode:N` suffix:
  `{{MESSAGES}}`, `{{MESSAGES|mode:N}}`, `{{MESSAGES:START:N}}`, `{{MESSAGES:START:N|mode:N}}`,
  and the `END` / `MIDDLETRUNCATE` variants. It selects the message slice, optionally runs
  `apply_content_filter`, then formats once via `get_messages_content` (the original's 3-group
  regex and dual-format middle join are obsolete). `messages is None` → empty string.

## 6. RAG Template Assembly & Injection Hardening (`rag_template`)

`rag_template(template, context, query)` — **`async`**:

1. Empty template → `DEFAULT_RAG_TEMPLATE`; then `await prompt_template(template)`.
2. Warn (debug log) if neither `[context]` nor `{{CONTEXT}}` is present, and if the **context**
   itself contains `<context>…</context>` (a possible injection signal).
3. **Placeholder protection.** If the *context string* contains `[query]` or `{{QUERY}}`, the
   template's own `[query]`/`{{QUERY}}` placeholders are first swapped to a unique
   `{{QUERY<uuid>}}` token, recorded as `(uuid_token, original_literal)`.
4. Substitute `[context]`/`{{CONTEXT}}` → `context`, then `[query]`/`{{QUERY}}` → `query`.
5. Restore each protected token back to its **original literal** (`[query]` / `{{QUERY}}`).

> **Corrected semantics (Directive 4/6).** In the protected branch the restoration maps
> `uuid_token → original literal placeholder`, **not** `→ query value` as the original doc
> claimed. The effect: when the retrieved context echoes query-like tokens, the substitution
> step fills *those* (context-originated) tokens, while the template's genuine placeholders
> are returned to their literal form — keeping injected context from hijacking the query slot.

## 7. Task-Specific Generators

All of the following are **`async`** and finish by calling `await prompt_template(template, user)`,
forwarding the full `user` object (not `user_name`/`user_location` kwargs):

- `title_generation_template(template, messages, user=None)` — last user message → `{{prompt}}`,
  then `{{MESSAGES}}`.
- `follow_up_generation_template`, `tags_generation_template`, `image_prompt_generation_template`,
  `query_generation_template` — same prompt+messages shape.
- `emoji_generation_template(template, prompt, user=None)` — takes `prompt` directly (no messages).
- `autocomplete_generation_template(template, prompt, messages=None, type=None, user=None)` —
  also substitutes `{{TYPE}}`.

Two synchronous generators remain:

- `moa_response_generation_template(template, prompt, responses)` — replaces `{{prompt}}`
  (with the same start/end/middle truncation as `replace_prompt_variable`) and joins the
  `responses` (each wrapped in `"""…"""`) into `{{responses}}`.
- `tools_function_calling_generation_template(template, tools_specs)` — substitutes `{{TOOLS}}`.

## 8. Security Considerations

- **Injection hardening** — `rag_template`'s UUID placeholder swap (§6) isolates the
  template's real query/context slots from query-like tokens embedded in retrieved context;
  suspicious `<context>` tags in the context are logged.
- **Safe defaults** — missing user fields render as `"Unknown"` (groups → `""`); an empty RAG
  template falls back to `DEFAULT_RAG_TEMPLATE`; `messages is None` yields empty output.
- **Fail-soft DB access** — `{{USER_GROUPS}}` resolution and the age computation are wrapped in
  `try/except`, so template rendering never fails on a bad/missing user record.
- **No format-string execution** — all substitution is literal `str.replace` / `re.sub`; user
  text is never `eval`'d or used as a Python format string.

---

## Verification Recipe

Run from the repo root. Symbol resolution for manual `git log -L` uses the overrides in
`docs/DOCUMENTATION_STANDARD.md`.

```bash
# prompt_template is async with the expanded user vars + lazy groups
grep -rn "async def prompt_template" backend/open_webui/utils/task.py
grep -rn "{{USER_EMAIL}}\|{{USER_AGE}}\|{{USER_GROUPS}}\|get_groups_by_member_id" backend/open_webui/utils/task.py

# Message content filters + helpers
grep -rn "def truncate_content\|def apply_content_filter\|MESSAGES:MIDDLETRUNCATE\|MESSAGES(?:" backend/open_webui/utils/task.py

# rag_template async + restore-to-original-literal
grep -rn "async def rag_template\|query_placeholders.append((query_placeholder, " backend/open_webui/utils/task.py

# Generators are async and forward the user object
grep -rn "async def title_generation_template\|async def autocomplete_generation_template\|await prompt_template(template, user)" backend/open_webui/utils/task.py
grep -rn "def moa_response_generation_template\|def tools_function_calling_generation_template\|{{TOOLS}}\|{{TYPE}}" backend/open_webui/utils/task.py

# Safe model lookup; no SRC_LOG_LEVELS import
grep -rn "models.get(task_model_id, {})" backend/open_webui/utils/task.py
grep -rn "SRC_LOG_LEVELS" backend/open_webui/utils/task.py || echo "no SRC_LOG_LEVELS (expected)"
```
