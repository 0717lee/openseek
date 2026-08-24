///|
extern "js" fn titlebar_test_element(
  in_titlebar : Bool,
  interactive : Bool,
) -> @dom.Element =
  #| (inTitlebar, interactive) => ({
  #|   closest(selector) {
  #|     if (selector === ".sidebar-header, .topbar, .editor-tabsbar") {
  #|       return inTitlebar ? this : null;
  #|     }
  #|     if (selector === "button, a, input, textarea, select, [role=button], .editor-tab") {
  #|       return interactive ? this : null;
  #|     }
  #|     return null;
  #|   },
  #| })

///|
test "window zoom gesture accepts chrome and excludes controls" {
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
