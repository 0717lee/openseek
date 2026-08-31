///|
test "native overlay shell classes stay desktop and platform specific" {
  assert_eq(app_shell_class(true, false, "MacIntel", is_windows=false), "app")
  assert_eq(
    app_shell_class(false, false, "Win32", is_windows=true),
    "app sidebar-collapsed",
  )
  assert_eq(
    app_shell_class(true, true, "MacIntel", is_windows=false),
    "app native-titlebar-overlay native-apple-titlebar",
  )
  assert_eq(
    app_shell_class(false, true, "Windows", is_windows=true),
    "app sidebar-collapsed native-titlebar-overlay native-windows-titlebar",
  )
  assert_eq(
    app_shell_class(true, true, "Linux x86_64", is_windows=false),
    "app",
  )
}
