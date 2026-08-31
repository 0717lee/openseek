///|
test "native overlay shell classes stay desktop and platform specific" {
  assert_eq(app_shell_class(true, false, "MacIntel"), "app")
  assert_eq(app_shell_class(false, false, "Win32"), "app sidebar-collapsed")
  assert_eq(
    app_shell_class(true, true, "MacIntel"),
    "app native-titlebar-overlay native-apple-titlebar",
  )
  assert_eq(
    app_shell_class(false, true, "Windows"),
    "app sidebar-collapsed native-titlebar-overlay native-windows-titlebar",
  )
  assert_eq(app_shell_class(true, true, "Linux x86_64"), "app")
}
