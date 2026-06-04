///|
test "command policy detects guarded MoonBit commands" {
  assert_true(moonbit_command_policy_error("moon test") is Some(_))
  assert_true(
    moonbit_command_policy_error("DEEPSEEK_MODEL=x moon run cmd/main")
    is Some(_),
  )
  assert_true(moonbit_command_policy_error("cd demo && moon check") is Some(_))
  assert_true(moonbit_command_policy_error("moon --version") is None)
  assert_true(moonbit_command_policy_error("git status --short") is None)
}
