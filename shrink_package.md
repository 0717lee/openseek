# Shrinking a package's public interface (MoonBit)

A semantics-preserving sweep that makes each package export only what other
packages actually use. Repo-agnostic; drive it with `moon ide analyze`.

## Method

1. **Measure, don't guess.** `moon ide analyze <pkg>` prints every exported
   symbol (values, methods, struct fields, enum variants) with
   `usage: N (M in test)`. Real usage = `N − M`. It also flags `pub(all)` /
   `pub(open)` that can narrow to `pub`. Script the sweep: run it over every
   package first and rank packages by zero-real-usage count — fix the worst
   first.
2. **Classify each zero-real symbol** — the deny-warn gate forces exactly
   three outcomes:
   - **Test-only usage (`N > 0, N == M`)** → remove `pub`; move the blackbox
     tests that used it into the package (whitebox `_wbtest.mbt` or inline
     `test` blocks). Test usage is not API justification.
   - **No usage at all (`N == 0`), plausibly intentional** (documented
     tunables, one of a symmetric family, protocol surface) → keep `pub` but
     move the block to `exports.mbt` in that package. The file IS the
     convention: everything in it is exported on purpose despite no internal
     consumer.
   - **No usage at all, vestigial** → delete the block. (Making it `priv`
     instead just trades an over-export for an unused-symbol warning.)
3. **Verify per package, not per sweep**: `moon check --deny-warn`, run the
   package's tests, then `moon info` and check the `.mbti` diff shrank the way
   you intended. The `.mbti` diff is the review artifact.

## Traps

- **Cross-workspace consumers are invisible.** `moon ide analyze` only sees
  the current workspace. A package consumed by a sibling module (another
  `moon.work`, a JS app module, a desktop shell) shows zero usage here while
  being load-bearing there. Union usage from every workspace that imports it
  before shrinking — and put the symbols such a consumer needs in
  `exports.mbt` with a comment naming that consumer. `moon ide analyze`
  respects the convention, so they stop showing up as shrink candidates.
- **Published modules**: if the module is on a registry, everything `pub` is
  potentially someone's dependency. Get the owner's explicit OK that
  in-repo usage is the yardstick (here: yes).
- **Blackbox tests break at compile time** when their symbol goes priv —
  that's the signal, not a problem. Convert those tests rather than keeping
  the export.
- **Struct fields**: on a `pub` struct, a zero-real-usage field can go `priv`
  (external code loses only read access). But `pub(all)` structs constructed
  outside the package need every labeled field visible — check construction
  sites before touching fields.
- **Analyzer notes are hints, not proofs.** `(all) or (open) can be removed`
  and usage counts can miss reflection-ish uses (derive output consumed as
  JSON keys, wire contracts). Compile + full tests after each package.
- **Dead packages**: a package whose every export is unused may itself be
  unimported — check `moon.pkg` importers; deleting the package beats
  shrinking it.

## Order of work

Pilot one leaf package end-to-end (smallest blast radius, validates the
test-conversion mechanics), then sweep families bottom-up (leaf packages
before the packages that import them), committing per family so review and
bisection stay tractable.
