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
   - **Test-only usage (`N > 0, N == M`)** → first check HOW consumers import
     the package: `import { ... } for "test"` in their `moon.pkg` means the
     package is a test kit by design — exempt it wholesale (e.g. a
     `testkit/`). Otherwise decide seam vs incident: a symbol many packages'
     tests lean on (a store seeder, a fixture constructor, a policy probe) is
     a deliberate test seam → `exports.mbt`, documented. A getter poked by
     one adjacent test is incidental → remove `pub` and move that test into
     the package (whitebox/inline). Test usage is never API justification by
     itself.
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
- **Struct fields**: don't bother marking fields `priv` on a plain `pub`
  struct — the 2026 toolchain flags the modifier as redundant there
  (deny-warn fails). Field-level shrink only matters for `pub(all)` structs,
  where external construction needs every labeled field; check construction
  sites before narrowing those.
- **Shrinking surfaces dead code beyond visibility.** Once a constructor goes
  package-private, `unused_default_value` and friends start firing — e.g. a
  parameter default that no caller ever exercised (an upstream wrapper owned
  the real default). Treat these warnings as findings: delete the dead
  default (make the parameter required), don't suppress the warning.
- **Analyzer notes are hints, not proofs.** `(all) or (open) can be removed`
  and usage counts can miss reflection-ish uses (derive output consumed as
  JSON keys, wire contracts). Compile + full tests after each package.
- **Dead packages**: a package whose every export is unused may itself be
  unimported — check `moon.pkg` importers; deleting the package beats
  shrinking it.
- **`pub impl` (trait impls, incl. derive-adjacent Show/ToJson/FromJson)**
  with zero external usage usually demote to plain `impl` — in-package and
  derive-chain uses don't need `pub`. Two exceptions: (a) round-trip impls on
  durable-record types are protocol surface — keep them (exports.mbt);
  (b) a trait impl whose trait OBJECT crosses the package boundary cannot
  demote — the consumer package invoking through `&Trait` needs the
  conformance public ("implementation of method X is private" is the
  compiler telling you this). Derive-generated impls have no block to edit;
  their visibility follows the type — skip them.
- **Enum variants and `pub(all)` struct fields** are not individually
  shrinkable — act on the analyzer's narrowability flag for the whole type,
  and skip per-variant/per-field rows unless the type is plain `pub`.

- **Make edit tooling fail on no-change.** A regex that silently matches
  nothing turns a whole category of edits into no-ops that still report
  success (this sweep's `pub(all)` narrowing was a no-op for three batches
  before the residual-stats check caught it). Count *changed* files/lines,
  not matched declarations — and re-run the analyzer at the end as an
  independent audit of what actually changed.

## Order of work

Pilot one leaf package end-to-end (smallest blast radius, validates the
test-conversion mechanics), then sweep families bottom-up (leaf packages
before the packages that import them), committing per family so review and
bisection stay tractable.
