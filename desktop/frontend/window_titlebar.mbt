// The native overlay titlebar is painted by the page, so its web content has
// to recreate the operating system's double-click-to-zoom convention. Keep
// the gesture at the document boundary: the visible top chrome is split
// between the left sidebar, conversation topbar, and expanded editor strip.

///|
const WindowTitlebarSelector = ".sidebar-header, .topbar, .editor-tabsbar"

///|
const WindowTitlebarInteractiveSelector = "button, a, input, textarea, select, [role=button], .editor-tab"

///|
fn is_window_titlebar_double_click_target(element : @dom.Element) -> Bool {
  element.closest(WindowTitlebarSelector) is Some(_) &&
  element.closest(WindowTitlebarInteractiveSelector) is None
}

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
        },
      })
    }
    _ => None
  }
}

///|
/// Install only in the desktop personality. Browser consoles render the same
/// top chrome but do not own a native application window to resize.
fn window_titlebar_subscription(emit : @cmd.Emit[Unit]) -> @sub.Sub {
  @sub.custom_sub(
    "window-titlebar-double-click",
    Global,
    WindowTitlebarSubscription(emit),
    window_titlebar_sub_loader,
  )
}
