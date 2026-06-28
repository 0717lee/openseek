///|
/// Read-only mode (used by `--review`) must refuse source-mutating moon commands
/// before they run, even though such commands are otherwise "trusted" and run
/// unsandboxed. The guard fires before execution, so no subprocess is spawned.
async test "read-only shell blocks source-mutating moon commands" {
  let blocked = execute_with_workspace(
    ".",
    { "cmd": "moon fmt" },
    read_only=true,
  )
  guard blocked is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("read-only review mode"))
}

///|
test "read-only guard blocks mutating moon anywhere; allows read-only commands" {
  // mutating moon — plain, chained either way, and env-prefixed (all bypasses)
  assert_true(
    review_read_only_blocks(@shell_parse.parse_for_policy("moon fmt")),
  )
  assert_true(
    review_read_only_blocks(@shell_parse.parse_for_policy("moon info")),
  )
  assert_true(
    review_read_only_blocks(
      @shell_parse.parse_for_policy("moon fmt && git diff"),
    ),
  )
  assert_true(
    review_read_only_blocks(
      @shell_parse.parse_for_policy("git diff && moon fmt"),
    ),
  )
  assert_true(
    review_read_only_blocks(
      @shell_parse.parse_for_policy("moon test --update; true"),
    ),
  )
  assert_true(
    review_read_only_blocks(@shell_parse.parse_for_policy("FOO=bar moon fmt")),
  )
  // a pipe segment that mutates is still caught (pipes parse as Simple)
  assert_true(
    review_read_only_blocks(@shell_parse.parse_for_policy("moon fmt | tee out")),
  )
  // a read-only pipe is allowed (no mutating segment)
  assert_false(
    review_read_only_blocks(@shell_parse.parse_for_policy("git diff | head")),
  )
  // read-only commands — allowed
  assert_false(
    review_read_only_blocks(@shell_parse.parse_for_policy("moon check")),
  )
  assert_false(
    review_read_only_blocks(
      @shell_parse.parse_for_policy("moon check --target all"),
    ),
  )
  assert_false(
    review_read_only_blocks(@shell_parse.parse_for_policy("moon test")),
  )
  assert_false(
    review_read_only_blocks(@shell_parse.parse_for_policy("moon fmt --check")),
  )
  assert_false(
    review_read_only_blocks(
      @shell_parse.parse_for_policy("git diff origin/main"),
    ),
  )
}
