---
# Machine-readable anchor block — see Directive 8 / Directive 11.
covers_files:
  - backend/open_webui/__init__.py
  - backend/open_webui/main.py
  - backend/open_webui/env.py
covers_symbols:
  - { symbol: app, file: backend/open_webui/__init__.py }
  - { symbol: KEY_FILE, file: backend/open_webui/__init__.py }
  - { symbol: version_callback, file: backend/open_webui/__init__.py }
  - { symbol: main, file: backend/open_webui/__init__.py }
  - { symbol: serve, file: backend/open_webui/__init__.py }
  - { symbol: dev, file: backend/open_webui/__init__.py }
verified_against_commit: f2a936ce4dc0eca4db997205a1f358f3a0282b9c
---

# CLI Entry Point (`open_webui/__init__.py`)

`backend/open_webui/__init__.py` is the `open-webui` Typer CLI. It bootstraps a few env vars,
generates/loads the secret key, optionally wires CUDA library paths, then launches the FastAPI
app via uvicorn (`open_webui.main:app`).

> **Merge candidate.** This is the process-launch layer in front of
> [main-entrypoint.md](./main-entrypoint.md) (which documents the `main.py` app it starts). The
> two form a natural "how the app starts" pair; this doc is small and could fold into that one.

> **What changed since the original guide.**
> - **`dev` does NOT do the env bootstrap.** Only `serve` sets `FROM_INIT_PY`, loads/creates the
>   secret key, and configures CUDA. `dev` just calls `uvicorn.run(..., reload=...)`. The
>   original implied both modes run the same setup/deferred-import path.
> - **The env setup runs inside `serve()`**, not at module import. There is no module-level
>   `os.environ["FROM_INIT_PY"] = "true"`.
> - **New: Windows event-loop handling.** `serve` passes `loop="none"` on Windows so
>   `asyncio.run` honors the `WindowsSelectorEventLoopPolicy` set in `db.py` (psycopg v3 async
>   is incompatible with the default `ProactorEventLoop`).
> - Imports use `from typing import Annotated` (not `typing_extensions`); there is no `Optional`.

---

## 1. Structure

A single `app = typer.Typer()` exposes three commands — `main`, `serve`, `dev` — and
`if __name__ == "__main__": app()`. Imports: `base64`, `os`, `random`, `sys`, `pathlib.Path`,
`typing.Annotated`, `typer`, `uvicorn`.

## 2. Commands

- **`main(--version)`** — the root command; `--version` triggers `version_callback`, which
  prints `Open WebUI version: {VERSION}` (imported lazily from `env`) and `raise typer.Exit()`.
- **`serve(host="0.0.0.0", port=8080)`** — production launch (see §3).
- **`dev(host="0.0.0.0", port=8080, reload=True)`** — development launch: `uvicorn.run("open_webui.main:app", reload=reload, forwarded_allow_ips="*")`.
  No secret-key/CUDA/`FROM_INIT_PY` setup.

## 3. `serve` — startup bootstrap

In order, inside the function:

1. `os.environ["FROM_INIT_PY"] = "true"` (signals package-launch to `env.py`).
2. **Secret key** — if `WEBUI_SECRET_KEY` is unset, load it from `KEY_FILE`
   (`Path.cwd() / ".webui_secret_key"`), generating it first when absent:
   `KEY_FILE.write_bytes(base64.b64encode(random.randbytes(12)))` (12 random bytes → base64).
   An explicit env var always takes precedence over the file.
3. **CUDA (optional)** — when `USE_CUDA_DOCKER == "true"`, append the torch/cuDNN paths to
   `LD_LIBRARY_PATH`, then probe `torch.cuda.is_available()`. On failure it logs, resets
   `USE_CUDA_DOCKER=false`, and **restores** the original `LD_LIBRARY_PATH`.
4. **Deferred import** — `import open_webui.main` and `from open_webui.env import UVICORN_WORKERS`
   happen *after* the above, so the env is configured before the app/config modules load.
5. **Launch** — `loop = "none" if sys.platform == "win32" else "auto"`, then
   `uvicorn.run("open_webui.main:app", host, port, forwarded_allow_ips="*", workers=UVICORN_WORKERS, loop=loop)`.

## 4. dev vs serve

| | `serve` | `dev` |
|---|---|---|
| Secret key / CUDA / `FROM_INIT_PY` | yes | **no** |
| Workers | `UVICORN_WORKERS` (env) | uvicorn default (1) |
| Reload | no | `reload=True` |
| Windows loop fix | yes (`loop="none"`) | no |
| App load | string `"open_webui.main:app"` (worker-safe) | same |

Both pass `forwarded_allow_ips="*"` (trusts proxy `X-Forwarded-*`). `UVICORN_WORKERS` is parsed
in `env.py` (see [env-configuration.md](./env-configuration.md)); the launched app's lifespan is
documented in [main-entrypoint.md](./main-entrypoint.md).

---

## Verification Recipe

Run from the repo root. Symbol resolution for manual `git log -L` uses the overrides in
`docs/DOCUMENTATION_STANDARD.md`.

```bash
# Commands + version callback
grep -rn "app = typer.Typer()\|def version_callback\|def serve(\|def dev(\|def main(" backend/open_webui/__init__.py

# serve-only bootstrap; dev has none of it
grep -rn "FROM_INIT_PY\|KEY_FILE = Path.cwd()\|random.randbytes(12)\|USE_CUDA_DOCKER" backend/open_webui/__init__.py
awk '/^def dev\(/,/^if __name__/' backend/open_webui/__init__.py | grep -c "FROM_INIT_PY\|WEBUI_SECRET_KEY\|USE_CUDA"   # expect 0

# Windows loop handling + workers + deferred import
grep -rn "loop = 'none' if sys.platform == 'win32'\|workers=UVICORN_WORKERS\|import open_webui.main" backend/open_webui/__init__.py

# Imports: typing.Annotated (not typing_extensions)
grep -rn "from typing import Annotated" backend/open_webui/__init__.py
grep -rn "typing_extensions" backend/open_webui/__init__.py || echo "no typing_extensions (expected)"
```
