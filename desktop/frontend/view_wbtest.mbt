///|
test "the native Apple shell reserves titlebar space without changing browser classes" {
  assert_eq(app_shell_class(true, false), "app")
  assert_eq(app_shell_class(false, false), "app sidebar-collapsed")
  assert_eq(app_shell_class(true, true), "app native-apple-titlebar")
  assert_eq(
    app_shell_class(false, true),
    "app sidebar-collapsed native-apple-titlebar",
  )
}
