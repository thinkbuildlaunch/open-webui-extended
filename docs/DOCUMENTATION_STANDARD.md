---
# This directive eats its own dog food — see Directive 8.
covers_files:
  - .gitattributes
  - tools/check_doc_staleness.sh
covers_symbols:
  - { symbol: check_doc_staleness, file: tools/check_doc_staleness.sh }
  - { symbol: PYFUNC_XFUNCNAME, file: tools/check_doc_staleness.sh }
  - { symbol: JSFUNC_XFUNCNAME, file: tools/check_doc_staleness.sh }
  - { file: .gitattributes, whole_file: true }
verified_against_commit: 375773fe4609235358e458237fa1d19fd7b4fee2
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

- **The diff driver MUST resolve every anchored symbol class (amended 11.2).**
  `.gitattributes` MUST map each covered language to a driver whose `xfuncname` recognizes
  *every* kind of symbol the docs anchor on — not merely the language's default function
  and class boundaries. A bare `*.py diff=python` is **prohibited** as the normative
  configuration: the stock Python funcname driver treats only `def`/`class` as boundaries,
  so for a covered constant `git log -L:SESSION_POOL_TIMEOUT:<file>` exits 128
  (unresolvable) and the check misreports a **false STALE** — the exact spurious alarm
  11.2 exists to eliminate. See clauses 11.6 and 11.9 below; this is also where the
  reproducibility obligation is discharged.
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
| Marker == HEAD (empty `<marker>..HEAD` range) | **Pass** — no commit lies in the range, so no covered symbol can have changed. The check skips the per-symbol `git log -L` (which exits 128 on an empty range and would otherwise misreport "not resolvable"). |
| Doc covers a whole file legitimately | `whole_file: true`; the check falls back to `git log <marker>..HEAD -- <file>` for that entry only. |

---

## Amendment to Directive 11

**Status:** prescriptive. Extends Directive 11. The amended bullet in 11.2 above replaces
the original diff-driver bullet; clauses 11.6–11.9 are new. The first application of the
directive surfaced two design gaps and one factual error in its own normative text; per
11.6 those findings are written back into the standard rather than left in the tooling.

### Reproducing resolution by hand (discharges amended 11.2)

The custom `xfuncname` overrides live in Git config, which is not version-controlled, so
`tools/check_doc_staleness.sh` supplies them at invocation via `git -c`. To reproduce
symbol resolution manually (so a maintainer running `git log -L` does not hit rc=128 and
wrongly conclude a doc is broken), prepend the **exact, empirically-validated** overrides
the tool uses:

```bash
# Python — def/class PLUS module-level NAME= / NAME: assignments (constants, env vars):
git -c diff.python.xfuncname='^[[:space:]]*(class|(async[[:space:]]+)?def)[[:space:]]|^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[:=]' \
    log -L:SESSION_POOL_TIMEOUT:backend/open_webui/socket/main.py

# TypeScript/JS/Svelte (`jsfunc`) — function/class decls + const/let/var bindings,
# INCLUDING type-annotated declarations (`const socketConnected: Writable<…> = …`):
git -c diff.jsfunc.xfuncname='^[[:space:]]*((export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?(function|class)[[:space:]]+[A-Za-z0-9_]+|(export[[:space:]]+)?(const|let|var)[[:space:]]+[A-Za-z0-9_]+)' \
    log -L:socketConnected:src/lib/stores/index.ts
```

These are the forms in `tools/check_doc_staleness.sh` (`PYFUNC_XFUNCNAME`, `JSFUNC_XFUNCNAME`).
Every config/command/regex shown in any doc MUST be a form validated to resolve the very
anchors the standard relies on — never the naive `*.py diff=python`, which cannot.

### 11.6 — Empirical findings about resolution MUST be propagated to the normative text

When testing or dog-fooding reveals that anchors resolve only under conditions the prose
does not state — a required driver extension, an invocation override, a naming constraint,
an environment dependency — that finding MUST be written into the normative prose, not
merely encoded in the tooling.

The reasoning is recursive: a marker vouches for prose↔code correspondence. If the prose
under-specifies what makes the anchors resolve, the marker asserts a correspondence that
does not hold for any reader who follows the prose alone — drift between the standard's
words and its behavior, the same failure mode the standard detects one level down.

Consequently:

- A resolution-affecting finding is not "done" when the script is fixed; it is done when
  the prose, the example, and the script agree.
- A 11.3 affirmation MUST NOT be issued for a doc while a known, resolution-affecting
  finding remains unpropagated to that doc's prose. Affirming prose "accurate" while
  knowing it under-specifies the tooling is a false affirmation — prohibited.
- The standard's own normative examples are held to the highest bar: every config,
  command, and regex shown MUST be copy-pasteable without silent prerequisites.

### 11.7 — Mutating `covers_symbols` is a reconciliation act

Editing `covers_symbols` — adding, swapping, or removing an anchor — is governed by 11.3,
not bookkeeping that leaves the marker untouched by default.

**Adding or swapping in an anchor.** Confirming that the anchor resolves (syntactic) and
is unchanged since the marker (what the check proves) is necessary but not sufficient. You
MUST additionally establish the semantic correspondence the marker will vouch for: read
the doc's prose and confirm it accurately describes that symbol's behavior or contract. A
freshly named anchor has never had this correspondence established at any marker; only a
read can establish it.

**Recording.** The commit that mutates `covers_symbols` MUST record, in its message, which
anchors were added/swapped/removed, and an affirmation that the prose↔symbol correspondence
was established for each added or swapped-in anchor.

**Marker handling.** The marker MUST advance to the mutating commit *unless both* hold, in
which case it MAY remain: (a) every added/swapped-in anchor is byte-identical between the
doc's current marker and the mutating commit, and (b) every retained anchor is likewise
unchanged across that span (the check proves this). When both hold the recorded affirmation
is still mandatory; "no code changed" justifies leaving the marker in place but does not
excuse skipping the correspondence check or its record.

**Removing an anchor.** Per Directive 3, first confirm from the repo root whether the symbol
still exists (merely no longer doc-relevant) versus was renamed/moved/deleted. A removal
that is a rename in disguise deletes the very signal the check would have raised.

### 11.8 — Prefer a qualified unambiguous anchor over abandonment

When a candidate anchor name collides — by substring or duplication — so that
`git log -L:name:file` is ambiguous, you MUST first attempt a qualified or more-specific
anchor that resolves unambiguously (a longer name, a class-qualified member, a distinct
nearby definition) before downgrading the entry to informational-only `covers_files`.

Downgrading to `covers_files` (which the check does not verify) is permitted ONLY when no
unambiguous anchor exists for the concept; it silently removes the symbol from staleness
detection, trading a false alarm for a blind spot. Before any downgrade you MUST confirm
the name genuinely collides against the actual tree: a name that merely *looks*
collision-prone but does not actually collide (e.g. `socketConnected`, which is unique even
though `socket` is a substring of it) MUST be anchored, not abandoned. Record why a
downgrade was unavoidable so the coverage loss is deliberate and visible.

### 11.9 — The standard applies to itself; "verbatim" is not a defense

The standard document and its tooling are themselves anchored docs subject to every clause
herein, including amended 11.2, 11.6, and 11.7. There is no privileged exemption for the
document that defines the rules.

Adopting the directive by saving its text "verbatim" satisfies nothing if the verbatim text
under-specifies the tooling that was actually built. The committed prose MUST match the
committed tooling's real requirements (11.6); the standard's anchor block, affirmations,
and examples are held to the literal-reproducibility bar without exception. A maintainer who
follows only the standard's prose MUST arrive at a working configuration — if they cannot,
the standard is stale against its own implementation and MUST be corrected before any of its
self-affirmations stand.

---

## Running the check

```bash
tools/check_doc_staleness.sh   # exit 0 = all docs current; non-zero = STALE/FAIL lines printed
```

It scans every `docs/**/*.md` with a `verified_against_commit` marker, validates the
marker's format and reachability, and runs the symbol-granular check above. Docs without a
marker are skipped. It deliberately does **not** compare markers across docs (11.4).
