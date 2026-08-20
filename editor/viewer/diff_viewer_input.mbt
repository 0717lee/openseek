// Diff-only input forwarding. The ordinary Viewer API stays unchanged; the
// coordinator reaches the already installed MouseHandler so the shared rail
// inherits the editor's wheel classification, smooth scrolling, pointer
// capture, platform drag reset, and track-jump behavior.

///|
fn Viewer::delegate_vertical_scrollbar_pointer_down(
  self : Viewer,
  event : @rdom.Event,
) -> Unit {
  match self.current_code_browser_data() {
    Some(browser) =>
      browser.mouse_handler.delegate_vertical_scrollbar_pointer_down(event)
    None => ()
  }
}

///|
fn Viewer::delegate_scroll_from_mouse_wheel_event(
  self : Viewer,
  event : @rdom.Event,
) -> Bool {
  guard self.current_code_browser_data() is Some(browser) else { return false }
  guard event.to_wheel_event() is Some(wheel) else { return false }
  browser.mouse_handler.handle_editor_wheel(event, wheel)
}
