// The app's single entry, shared by the two shell executables:
// `frontend/desktop` (the proton webview) and `frontend/browser` (the
// console page openseek-api serves). Which personality the page runs is
// still decided at runtime by `@interop.page_channel()`.

///|
/// Browser platform label used to keep Ctrl+T available to terminal programs
/// on Apple systems while using the conventional Ctrl shortcut elsewhere.
fn quick_open_browser_platform() -> String {
  let navigator = @js.Value::cast_from(@dom.window().navigator())
  if @interop.js_prop(navigator, "userAgentData") is Some(user_agent_data) &&
    @interop.js_prop(user_agent_data, "platform") is Some(value) &&
    (@js.Cast::into(value) : String?) is Some(platform) &&
    !platform.is_empty() {
    return platform
  }
  if @interop.js_prop(navigator, "platform") is Some(value) &&
    (@js.Cast::into(value) : String?) is Some(platform) {
    platform
  } else {
    ""
  }
}

///|
fn quick_open_platform_is_apple() -> Bool {
  let platform = quick_open_browser_platform().to_lower()
  platform.contains("mac") ||
  platform.contains("iphone") ||
  platform.contains("ipad") ||
  platform.contains("ipod")
}

///|
/// Map only the platform's exact, non-repeating command chords.
fn quick_open_shortcut_mode(
  keyboard : @rabbita/common.Keyboard,
  is_apple : Bool,
) -> QuickOpenMode? {
  let command = if is_apple {
    keyboard.meta_key() && !keyboard.ctrl_key()
  } else {
    keyboard.ctrl_key() && !keyboard.meta_key()
  }
  guard command &&
    !keyboard.shift_key() &&
    !keyboard.alt_key() &&
    !keyboard.is_composing() &&
    !keyboard.repeat() else {
    return None
  }
  match keyboard.code() {
    "KeyP" => Some(QuickOpenFiles)
    "KeyT" => Some(QuickOpenSymbols)
    _ => None
  }
}

///|
#warnings("-alert_unstable")
pub fn boot() -> Unit {
  let app = @rabbita.new(() => {
    let (state, emit) = @rabbita.create_state_with_init(
      // Init flows through `update` like any other message, as
      // `with_init(dispatch(Init))` did before the 0.13 migration.
      init=emit => (initial_model(), emit(Init)),
      update=(emit, msg, model) => {
        let (cmd, next) = update(emit, msg, model)
        (next, cmd)
      },
      // The narrow-layout flag must track the window: rotating a phone or
      // resizing a desktop window across the breakpoint re-lays the app out.
      // Global application shortcuts share Rabbita's normalized document
      // keydown subscription. Quick Open remains desktop-only so a browser
      // console retains its own Cmd/Ctrl+P/T behavior.
      subscriptions=(emit, model) => {
        let is_apple = if model.is_desktop {
          quick_open_platform_is_apple()
        } else {
          false
        }
        @sub.batch([
          @sub.on_resize(
            emit.map(viewport => ViewportResized(width=viewport.width)),
          ),
          @sub.on_key_down(
            @cmd.Emit((keyboard : @rabbita/common.Keyboard) => {
              if model.is_desktop &&
                quick_open_shortcut_mode(keyboard, is_apple) is Some(mode) {
                emit(QuickOpenOpen(mode))
              } else if keyboard.code() == "Backquote" &&
                keyboard.ctrl_key() &&
                !keyboard.shift_key() &&
                !keyboard.alt_key() &&
                !keyboard.meta_key() &&
                !keyboard.is_composing() &&
                !keyboard.repeat() {
                emit(Terminal(ToggleTerminal))
              } else {
                @cmd.none
              }
            }),
          ),
          external_link_subscription(emit.map(url => ExternalLinkClicked(url))),
        ])
      },
    )
    state.view(model => view(emit, model))
  })
  app.mount("app")
}
