// The native overlay titlebar is painted by the page, so its web content has
// to recreate the operating system's double-click-to-zoom convention. Keep
// the gesture at the document boundary: the visible top chrome is split
// between the left sidebar, conversation topbar, and expanded editor strip.

///|
const WindowTitlebarSelector = ".sidebar-header, .topbar, .editor-tabsbar, .window-titlebar-drag-strip"

///|
const WindowTitlebarExcludedSelector = "button, a, input, textarea, select, [role=button], [contenteditable=true], .editor-tab, .dock-menu"

///|
fn window_titlebar_platform_supports_overlay(platform : String) -> Bool {
  browser_platform_is_apple(platform) || browser_platform_is_windows(platform)
}

///|
fn window_titlebar_overlay_supported() -> Bool {
  window_titlebar_platform_supports_overlay(app_shortcut_browser_platform())
}

///|
fn window_titlebar_drag_strip_visible(
  page_without_topbar : Bool,
  is_desktop : Bool,
  platform : String,
) -> Bool {
  page_without_topbar &&
  is_desktop &&
  window_titlebar_platform_supports_overlay(platform)
}

///|
fn is_window_titlebar_double_click_target(element : @dom.Element) -> Bool {
  if element.closest(WindowTitlebarExcludedSelector) is Some(_) {
    return false
  }
  element.closest(WindowTitlebarSelector) is Some(_)
}

///|
/// CEF needs the initial drag region assigned after the DOM exists. Repeating
/// this during subscription reconciliation also covers a topbar replaced by a
/// page transition; CSS remains the steady-state declaration.
extern "js" fn install_window_titlebar_drag_regions() -> Unit =
  #| () => {
  #|   const roots = document.querySelectorAll(
  #|     ".sidebar-header, .topbar, .editor-tabsbar, .window-titlebar-drag-strip",
  #|   );
  #|   const excluded =
  #|     "button, a, input, textarea, select, [role=button], [contenteditable=true], .editor-tab, .dock-menu";
  #|   for (const root of roots) {
  #|     root.style.webkitAppRegion = "drag";
  #|     for (const control of root.querySelectorAll(excluded)) {
  #|       control.style.webkitAppRegion = "no-drag";
  #|     }
  #|   }
  #| }

///|
priv suberror WindowTitlebarSubscription {
  WindowTitlebarSubscription(@cmd.Emit[Unit])
}

///|
fn window_titlebar_sub_loader(
  payload : Error,
  scheduler : &Scheduler,
) -> @sub.RunningSub? {
  match payload {
    WindowTitlebarSubscription(emit) => {
      let mut emit = emit
      let target = @dom.document().as_event_target()
      install_window_titlebar_drag_regions()
      let listener : @dom.Listener = event => {
        guard event.to_mouse_event() is Some(mouse) &&
          mouse.get_button() == 0 &&
          event.target().to_element() is Some(element) &&
          is_window_titlebar_double_click_target(element) else {
          return
        }
        // A title or workspace label is text in the DOM, but within window
        // chrome it behaves as chrome rather than selectable document text.
        event.prevent_default()
        scheduler.add(emit(()))
      }
      target.add_event_listener_with_options("dblclick", listener, capture=true)
      Some({
        unload: _ => {
          target.remove_event_listener_with_options(
            "dblclick",
            listener,
            capture=true,
          )
        },
        update_tagger: payload => {
          guard payload is WindowTitlebarSubscription(next) else { return }
          emit = next
          install_window_titlebar_drag_regions()
        },
      })
    }
    _ => None
  }
}

///|
/// Install only after the caller has established that this is a desktop page
/// on a platform where Proton overlays web content into the native titlebar.
fn window_titlebar_subscription(emit : @cmd.Emit[Unit]) -> @sub.Sub {
  @sub.custom_sub(
    "window-titlebar-double-click",
    Global,
    WindowTitlebarSubscription(emit),
    window_titlebar_sub_loader,
  )
}
