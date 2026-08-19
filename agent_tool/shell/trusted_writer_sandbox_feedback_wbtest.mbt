///|
test "sandbox explains downgraded Moon writer pipelines" {
  let parsed = @shell_parse.parse_for_policy(
    "moon info 2>&1 | grep -c 'Failed to copy'",
  )
  assert_eq(downgraded_trusted_source_writers(parsed), ["moon info"])
  let feedback = shell_sandbox_denial_feedback(
    parsed, "Operation not permitted",
  )
  assert_true(feedback.contains("whole shell request ran read-only"))
  assert_true(feedback.contains("Run each detected writer in its own"))
  assert_true(feedback.contains("  - `moon info`"))
  assert_true(feedback.contains("Use the original arguments"))
  assert_false(
    feedback.contains("make source changes with line-anchored `edit`"),
  )
}

///|
test "sandbox lists every distinct downgraded trusted writer" {
  let parsed = @shell_parse.parse_for_policy(
    "moon info; git checkout main; moon fmt; moon info | grep done",
  )
  assert_eq(downgraded_trusted_source_writers(parsed), [
    "moon info", "git checkout", "moon fmt",
  ])
  let feedback = shell_sandbox_denial_feedback(
    parsed, "Operation not permitted",
  )
  assert_true(
    feedback.contains("  - `moon info`\n  - `git checkout`\n  - `moon fmt`"),
  )
}

///|
test "sandbox recognizes Moon info copy denial in a complex command" {
  let parsed = @shell_parse.parse_for_policy(
    "moon info >/dev/null 2>&1; echo $?",
  )
  assert_true(parsed is TooComplex(_))
  let output = "ERROR Failed to copy generated mbti file from /repo/_build/wasm/debug/check/argparse/argparse.mbti to /repo/argparse/pkg.generated.mbti: Operation not permitted (os error 1)"
  let feedback = shell_sandbox_denial_feedback(parsed, output)
  assert_true(feedback.contains("  - `moon info`"))
  assert_true(feedback.contains("inspect the file in a second shell"))
}

///|
test "sandbox keeps generic feedback outside downgraded trusted writers" {
  let standalone = @shell_parse.parse_for_policy("moon info")
  assert_eq(downgraded_trusted_source_writers(standalone), [])
  assert_eq(
    shell_sandbox_denial_feedback(standalone, "Operation not permitted"),
    SandboxSourceWriteFeedback,
  )
  let copy_denial = "ERROR Failed to copy generated mbti file from /repo/_build/pkg.mbti to /repo/pkg.generated.mbti: Operation not permitted (os error 1)"
  assert_eq(
    shell_sandbox_denial_feedback(standalone, copy_denial),
    SandboxSourceWriteFeedback,
  )
  let trusted_chain = @shell_parse.parse_for_policy("moon info && git diff")
  assert_eq(downgraded_trusted_source_writers(trusted_chain), [])
  assert_eq(
    shell_sandbox_denial_feedback(trusted_chain, "Operation not permitted"),
    SandboxSourceWriteFeedback,
  )
  let standalone_git = @shell_parse.parse_for_policy("git checkout main")
  assert_eq(downgraded_trusted_source_writers(standalone_git), [])
  assert_eq(
    shell_sandbox_denial_feedback(standalone_git, "Operation not permitted"),
    SandboxSourceWriteFeedback,
  )
}

///|
test "sandbox requires the full Moon info copy-denial signature" {
  assert_false(
    output_has_moon_info_copy_denial(
      "Failed to copy generated mbti file: unrelated failure",
    ),
  )
  assert_false(
    output_has_moon_info_copy_denial(
      "pkg.generated.mbti: Operation not permitted",
    ),
  )
}
