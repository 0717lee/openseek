///|
test "command policy detects guarded MoonBit commands" {
  assert_true(moonbit_command_policy_error("moon check") is Some(_))
  assert_true(moonbit_command_policy_error("moon test") is None)
  assert_true(moonbit_command_policy_error("moon run cmd/main") is None)
  assert_true(moonbit_command_policy_error("moon info") is None)
  assert_true(moonbit_command_policy_error("moon fmt") is None)
  assert_true(moonbit_command_policy_error("moon build") is None)
  assert_true(
    moonbit_command_policy_error("DEEPSEEK_MODEL=x moon run cmd/main") is None,
  )
  assert_true(moonbit_command_policy_error("cd demo && moon check") is Some(_))
  assert_true(moonbit_command_policy_error("moon --version") is None)
  assert_true(moonbit_command_policy_error("git status --short") is None)
}
