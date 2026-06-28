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
test "read-only guard predicate matches fmt/info but not check" {
  assert_true(should_auto_check_moon_command("moon fmt"))
  assert_true(should_auto_check_moon_command("moon info"))
  assert_false(should_auto_check_moon_command("moon check"))
  assert_false(should_auto_check_moon_command("moon check --target all"))
  assert_false(should_auto_check_moon_command("git diff origin/main"))
}
