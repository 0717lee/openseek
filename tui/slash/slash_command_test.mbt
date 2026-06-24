///|
test "has_arguments detects the separator after the command name" {
  assert_true(!@slash.has_arguments("model"))
  assert_true(@slash.has_arguments("model "))
  assert_true(@slash.has_arguments("model deepseek-v4-flash"))
}

///|
test "SlashCommandInvocation::parse reads /name arguments syntactically" {
  guard @slash.SlashCommandInvocation::parse("/model deepseek-v4-flash")
    is Some(invocation) else {
    fail("expected model invocation")
  }
  assert_eq(invocation.name(), "model")
  assert_eq(invocation.arguments(), "deepseek-v4-flash")
  // Trailing whitespace yields an empty, trimmed argument string.
  guard @slash.SlashCommandInvocation::parse("/model   ") is Some(trimmed) else {
    fail("expected model invocation with empty arguments")
  }
  assert_eq(trimmed.name(), "model")
  assert_eq(trimmed.arguments(), "")
  // Parsing is syntactic; unknown names still parse.
  guard @slash.SlashCommandInvocation::parse("/unknown x") is Some(unknown) else {
    fail("expected unknown invocation to parse")
  }
  assert_eq(unknown.name(), "unknown")
  assert_true(@slash.SlashCommandInvocation::parse("model") is None)
  assert_true(@slash.SlashCommandInvocation::parse("/") is None)
}
