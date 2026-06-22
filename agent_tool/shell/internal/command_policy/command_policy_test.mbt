///|
test "command policy allows moon subcommands through shell" {
  // moon check now runs through shell like every other moon subcommand.
  assert_true(
    @command_policy.moonbit_command_policy_error("moon check") is None,
  )
  assert_true(
    @command_policy.moonbit_command_policy_error("cd demo && moon check")
    is None,
  )
  assert_true(@command_policy.moonbit_command_policy_error("moon test") is None)
  assert_true(
    @command_policy.moonbit_command_policy_error("moon run cmd/main") is None,
  )
  assert_true(@command_policy.moonbit_command_policy_error("moon info") is None)
  assert_true(@command_policy.moonbit_command_policy_error("moon fmt") is None)
  assert_true(
    @command_policy.moonbit_command_policy_error("moon build") is None,
  )
  assert_true(
    @command_policy.moonbit_command_policy_error(
      "DEEPSEEK_MODEL=x moon run cmd/main",
    )
    is None,
  )
  assert_true(
    @command_policy.moonbit_command_policy_error("git status --short") is None,
  )
}

///|
test "command policy still redirects the moon_cmd tool name" {
  guard @command_policy.moonbit_command_policy_error("moon_cmd check")
    is Some(message) else {
    fail("expected moon_cmd to be redirected")
  }
  assert_true(message.contains("moon_cmd is not a shell command"))
}

///|
test "command policy detects moon_cmd in simple shell compounds" {
  for
    cmd in [
      "cd demo && moon_cmd check", "DEEPSEEK_MODEL=x moon_cmd run cmd/main", "env DEEPSEEK_MODEL=x moon_cmd check",
      "command moon_cmd check", "true || moon_cmd test", "moon_cmd check > out.log",
    ] {
    guard @command_policy.moonbit_command_policy_error(cmd) is Some(message) else {
      fail("expected moon_cmd to be redirected for \{cmd}")
    }
    assert_true(message.contains("moon_cmd is not a shell command"))
  }
}

///|
test "command policy does not match moon_cmd as data" {
  assert_true(
    @command_policy.moonbit_command_policy_error("printf '%s\\n' moon_cmd")
    is None,
  )
  assert_true(
    @command_policy.moonbit_command_policy_error("echo moon_cmd | cat") is None,
  )
  assert_true(
    @command_policy.moonbit_command_policy_error(
      "MOON_TOOL=moon_cmd moon check",
    )
    is None,
  )
}
