#!/usr/bin/env bash
#
# check_doc_staleness — fail if any doc's covered symbols changed since its
# `verified_against_commit`, or if that marker no longer resolves.
#
# Implements Directive 11 of the documentation standard
# (docs/DOCUMENTATION_STANDARD.md):
#   * 11.2 — symbol-granular detection via `git log -L:<symbol>:<file>`
#            (NEVER file-granular `git diff -- <file>`, except for entries
#            explicitly marked `whole_file: true`).
#   * 11.4 — validates each doc independently; deliberately does NOT compare
#            markers across docs. Uniformity is not a health metric.
#
# A doc opts in by carrying YAML front matter with `verified_against_commit`
# and `covers_symbols`. Docs without a marker are skipped.
#
# covers_symbols entry shapes:
#   - { symbol: foo, file: path/to/x.py }   # tracked with git log -L
#   - { file: path/to/x.cfg, whole_file: true }  # tracked with git log -- file
#
# Requires: git, yq (the jq-based YAML wrapper), and the diff drivers declared
# in .gitattributes. The custom `jsfunc` xfuncname is supplied below so TS/JS/
# Svelte anchors resolve without any clone-time git config.
set -euo pipefail

# xfuncname for the `jsfunc` driver (.gitattributes maps *.ts/.js/.svelte to it):
# matches function/class declarations and const/let/var bindings. The binding
# branch deliberately does NOT require a trailing `=`, so TypeScript
# declarations carrying a type annotation (`const socketConnected: Writable<…> =`)
# resolve as funcname lines too — without this, annotated exports exit 128.
JSFUNC_XFUNCNAME='^[[:space:]]*((export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?(function|class)[[:space:]]+[A-Za-z0-9_]+|(export[[:space:]]+)?(const|let|var)[[:space:]]+[A-Za-z0-9_]+)'

# Override the built-in `python` driver's xfuncname so that, in addition to
# `def`/`class`, a MODULE-LEVEL (column-0) `NAME =` or `NAME: type` assignment is
# a valid funcname anchor. This lets docs anchor module constants and env-var
# definitions (e.g. SESSION_POOL_TIMEOUT, WEBSOCKET_SERVER_PING_INTERVAL) with
# `git log -L`. The column-0 requirement keeps such anchors unambiguous: it
# excludes the indented re-use sites inside functions.
PYFUNC_XFUNCNAME='^[[:space:]]*(class|(async[[:space:]]+)?def)[[:space:]]|^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[:=]'

git_l() {
  git -c "diff.jsfunc.xfuncname=${JSFUNC_XFUNCNAME}" \
      -c "diff.python.xfuncname=${PYFUNC_XFUNCNAME}" "$@"
}

# Pull the YAML front matter (between the first pair of `---` lines) out of a
# markdown file so yq can parse it.
front_matter() { awk '/^---$/{c++; next} c==1' "$1"; }

check_doc_staleness() {
  local fail=0 doc fm sha symbol file whole

  while IFS= read -r doc; do
    fm="$(front_matter "$doc")"
    [ -z "$fm" ] && continue

    sha="$(printf '%s\n' "$fm" | yq -r '.verified_against_commit // ""' 2>/dev/null || true)"
    [ -z "$sha" ] || [ "$sha" = "null" ] && continue

    # 11.4: format (full 40-hex) + reachability (ancestor of HEAD) are hard FAILs.
    if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "FAIL  $doc: verified_against_commit '$sha' is not a full 40-hex SHA"
      fail=1; continue
    fi
    if ! git merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
      echo "FAIL  $doc: marker $sha is not an ancestor of HEAD (rebased away / wrong branch)"
      fail=1; continue
    fi

    # Empty range (marker == HEAD, e.g. a doc just re-verified to the tip):
    # no commit lies in <marker>..HEAD, so by definition no covered symbol can
    # have changed -> trivially current. Skip; `git log -L` over an empty range
    # exits 128 and would otherwise be misreported as "not resolvable".
    if [ -z "$(git rev-list "${sha}..HEAD" 2>/dev/null)" ]; then
      continue
    fi

    # Iterate covered symbols. Fields are joined with ASCII Unit Separator
    # (0x1F), NOT tab: tab is an IFS-whitespace char, so `read` would trim a
    # leading empty `symbol` field (whole_file entries have none) and shift the
    # columns. 0x1F is non-whitespace, so empty fields are preserved.
    while IFS=$'\037' read -r symbol file whole; do
      [ -z "$file" ] && continue
      if ! git cat-file -e "HEAD:$file" 2>/dev/null; then
        echo "STALE $doc: covered file '$file' is gone at HEAD"; fail=1; continue
      fi

      if [ "$whole" = "true" ]; then
        # 11.5: whole-file entries fall back to file-granular diff.
        if [ -n "$(git_l log --format='%H' "${sha}..HEAD" -- "$file" 2>/dev/null)" ]; then
          echo "STALE $doc: whole_file '$file' changed since $sha"
          git_l log --oneline "${sha}..HEAD" -- "$file" | sed 's/^/        /'
          fail=1
        fi
        continue
      fi

      if [ -z "$symbol" ]; then
        echo "FAIL  $doc: covers_symbols entry for '$file' has no symbol and is not whole_file:true"
        fail=1; continue
      fi

      if ! out="$(git_l log -L":${symbol}:${file}" "${sha}..HEAD" 2>/dev/null)"; then
        echo "STALE $doc: symbol '$symbol' not resolvable in '$file' (renamed/moved/deleted?)"
        fail=1; continue
      fi
      if [ -n "$out" ]; then
        echo "STALE $doc: '$symbol' in '$file' changed since $sha"
        printf '%s\n' "$out" | grep -E '^commit ' | sed 's/^/        /'
        fail=1
      fi
    done < <(printf '%s\n' "$fm" | yq -r '.covers_symbols[]? | [(.symbol // ""), (.file // ""), (.whole_file // false)] | map(tostring) | join("")' 2>/dev/null)

  done < <(git ls-files | grep -E '^docs/.*\.md$')

  return "$fail"
}

check_doc_staleness
