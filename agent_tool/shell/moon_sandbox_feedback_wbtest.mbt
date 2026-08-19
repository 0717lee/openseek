///|
test "sandbox explains downgraded Moon writer pipelines" {
  let parsed = @shell_parse.parse_for_policy(
    "moon info 2>&1 | grep -c 'Failed to copy'",
  )
  assert_true(downgraded_moon_source_writer(parsed) is Some("moon info"))
  let feedback = shell_sandbox_denial_feedback(
    parsed, "Operation not permitted",
  )
  assert_true(feedback.contains("whole shell request ran read-only"))
  assert_true(feedback.contains("Run the Moon invocation in its own"))
  assert_true(feedback.contains("/tmp/moon-info.log"))
  assert_false(
    feedback.contains("make source changes with line-anchored `edit`"),
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
  assert_true(feedback.contains("the `moon info` invocation was combined"))
  assert_true(feedback.contains("inspect the file in a second shell"))
}

///|
test "sandbox keeps generic feedback outside downgraded Moon writers" {
  let standalone = @shell_parse.parse_for_policy("moon info")
  assert_true(downgraded_moon_source_writer(standalone) is None)
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
  assert_true(downgraded_moon_source_writer(trusted_chain) is None)
  assert_eq(
    shell_sandbox_denial_feedback(trusted_chain, "Operation not permitted"),
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
