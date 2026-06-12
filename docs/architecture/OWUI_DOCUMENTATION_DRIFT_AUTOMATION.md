---
# Design/wiring spec for the drift-automation tooling. Anchored to the tooling it specifies.
# The tools below are NOT YET BUILT/COMMITTED — this is a design, not validated tooling. The
# marker stays a placeholder until the tools exist and are validated (Standard III.6).
covers_files:
  - .gitattributes
  - tools/check_doc_staleness.sh
  - tools/doc_reverse_index.sh
  - tools/doc_coverage_gap.sh
covers_symbols:
  - { symbol: check_doc_staleness, file: tools/check_doc_staleness.sh }
verified_against_commit: <PLACEHOLDER — tooling unbuilt; fill once tools exist and are validated>
---

# Documentation Drift Automation

> **Status:** design + wiring spec, **not** validated tooling. It depends on, and extends,
> `DOCUMENTATION_STANDARD.md` Part II/III. The reference `check_doc_staleness.sh` is drafted in the
> standard but not yet committed or validated against this tree (Standard III.6); the helpers here are
> specified, not yet written. Build order and blockers are at the end.

## Purpose

The standard's `verified_against_commit` markers are *passive*: they tell the truth only when someone
runs the check. This spec makes drift detection *active* and scopes it to this repository's actual drift
source. The governing fact (Standard III.2): for an extended fork of a mature upstream, **the dominant
drift event is the upstream merge, not your own edits.** Everything below optimizes for that.

Design constraints carried from the standard:
- Symbol-granular, never file-granular (11.2).
- Divergent markers are healthy; never enforce a shared SHA (11.4).
- The check proves *no covered symbol moved*, not *the right symbols are covered* (III.3) — hence the
  coverage-gap advisory.
- Tooling is pinned to `python-yq` and the extended funcname drivers (III.1).

## 1. The reverse index (doc ↔ source)

Every anchored doc declares `covers_files` / `covers_symbols`. Aggregating those front-matter blocks
yields the inverse map — **"if this symbol/file changes, these docs cover it"** — which turns a source
diff into a list of docs to check.

Specified as `tools/doc_reverse_index.sh` (design):

```
for each docs/**/*.md with front matter:
    read covers_symbols[] -> emit lines:  <file>\t<symbol>\t<doc>
sort/group by <file> (and by <symbol>) -> reverse_index.tsv
```

Output is a generated artifact (not hand-maintained — it would drift). It is the input to the edit-triggered
check (§2) and a quick "which docs own this file?" lookup for agents.

## 2. Edit-triggered check (your own PRs)

On any pull request whose diff touches `backend/` or `src/`:

1. Run `tools/check_doc_staleness.sh` (the standard's symbol-granular check).
2. For any STALE doc, use the reverse index to attribute it to the changed symbol(s) and post a PR comment:
   *"`<symbol>` in `<file>` changed; re-audit `<doc>` and advance its marker as the output of that re-read
   (Standard 11.3) — do not bump-to-green."*

This is advisory-with-teeth: it doesn't auto-bump anything (auto-bump is the exact dishonest move 11.3
forbids); it names the docs a human/agent must reconcile.

## 3. Upstream-merge trigger (the primary one)

On every merge of upstream into the fork:

1. Run `tools/check_doc_staleness.sh` against the post-merge HEAD.
2. The resulting STALE list **is** that merge's documentation-reconciliation worklist.
3. Reconcile each STALE doc (re-read → fix prose + `covers_symbols` together, or record the 11.3
   affirmation), then advance its marker.

Rationale (Standard III.2): `git log -L` can behave unreliably across the large merge/squash/rebase commits
upstream merges produce, so the merge is treated as an explicit re-audit checkpoint rather than something
`-L` is trusted to carry correctness across.

## 4. Changelog-grep targeting (cheap prioritization)

Upstream ships release notes. You can't parse them reliably, but you can intersect them with what you
document:

```
symbols = union of covers_symbols across all docs        # you already have this from §1
grep -F -f <(symbols) <upstream changelog / release notes>
-> any covered symbol named by upstream = HIGH-priority re-read this merge
```

This focuses the §3 worklist: covered symbols upstream explicitly touched get read first. Low effort,
targeted, and it degrades gracefully (a miss just means normal priority).

## 5. Coverage-gap advisory (mitigates III.3, never a gate)

The marker system cannot detect *under-coverage* — a new symbol in a covered file that no doc describes.
`tools/doc_coverage_gap.sh` (design) provides a cheap advisory:

```
for each file appearing in any covers_files:
    current_symbols = top-level symbols via the extended xfuncname driver   # reuse III.1 driver
    documented_symbols = symbols any doc covers in that file (from §1)
    report current_symbols - documented_symbols   # present in code, in no doc
```

Output is an **advisory report, not a CI gate** — not every symbol warrants documentation, so gating here
would just train people to suppress it. It surfaces candidates for new coverage after an upstream merge adds
surface area.

## 6. Timestamping (the one honest aggregate)

Per-doc "last updated" dates are banned (Directive 8). Maintain exactly **one** dated corpus-level fact —
in `FILE_TREE.md` or the index — of the form *"docs reconciled against upstream as of `<tag/date>`."* This is
the single source of truth for how current the whole corpus is relative to upstream, distinct from the
per-doc markers (Standard III.5).

## Build order & blockers

This spec is inert until the tooling exists. Dependency order (not time-boxed):

1. **Decide the docs directory layout** so the `docs/**/*.md` glob and cross-doc links are correct
   (Standard III.5). *Blocked on your decision: where do these docs physically live?*
2. **Commit + validate `check_doc_staleness.sh`** against the real Python **and** Svelte/TS tree; pin
   `python-yq`; commit `.gitattributes` with the extended drivers (Standard III.6). *Blocked on repo access.*
3. **Generate `doc_reverse_index.sh`** (pure aggregation over front matter — buildable as soon as the docs
   have anchor blocks, which they now do).
4. **Wire §2 (PR check) and §3 (merge check)** into CI / hooks.
5. **Add §4 (changelog grep) and §5 (coverage-gap advisory)** as the corpus stabilizes.

## Verification Recipe

```bash
# Once built, these are the artifacts this spec describes:
test -f tools/check_doc_staleness.sh && echo "staleness check present" || echo "MISSING (Standard III.6)"
test -f tools/doc_reverse_index.sh   && echo "reverse index present"   || echo "not yet built"
test -f tools/doc_coverage_gap.sh    && echo "coverage gap present"    || echo "not yet built"
grep -q "diff=python" .gitattributes && echo ".gitattributes maps python" || echo "MISSING driver mapping"
# Sanity: every doc that should be anchored actually has a marker
for d in docs/**/*.md; do head -20 "$d" | grep -q verified_against_commit || echo "no marker: $d"; done
```
