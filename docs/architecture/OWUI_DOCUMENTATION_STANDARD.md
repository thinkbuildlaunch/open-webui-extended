---
# This standard is itself an anchored doc — it obeys its own Directive 8 and 11.9.
covers_files:
  - .gitattributes
  - tools/check_doc_staleness.sh
covers_symbols:
  - { symbol: check_doc_staleness, file: tools/check_doc_staleness.sh }
verified_against_commit: <PLACEHOLDER — fill at first in-repo reconciliation; see Part III.6>
---

# Documentation Standard — Effective, Verifiable Code Docs

**Status:** canonical and prescriptive. This is the single source for how architecture
and component docs in this repository are written, anchored, and kept honest. Part I
(Directives 1–10) governs *authoring*. Part II (Directive 11) governs the *verification
marker* that lets a doc prove it still matches the code. Part III adds repository-level
conventions and the known operational limits of the tooling. The parts are designed to
work together: Part I makes docs durable and greppable; Part II makes that durability
machine-checkable; Part III says what the machine check does **not** cover and how to run
it honestly against this repository in particular.

> **Adoption state.** This document is finalized in prose but is **not yet self-true**: its
> own anchor block carries a placeholder marker and `tools/check_doc_staleness.sh` has not
> yet been committed and validated against this repository's tree. Per Directive 11.9 the
> standard's self-affirmations do not stand until Part III.6 is complete. Treat it as
> authoritative for *authoring* immediately; treat its *verification* claims as pending.

## Purpose

These docs exist to be **read and acted on by AI coding agents and humans**, and to stay
true to the code with minimal upkeep. Two properties dominate every rule below:

1. **Durability** — a doc must not go stale the moment someone adds an import or reorders
   a file.
2. **Verifiability** — every claim should be checkable against the code, ideally by a
   command an agent can run.

The directives are ordered by how much trouble their absence causes, and are written
against real failure modes found while auditing this repository's docs: stale line
numbers, copied code that drifted from its original, a confidently-wrong concurrency
claim, a referenced test file that did not exist, and — once the verification marker was
introduced — a marker that vouched for a correspondence the prose did not fully hold.

---

# Part I — Authoring Directives

## A. Anchoring — how to point at code

### 1. Reference symbols, never line numbers.

Cite code by the name an agent can `grep` for: a function, class, constant, env var,
config key, or file path. A symbol survives edits and refactors; a line number is wrong
the instant anyone adds an import above it.

- ❌ `see socket/main.py lines 179-201`
- ✅ ``see `periodic_session_pool_cleanup()` in `socket/main.py` ``

If a line range is the only thing you can point at, that is a signal the code lacks a
named anchor — consider whether the thing being referenced should be extracted into a
named function or constant.

### 2. Cite the smallest stable anchor available.

Prefer the most specific *durable* identifier: a constant name over its value, a function
name over a pasted block, a file path over a directory. Use a bare file path only when the
whole file is the subject; otherwise name the symbol within it.

- ❌ `the cleanup runs every 120 seconds`
- ✅ ``the cleanup loop sleeps for `SESSION_POOL_TIMEOUT` between scans``

### 3. Deleting a reference requires proving absence, not just a failed lookup.

Before removing a citation because a symbol or path "doesn't exist," search from the repo
root with a broad pattern. Code moves and gets renamed far more often than it vanishes.
Repoint the reference if you can; delete only when absence is confirmed.

> A path miss (`test/util/test_redis.py` not found) is not proof the test is gone —
> `find . -name 'test_*redis*'` from the root is. Removing a real reference is more
> destructive than fixing a stale one.

## B. Content — what to actually write

### 4. Describe contracts and intent, not transcribed code.

Do not paste code blocks that duplicate the implementation. A copy rots independently of
the original — an audited heartbeat doc's sample had dropped the `await` the real handler
has. Describe the **behavior, the contract, the invariant, and the why**. When a snippet
is genuinely necessary, reduce it to the minimal shape (a signature, a key pattern) and
label it illustrative.

- ❌ A six-line copy of the heartbeat handler (which then loses an `await`).
- ✅ ``the handler awaits `Users.update_last_active_by_id()` directly — it is `async` and
  uses `AsyncSession`, *not* a sync call dispatched to a thread pool.``

This is where a doc earns its keep. The durable, high-value claims in any audit are of
this kind; copied code is pure liability.

### 5. Every number and default has exactly one source of truth.

Any magic value — timeout, threshold, interval, port — must name the symbol it comes from
and be marked as the value *at time of writing*. The symbol is the anchor; the number is a
convenience copy that may drift. (Aggregate counts across the codebase — number of
routers, models, migrations — are governed additionally by Part III.4.)

- ❌ `Compaction squashes the oldest half once there are 500 updates.`
- ✅ ``Compaction triggers at `YdocManager.COMPACTION_THRESHOLD` (500 at time of writing)
  and squashes the oldest half.``

### 6. Document deliberate-but-surprising code loudly.

When an implementation looks wrong but is intentional, state that it is intentional and
explain why — because the next reader, human or agent, will otherwise "fix" it into a bug.
This is the single most valuable thing a doc can contain.

> The `RedisDict` bulk set deliberately never `DELETE`s the hash; it does `HSET` of new
> values then `HDEL` of stale keys, specifically so concurrent readers never observe an
> empty dict. Without this note, an agent refactors it to "atomic `DELETE` + `HSET`" and
> reintroduces the race.

### 7. Model non-deterministic behavior as ranges and conditions, not single instants.

Where behavior is variable — scan-loop phase, retries, failover, ping/pong timing — state
the range and the triggering condition. A timing diagram showing one deterministic moment
for a variable process is misleading even when its arithmetic is correct.

- ❌ `The orphaned session is reaped at 240s.`
- ✅ ``Reap latency after the last heartbeat ranges from just over `SESSION_POOL_TIMEOUT`
  to roughly 2×, depending on loop phase — and only on the path where the Engine.IO
  disconnect never fired (e.g. the instance itself died). In the normal case the
  disconnect handler deletes the session first.``

## C. Verifiability — making docs self-auditing

### 8. Lead each doc with a machine-readable anchor block.

Open every doc that makes code claims with front matter listing the files and symbols it
covers and the commit it was last verified against (see the top of this file). This gives
an agent an immediate doc→code map and a real staleness signal — far more useful than a
"last updated" date, which says nothing about whether the content is still true. The
block's precise meaning and the rules for advancing its marker are defined in Directive 11.

> Navigation-only docs (an index, a glossary's front matter is still required because each
> entry makes a code claim) that genuinely make no falsifiable code claim may omit the
> code anchors, but MUST state in their header that they are link-verified, not
> symbol-verified, so the omission is deliberate and visible rather than an oversight.

### 9. Make every claim falsifiable.

Phrase factual statements so they can be checked against the code with a grep or a quick
read. Avoid mood-piece prose that cannot be confirmed or refuted. A doc built from checkable
assertions can be audited automatically; one built from vague description cannot.

- ❌ `Redis is used extensively for coordination.`
- ✅ ``Session reaping is gated by a `RedisLock` named `…:session_cleanup_lock`, so only one
  instance runs the loop.``

### 10. End each doc with a verification recipe.

Close the doc (or each major section) with the concrete commands that confirm it still
matches reality — the resolution check for each covered symbol, the existence check for each
covered path. For anchored docs this recipe is executed automatically by the Directive 11
tooling (`check_doc_staleness.sh`); the recipe in prose is the human-readable form of the
same checks, and the two must not disagree.

```bash
# Human-readable recipe for a heartbeat doc; the automated equivalent is check_doc_staleness.sh
grep -rn "def periodic_session_pool_cleanup" backend/open_webui/socket/main.py
grep -rn "SESSION_POOL_TIMEOUT" backend/open_webui/socket/main.py
grep -rn "async def update_last_active_by_id" backend/open_webui/models/users.py
```

If any line returns nothing, the doc is stale and must be re-audited before it is trusted.

---

# Part II — Directive 11: The Verification Marker

A verification marker has a failure mode a stale line number does not: it can *lie*. A line
number is observably wrong or right against the code. A marker that says "checked against
commit X" can record a claim that someone read the prose when no one did, and after the
fact a real re-audit and a mechanical string-replace are indistinguishable. The clauses
below remove every place that lie can hide, and extend the same correspondence discipline up
to the standard's own tooling and sideways to the set of covered symbols.

## 11.1 — Redefine what the marker means (so it cannot lie)

`verified_against_commit` MUST NOT be read as "a human attests they re-read this." It means
exactly this, and nothing softer:

> As of the named commit, no symbol in `covers_symbols` has changed, and the prose was last
> reconciled with those symbols at that commit.

The first clause is provable from git history with no trust required. The second is the only
clause that depends on a person, and 11.3 and 11.7 force it to leave evidence. The
consequence is that a passing check asserts a **real invariant** — *nothing the doc depends
on has moved* — rather than a claim about anyone's diligence.

A corollary retires an easy worry: because covered symbols live in code files, doc-only
commits never touch them, so the marker trailing the newest doc-only commit by one is
expected and inert.

## 11.2 — The staleness check MUST be symbol-granular, and the driver MUST resolve every anchor

File-granularity (`git diff <sha> HEAD -- <file>`) is **prohibited** as the staleness
mechanism. It flags every doc covering a file for any edit anywhere in it — including
functions the doc never names — and spurious alarms are what train people to bump the marker
to silence the check without reading. The check MUST fire only when a *covered symbol*
actually moved.

Requirements:

- **The diff driver MUST resolve every symbol class the docs anchor on**, not only a
  language's default function/class boundaries. The stock Git `diff=python` funcname driver
  recognizes only `def`/`class`, so for a covered constant `git log -L:SESSION_POOL_TIMEOUT:<file>`
  exits 128 and the check misreports the anchor as renamed/deleted — a *false STALE*, the very
  alarm this clause exists to prevent. A bare `*.py diff=python` is therefore prohibited as the
  normative configuration; the driver MUST be extended so top-level `NAME =` and annotated
  `NAME:` assignments are funcname lines too. Representative working form (validate against your
  own tree per 11.6 before trusting it):

  ```gitconfig
  [diff "python"]
      xfuncname = "^[[:space:]]*((async[[:space:]]+)?def|class)[[:space:]].*$|^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[:=].*$"
  ```

  A custom `xfuncname` lives in Git *config*, which is not version-controlled, so the working
  definition MUST be made reproducible — either supplied at invocation by the tooling
  (`git -c diff.<driver>.xfuncname=…`, the approach below) or installed via a repo-tracked
  config include. Whichever is chosen, the prose MUST state the exact override needed to
  reproduce resolution **by hand**, so a maintainer running `git log -L` manually does not hit
  rc=128 and wrongly conclude the doc is broken.
- **`.gitattributes` MUST map each covered language to such a driver**, e.g. `*.py diff=python`,
  `*.ts diff=jsfunc`, `*.svelte diff=jsfunc`. (See Part III.2 on the reduced reliability of the
  `.svelte`/`.ts` case.)
- **`covers_symbols` entries MUST be `{symbol, file}` pairs.** A bare file (no symbol) is
  permitted *only* when the entire file is the subject, and MUST be marked `whole_file: true`.
  Anyone tempted to omit the symbol should instead ask whether the code lacks a named anchor
  (Directive 1).
- **Symbol names MUST be unambiguous within their file** (see also 11.8). An ambiguous `-L`
  target is a defect in the doc, not a reason to fall back to line numbers.

The detection, per covered symbol, is `git log -L:symbol:file <marker>..HEAD`:

- non-empty → the symbol changed → **STALE**
- unresolvable at HEAD → renamed, moved, or deleted → **STALE** (Directive 3 applies: confirm
  which, from the repo root, before editing the reference)
- empty → unchanged → pass

A reference implementation — the same configuration its own prose prescribes (11.9). **Tooling
prerequisites are pinned in Part III.1; in particular the `yq` here is jq-syntax `python-yq`,
not the mikefarah/Go `yq`, whose expression language differs.**

```bash
#!/usr/bin/env bash
# check_doc_staleness: fail if any doc's covered symbols changed since its
# verified_against_commit, or if the marker no longer resolves.
# Deliberately does NOT compare markers across docs (see 11.4).
# Requires: git (>=2.22 for `log -L`), python-yq (jq-syntax; NOT mikefarah yq),
#           and the extended funcname drivers supplied below. See Part III.1.
set -euo pipefail

# Extended xfuncname drivers, supplied at invocation so manual repro matches the script.
# These are representative; validate against the tree per 11.6 (and Part III.2 for .svelte/.ts).
PY_XFUNCNAME='^[[:space:]]*((async[[:space:]]+)?def|class)[[:space:]].*$|^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[:=].*$'
JS_XFUNCNAME='^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?(function|class|const|let|var)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*'

git_l() {  # git log -L with both drivers overridden; the irrelevant one is harmless
  git -c diff.python.xfuncname="$PY_XFUNCNAME" \
      -c diff.jsfunc.xfuncname="$JS_XFUNCNAME" \
      log -L":$1:$2" "$3..HEAD" 2>/dev/null
}

fail=0
for doc in $(git ls-files 'docs/**/*.md'); do   # NOTE: glob assumes the docs/ layout — see Part III.5
  # Front matter must be extracted from the markdown before yq parses it.
  fm=$(awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f{print}' "$doc")
  sha=$(printf '%s\n' "$fm" | yq -r '.verified_against_commit // ""') || continue
  [ -z "$sha" ] && continue
  case "$sha" in '<'*) continue ;; esac   # skip explicit unfilled placeholders

  if ! git merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
    echo "FAIL  $doc: marker $sha is not an ancestor of HEAD (rebased away / wrong branch)"
    fail=1; continue
  fi

  # whole_file entries: file-level fallback, explicitly opted into.
  while IFS=$'\x1f' read -r file; do
    [ -z "$file" ] && continue
    if [ -n "$(git log "$sha..HEAD" --oneline -- "$file")" ]; then
      echo "STALE $doc: whole_file '$file' changed since $sha"; fail=1
    fi
  done < <(printf '%s\n' "$fm" | yq -r '.covers_symbols[] | select(.whole_file==true) | .file')

  # symbol entries: symbol-granular check.
  while IFS=$'\x1f' read -r symbol file; do
    [ -z "$symbol" ] && continue
    if ! git cat-file -e "HEAD:$file" 2>/dev/null; then
      echo "STALE $doc: covered file '$file' is gone at HEAD"; fail=1; continue
    fi
    if ! out=$(git_l "$symbol" "$file" "$sha"); then
      echo "STALE $doc: symbol '$symbol' not resolvable in '$file' (renamed/moved/deleted?)"; fail=1; continue
    fi
    if [ -n "$out" ]; then
      echo "STALE $doc: '$symbol' in '$file' changed since $sha"
      echo "$out" | grep -E '^commit ' | sed 's/^/        /'
      fail=1
    fi
  done < <(printf '%s\n' "$fm" | yq -r '.covers_symbols[] | select(.whole_file != true) | [.symbol, .file] | join("\u001f")')
done
exit "$fail"
```

> Note the `\x1f` (Unit Separator) field delimiter: a tab is IFS whitespace, which collapses
> the leading empty field of a `whole_file` entry and shifts every column. A non-whitespace
> separator preserves empty fields. This bug is invisible until a `whole_file` entry exists —
> which is exactly why the standard is dog-fooded against a doc that has one.

## 11.3 — Advancing the marker MUST be the output of a re-read

This is the only moment a person is trusted, so it is the only place the lie can survive 11.1.
It is fenced as follows.

The marker MAY advance only as the *conclusion* of re-reading the covered symbols at the new
commit. The commit that advances it MUST do one of exactly two things:

1. **Carry the resulting prose edits.** The marker bump and the corrected prose land together,
   in the same commit. The diff is its own evidence.
2. **If no prose edit was needed,** be a deliberate re-verification whose commit message records
   (a) which covered symbols changed since the prior marker and (b) an explicit affirmation that
   the prose was re-read and remains accurate.

Prohibited, without exception:

- **Silent bump** — advancing the marker in a commit that edits no prose and carries no
  affirmation under (2).
- **Bump-to-green** — advancing the marker to clear a failing check. The failing check is the
  signal to re-audit; the bump is what you earn afterward.
- **Batch bump** — advancing several docs' markers in one mechanical commit that did not
  re-audit each one independently.

The forbidden move, named precisely so an agent can recognize it in itself: *the check flagged a
covered symbol as changed, and you advanced the marker past that change without either editing
the prose or affirming under (2).* By the check's own logic a dependency moved, so silence is
never the honest answer there.

## 11.4 — Divergence is the healthy state; uniformity MUST NOT be enforced

CI MUST validate, per doc, the marker's **format** (a full 40-hex SHA) and **reachability** (an
ancestor of HEAD), and the **11.2 staleness check**.

CI MUST NOT assert that `verified_against_commit` is equal across docs. Docs are re-audited at
different times against different commits, so a healthy repository's markers *diverge*. An "all
docs share one SHA" invariant rewards synchronized bumping — the precise hollow move 11.3
forbids — and penalizes the independent verification we want. A one-off `sort -u` is fine as a
typo catch when you have just touched every doc in one session; it is not a health metric and
MUST NOT be promoted into one.

## 11.5 — Required edge-case handling

| Situation | Required behavior |
|-----------|-------------------|
| Covered symbol renamed | STALE → re-audit, fix prose **and** `covers_symbols`, then advance per 11.3 / 11.7. Confirm rename vs. deletion from the repo root first (Directive 3). |
| Covered symbol moved to another file | STALE → update the `file` field in `covers_symbols`, then advance per 11.3 / 11.7. |
| Symbol name ambiguous within its file | Defect in the doc — qualify or refactor the anchor (11.8). Never fall back to a line range. |
| Marker not an ancestor of HEAD | Hard **FAIL** (distinct from STALE) — meaningless until repointed at a reachable commit. |
| Doc covers a whole file legitimately | `whole_file: true`; the check falls back to `git log <marker>..HEAD -- <file>` for that entry only. |
| Constant/env-var anchor returns rc=128 | The funcname driver is not extended per 11.2 — fix the driver, do not abandon the anchor. |
| `.svelte` / `.ts` anchor will not resolve unambiguously | Expected; per Part III.2 prefer a qualified anchor, else `whole_file: true` for that component, and record why. Do not silently drop it. |
| Marker spans an upstream merge commit | Re-audit on the merge rather than trusting `-L` across it; see Part III.2. |

## 11.6 — Empirical findings about resolution MUST be propagated to the normative text

When testing or dog-fooding reveals that anchors resolve only under conditions the prose does
not state — a required driver extension, an invocation override, a naming constraint, an
environment dependency — that finding MUST be written into the normative prose, not merely
encoded in the tooling.

The reasoning is recursive and load-bearing: a marker vouches for prose↔code correspondence. If
the prose under-specifies what makes the anchors resolve, the marker asserts a correspondence
that does not hold for any reader who follows the prose alone. A fix that lives only in the
script is drift between the standard's words and its behavior — the same failure mode the
standard detects in ordinary docs, one level up.

Consequently:

- A resolution-affecting finding is not "done" when the script is fixed; it is done when the
  prose, the example, and the script agree.
- **A 11.3 affirmation MUST NOT be issued for a doc while a known, resolution-affecting finding
  remains unpropagated to that doc's prose.** Knowing the prose under-specifies the tooling and
  affirming it accurate anyway is a false affirmation.
- The standard's own examples are held to the highest bar: every config, command, and regex
  shown MUST be a form actually validated to resolve the anchors in the repo it ships with,
  copy-pasteable without silent prerequisites. (The `python-yq` pin in Part III.1 is one such
  propagation; the `.svelte`/`.ts` and merge-history caveats in Part III.2 are others.)

## 11.7 — Mutating `covers_symbols` is a reconciliation act

Editing `covers_symbols` — adding an anchor, swapping one for another, or removing one — is
itself a reconciliation act governed by 11.3, **not** bookkeeping that leaves the marker
untouched by default.

**Adding or swapping in an anchor.** Confirming that the anchor *resolves* (syntactic) and is
*unchanged since the marker* (what the check proves) is necessary but **not sufficient**. You
MUST additionally establish the semantic correspondence the marker will vouch for: read the
doc's prose and confirm it accurately describes that symbol's behavior or contract. A freshly
named anchor has never had this correspondence established at any marker; the script cannot
establish it; only a read can.

**Recording.** The commit that mutates `covers_symbols` MUST record, in its message, which
anchors were added, swapped, or removed, and an affirmation that prose↔symbol correspondence was
established for each added or swapped-in anchor — the same auditable trace 11.3 requires.

**Marker handling.** The marker MUST advance to the mutating commit **unless** every added or
swapped-in anchor is byte-identical between the doc's current marker and the mutating commit
**and** every retained anchor is likewise unchanged across that span (the check proves the
latter). When both hold, the content the marker vouches for is unchanged and the marker MAY
remain — but the recorded affirmation above is still mandatory. Otherwise the marker MUST
advance per 11.3.

**Removing an anchor.** Per Directive 3, first confirm from the repo root whether the symbol
still exists (and is merely no longer doc-relevant) versus was renamed, moved, or deleted. A
removal that is a rename in disguise deletes the very signal the check would have raised.

## 11.8 — Prefer a qualified unambiguous anchor over abandonment

When a candidate anchor name collides — by substring or duplication — so that `-L:name:file` is
ambiguous, you MUST first attempt a qualified or more-specific anchor that resolves
unambiguously (a longer name, a class-qualified member, a distinct nearby definition) before
downgrading the entry to informational-only `covers_files`.

Downgrading to `covers_files`, which the check does **not** verify, is permitted ONLY when no
unambiguous anchor exists for the concept. It is a last resort because it silently removes the
symbol from staleness detection — trading a false alarm for a blind spot.

Before any downgrade you MUST confirm the name is *genuinely* ambiguous against the actual tree.
A name that merely *looks* collision-prone but does not actually collide (e.g. `socketConnected`)
MUST be anchored, not abandoned. Record why any unavoidable downgrade was necessary.

## 11.9 — The standard applies to itself; "verbatim" is not a defense

The standard document and its tooling are themselves anchored docs subject to **every** clause
herein. There is no privileged exemption for the document that defines the rules.

Adopting the standard by saving its text "verbatim" satisfies nothing if the verbatim text
under-specifies the tooling that was actually built: the committed prose MUST match the committed
tooling's real requirements (11.6), and the standard's own anchor block, affirmations, and
examples are held to the literal-reproducibility bar without exception. A maintainer who follows
only the standard's prose MUST arrive at a working configuration — if they cannot, the standard
is stale against its own implementation and MUST be corrected before any of its self-affirmations
stand. **The Part III.6 adoption checklist is the concrete discharge of this clause for this
repository.**

---

# Part III — Repository conventions and operational limits

Part III is additive to Parts I–II and specific to *this* repository (a mature upstream project
consumed as an extended fork, with a Python backend and a Svelte/TypeScript frontend, and a
large body of upstream-maintained public documentation). It records the conventions that keep
the corpus honest at the repository level and the limits of the Part II machinery, so neither is
discovered the hard way.

## III.1 — Tooling prerequisites (pin these)

The reference `check_doc_staleness.sh` depends on a specific toolchain. Pin it explicitly; a
substitute with different semantics is a silent prerequisite of the kind 11.6 forbids.

- **`yq` = `python-yq` (the jq-based wrapper, kislyuk/yq).** The script's expressions
  (`yq -r '… // ""'`, `[.symbol, .file] | join("\u001f")`, `select(.whole_file==true)`) are jq
  syntax. The unrelated **mikefarah/Go `yq`** uses a different expression language and will fail
  cryptically. CI MUST install `python-yq`, and the prose here MUST say so.
- **`git` ≥ 2.22** for `log -L` line-log support.
- **`bash`** (the script uses process substitution and `IFS=$'\x1f'`).
- The **extended funcname drivers** in 11.2 MUST be present either by invocation (`git -c …`, as
  the script does) or a repo-tracked config include, and MUST be validated against this tree per
  11.6 before any marker is trusted.

## III.2 — Known-weak resolution cases

The Part II check is reliable for Python symbols and steady history. Two cases are weaker and
MUST be handled as stated, not trusted blindly.

- **Frontend `.svelte` / `.ts` anchors.** Several docs anchor frontend symbols
  (`setupSocket`, `injectCsp`, `SocketIOCollaborationProvider`, `getKatexRenderer`). Single-file
  Svelte components and TS arrow-function/const exports resolve under `git log -L:name:file` far
  less reliably than Python `def`/`class`/constant lines. For these, follow 11.8: prefer a
  qualified anchor; if none resolves unambiguously, set `whole_file: true` for that component and
  record why. Expect frontend docs to use `whole_file` more often than backend docs — that is a
  known coverage-precision tradeoff, not a defect to hide.
- **Markers that span an upstream merge.** This repository periodically merges upstream, producing
  large merge commits. `git log -L` across squashes, rebases, and rename-then-rename-back can
  produce false STALE or miss a change. Therefore the **upstream merge is itself the re-audit
  trigger** (see `DOCUMENTATION_DRIFT_AUTOMATION.md`): after merging upstream, run the check and
  treat its STALE list as that merge's reconciliation worklist, rather than relying on `-L` to
  silently carry correctness across the merge.

## III.3 — The marker proves no-drift, not coverage-completeness (stated residual)

A green check asserts that *nothing a doc covers has changed*. It does **not** assert that the
doc covers *everything it should*. A doc can remain permanently green while a newly added function
in a file it covers goes entirely undocumented, because the doc never claimed that symbol. 11.7
and 11.8 guard coverage at the edges of existing docs; nothing in Part II detects **under-coverage**
of newly added code. This is the standard's known residual, stated plainly per its own spirit. The
optional, advisory coverage-gap report in `DOCUMENTATION_DRIFT_AUTOMATION.md` (§"Coverage-gap
advisory") is the cheap partial mitigation; it is advisory, never a gate, because not every symbol
warrants doc coverage.

## III.4 — Aggregate counts live only in a dated FILE_TREE

Directive 5 binds each individual magic value to one symbol. Its corpus-level corollary: **aggregate
counts** — number of routers, models, migrations, providers, lines of code, token-tier sizes — are
volatile and MUST live only in a single dated `FILE_TREE.md`, never embedded in prose docs.
Aggregate counts in prose drift silently and cannot be symbol-anchored, so prose MUST refer to such
quantities qualitatively ("the feature routers," "the Alembic revision history") and cite `FILE_TREE`
for the number. This rule is what prevents the count-drift failure mode (a doc claiming one table
total while another claims a different one).

## III.5 — One corpus-level upstream-sync line; and the docs-location decision

- **Upstream-sync line.** Maintain exactly one dated fact — in `FILE_TREE.md` or the documentation
  index — of the form "docs reconciled against upstream as of `<tag/date>`." This is the honest form
  of timestamping: a single source of truth for how current the *whole corpus* is relative to
  upstream, distinct from and not a substitute for the per-doc `verified_against_commit` markers.
- **Docs location / glob.** The reference script globs `docs/**/*.md`. Whatever directory the
  anchored docs actually live in (an in-repo `docs/` tree, a separate docs repository, or a retrieval
  corpus) MUST be reflected in that glob and in cross-doc links. The directory layout is a
  prerequisite for the tooling and MUST be decided before CI wiring.

## III.6 — Adoption checklist (required before any self-affirmation; discharges 11.9)

Until every box is checked **in the repository**, this standard is stale against its own
implementation and none of its self-affirmations stand (11.9):

- [ ] Commit `tools/check_doc_staleness.sh`.
- [ ] Commit `.gitattributes` mapping `*.py`, `*.ts`, `*.svelte` to extended funcname drivers (11.2).
- [ ] Validate both `xfuncname` drivers against the **real** tree — Python constants/env-vars AND at
      least one `.svelte` and one `.ts` anchor — confirming each covered symbol resolves under
      `git log -L` by hand (11.6, III.2).
- [ ] Pin `python-yq` in CI and in any contributor setup docs (III.1).
- [ ] Fill `verified_against_commit` on this file and every anchored doc with a real, reachable SHA.
- [ ] Wire the check into CI and/or a pre-push hook (11.4), plus the upstream-merge trigger (III.2).

---

# Quick reference

| Do | Don't |
|----|-------|
| Cite `periodic_session_pool_cleanup()` | Cite `lines 179-201` |
| Name the constant, note its current value | Hard-code the number alone |
| Describe the contract (`async`, awaited) | Paste the implementation |
| Flag intentional-looking-wrong code + why | Leave it for someone to "fix" |
| State ranges + trigger conditions | Assert one deterministic instant |
| Prove absence before deleting a reference | Delete on a single failed lookup |
| Open with an anchor block, close with a recipe | Rely on a "last updated" date |
| Advance the marker as the output of a re-read | Silent-bump, bump-to-green, or batch-bump |
| Let markers diverge across docs | Enforce one shared SHA |
| Pin `python-yq`; extend the funcname driver | Ship bare `*.py diff=python`; assume any `yq` |
| Use `whole_file` for unresolvable `.svelte` anchors, and say why | Drop a frontend anchor silently |
| Re-audit on each upstream merge | Trust `-L` to carry correctness across a merge |
| Put aggregate counts only in dated `FILE_TREE` | Embed router/model/table counts in prose |
| Treat a `covers_symbols` edit as a reconciliation | Treat it as marker-neutral bookkeeping |

---

# Why the standard holds together

Part I makes a doc durable by anchoring it to identity rather than position, and verifiable by
insisting every claim be falsifiable. Part II makes that check real and honest: the marker's
*meaning* was narrowed to something git proves unaided (11.1); its *granularity* was matched to the
doc's own symbol anchors (11.2) so it fires only on real drift; the one irreducibly human moment was
forced to coincide with the prose edit or leave an auditable affirmation (11.3, 11.7); and
uniformity, the structural incentive to fake that moment, was banned (11.4). The remaining clauses
extend the same obligation **up one level** (11.6, 11.9) and **sideways** (11.7), with 11.8
preventing silent coverage loss at the edges.

Part III states what remains true after all of that: the check proves *no covered symbol moved*, not
*the right symbols are covered* (III.3); it is weakest exactly where this repository is most
exotic — frontend anchors and upstream merges (III.2); and it depends on a pinned toolchain and a
decided docs layout to run at all (III.1, III.5). These limits are written down for the same reason
every other rule exists: a documentation system earns trust by being honest about where it does not
reach. The only way to keep its markers honest is also the only way its own rules permit — including
when the document being verified is this one.
