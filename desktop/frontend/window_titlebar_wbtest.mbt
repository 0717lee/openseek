///|
extern "js" fn titlebar_test_element(
  in_titlebar : Bool,
  excluded : Bool,
) -> @dom.Element =
  #| (inTitlebar, excluded) => ({
  #|   closest(selector) {
  #|     if (selector === ".sidebar-header, .topbar, .editor-tabsbar, .window-titlebar-drag-strip") {
  #|       return inTitlebar ? this : null;
  #|     }
  #|     if (selector === "button, a, input, textarea, select, [role=button], [contenteditable=true], .editor-tab, .dock-menu") {
  #|       return excluded ? this : null;
  #|     }
  #|     return null;
  #|   },
  #| })

///|
test "window zoom gesture accepts chrome and excludes controls and popups" {
  assert_true(
    is_window_titlebar_double_click_target(titlebar_test_element(true, false)),
  )
  assert_false(
    is_window_titlebar_double_click_target(titlebar_test_element(true, true)),
  )
  assert_false(
    is_window_titlebar_double_click_target(titlebar_test_element(false, false)),
  )
}

///|
test "the explicit blank-page drag strip is titlebar chrome" {
  let strip = titlebar_test_element(true, false)
  assert_true(is_window_titlebar_double_click_target(strip))
}

///|
test "window titlebar gesture follows Proton overlay platforms" {
  assert_true(
    window_titlebar_platform_supports_overlay("MacIntel", is_windows=false),
  )
  assert_true(
    window_titlebar_platform_supports_overlay("Windows", is_windows=true),
  )
  assert_true(
    window_titlebar_platform_supports_overlay("Win32", is_windows=true),
  )
  assert_false(
    window_titlebar_platform_supports_overlay("Linux x86_64", is_windows=false),
  )
}

///|
test "blank-page drag strip exists only in a native overlay window" {
  assert_true(
    window_titlebar_drag_strip_visible(true, true, "Windows", is_windows=true),
  )
  assert_true(
    window_titlebar_drag_strip_visible(true, true, "MacIntel", is_windows=false),
  )
  assert_false(
    window_titlebar_drag_strip_visible(false, true, "Windows", is_windows=true),
  )
  assert_false(
    window_titlebar_drag_strip_visible(true, false, "Windows", is_windows=true),
  )
  assert_false(
    window_titlebar_drag_strip_visible(
      true,
      true,
      "Linux x86_64",
      is_windows=false,
    ),
  )
}
