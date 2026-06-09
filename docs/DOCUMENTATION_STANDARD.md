---
# This directive eats its own dog food — see Directive 8.
covers_files:
  - .gitattributes
  - tools/check_doc_staleness.sh
covers_symbols:
  - { symbol: check_doc_staleness, file: tools/check_doc_staleness.sh }
  - { file: .gitattributes, whole_file: true }
verified_against_commit: 226c29246a5429bdab6a62aa85ad6f7bd3f9598d
---

# Documentation Standard

Architecture and component docs in this repository carry a machine-readable anchor block
(Directive 8) and a verification recipe (Directive 10), and cite code by **symbol**, never
by line number (Directive 1). The directive below governs the verification marker itself.

The enforcement tool is [`tools/check_doc_staleness.sh`](../tools/check_doc_staleness.sh);
the language diff drivers it relies on are declared in [`.gitattributes`](../.gitattributes).

---

## Directive 11 — Verification Markers Are Earned, Not Asserted

**Status:** prescriptive. Supersedes the loose descriptions of `verified_against_commit`
in Directives 8 (anchor block) and 10 (verification recipe). Where this directive and
those conflict, this governs.

This exists because a verification marker has a failure mode that a stale line number
does not: it can *lie*. A line number is wrong or right against the code, observably.
A marker that says "checked against commit X" records a **claim that someone read the
prose**, and after the fact a real re-audit and a mechanical string-replace are
indistinguishable. The rules below remove every place that lie can hide.

### 11.1 — Redefine what the marker means (so it cannot lie)

`verified_against_commit` MUST NOT be read as "a human attests they re-read this." It
means exactly this, and nothing softer:

> As of the named commit, no symbol in `covers_symbols` has changed, and the prose was
> last reconciled with those symbols at that commit.

The first clause is provable from git history with no trust required. The second is the
only clause that depends on a person, and 11.3 forces it to leave evidence. The
consequence is that a passing check asserts a **real invariant** — *nothing the doc
depends on has moved* — rather than a claim about anyone's diligence.

A corollary retires an earlier worry: because covered symbols live in code files,
doc-only commits never touch them, so the marker trailing the newest doc-only commit by
one is expected and inert. Under this definition it is a non-event, not a limitation.

### 11.2 — The staleness check MUST be symbol-granular

File-granularity (`git diff <sha> HEAD -- <file>`) is **prohibited** as the staleness
mechanism. It flags every doc covering a file for any edit anywhere in it — including
functions the doc never names — and spurious alarms are what train people to bump the
marker to silence the check without reading. The check MUST fire only when a *covered
symbol* actually moved.

Requirements:

- **`.gitattributes` MUST declare a diff driver per language** so function-name anchors
  resolve reliably (`*.py diff=python`, `*.ts diff=jsfunc`, …). In this repo the custom
  `jsfunc` xfuncname (and an extended `python` xfuncname that also recognizes module-level
  `NAME =` / `NAME:` definitions, so constants and env vars are anchorable) are supplied by
  `tools/check_doc_staleness.sh` via `git -c diff.<driver>.xfuncname=…`.
- **`covers_symbols` entries MUST be `{symbol, file}` pairs.** A bare file (no symbol) is
  permitted *only* when the entire file is the subject, and MUST be marked
  `whole_file: true`. Anyone tempted to omit the symbol should instead ask whether the
  code lacks a named anchor (Directive 1).
- **Symbol names MUST be unambiguous within their file.** `git log -L:<name>:<file>`
  tracks the first funcname line matching `<name>` as a regex, so a name that is a
  substring of another definition in the same file (e.g. `connect` vs `disconnect`,
  `socket` vs `socketConnected`) is ambiguous. Qualify or refactor; never fall back to a
  line range.

Detection, per covered symbol, is `git log -L:symbol:file <marker>..HEAD`:

- non-empty → the symbol changed → **STALE**
- unresolvable at HEAD → renamed, moved, or deleted → **STALE** (Directive 3 applies:
  confirm which, from the repo root, before editing the reference)
- empty → unchanged → pass

Whole-file entries (`whole_file: true`) fall back to `git log <marker>..HEAD -- <file>`.

### 11.3 — Advancing the marker MUST be the output of a re-read

This is the only moment a person is trusted, so it is the only place the lie can survive
11.1. The marker MAY advance only as the *conclusion* of re-reading the covered symbols at
the new commit. The commit that advances it MUST do one of exactly two things:

1. **Carry the resulting prose edits** — the marker bump and the corrected prose land
   together, in the same commit. The diff is its own evidence.
2. **If no prose edit was needed,** be a deliberate re-verification whose commit message
   records (a) which covered symbols changed since the prior marker and (b) an explicit
   affirmation that the prose was re-read and remains accurate.

Prohibited, without exception:

- **Silent bump** — advancing the marker in a commit that edits no prose and carries no
  affirmation under (2).
- **Bump-to-green** — advancing the marker to clear a failing check. The failing check is
  the signal to re-audit; the bump is what you earn afterward.
- **Batch bump** — advancing several docs' markers in one mechanical commit that did not
  re-audit each one independently.

### 11.4 — Divergence is the healthy state; uniformity MUST NOT be enforced

CI MUST validate, per doc: the marker's **format** (a full 40-hex SHA) and **reachability**
(an ancestor of HEAD); and the **11.2 staleness check**.

CI MUST NOT assert that `verified_against_commit` is equal across docs. Docs are re-audited
at different times against different commits, so a healthy repository's markers *diverge*.
An "all docs share one SHA" invariant rewards synchronized bumping — the precise hollow
move 11.3 forbids. A one-off `sort -u` is fine as a typo catch when you have just touched
every doc in one session; it is not a health metric and MUST NOT be promoted into one.

### 11.5 — Required edge-case handling

| Situation | Required behavior |
|-----------|-------------------|
| Covered symbol renamed | STALE → re-audit, fix prose **and** `covers_symbols`, then advance per 11.3. Confirm rename vs. deletion from repo root first (Directive 3). |
| Covered symbol moved to another file | STALE → update the `file` field in `covers_symbols`, then advance per 11.3. |
| Symbol name ambiguous within its file | Defect in the doc — qualify or refactor the anchor. Never fall back to a line range. |
| Marker not an ancestor of HEAD | Hard **FAIL** (distinct from STALE) — the marker is meaningless until repointed at a reachable commit. |
| Doc covers a whole file legitimately | `whole_file: true`; the check falls back to `git log <marker>..HEAD -- <file>` for that entry only. |

---

## Running the check

```bash
tools/check_doc_staleness.sh   # exit 0 = all docs current; non-zero = STALE/FAIL lines printed
```

It scans every `docs/**/*.md` with a `verified_against_commit` marker, validates the
marker's format and reachability, and runs the symbol-granular check above. Docs without a
marker are skipped. It deliberately does **not** compare markers across docs (11.4).
