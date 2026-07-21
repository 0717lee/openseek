// `review_system_prompt()` — the read-only, compiler-grounded reviewer's
// system prompt — is generated from `review_system_prompt.mbt.md` by the
// `md_to_mbt_string` dev_build rule (see moon.pkg). Edit the markdown, not
// the generated `.mbt`.

///|
/// The review task: inspect the change set between `base` and HEAD.
fn review_task(base : String) -> String {
  (
    $|Review the code changes between \{base} and HEAD in the current repository.
    $|
    $|Steps:
    $|1. Run `git diff \{base}...HEAD` and `git diff --name-only \{base}...HEAD` to see the change set.
    $|2. Read the changed files and enough surrounding context to judge correctness.
    $|3. Run `moon check --target all` to confirm it compiles across targets; run `moon test` if feasible. Treat compiler/test output as ground truth.
    $|4. Call submit_review once with findings (file, line when known, severity, category, title, detail, optional suggestion), a summary, and stats (set build/tests from what moon check/test actually reported).
  )
}
