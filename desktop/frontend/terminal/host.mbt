// The embedded terminal emulator (vendored xterm.js, loaded as the
// `__openseek_xterm` global by an index.html script tag). Rabbita has no
// escape hatch for a foreign DOM widget, so the emulator owns one stable,
// never-diffed host element — the same pattern as the file editor's viewer
// host: the view renders `<div id="terminal-host">` empty and always (CSS
// hides the closed panel), and the widget attaches into it once, after a
// paint.

///|
/// The id of the stable element the emulator attaches into; the panel view
/// must render exactly one empty element with this id.
const TerminalHostId = "terminal-host"

///|
/// The emulator's imperative state. None of this may live in the Rabbita
/// model, so it is collected into this one module-level instance.
priv struct TermHost {
  /// The single xterm `Terminal` instance, `None` until the first mount.
  mut term : @js.Value?
  /// Its fit addon, sized to the host element by `fit()`.
  mut fit : @js.Value?
  /// The host-side session id the emulator is wired to; output for any
  /// other id is stale (a session retired by a conversation switch) and
  /// dropped at the write boundary.
  mut wired : Int?
}

///|
let term_host : TermHost = { term: None, fit: None, wired: None }

///|
/// The vendored bundle's export object (`{ Terminal, FitAddon, writeBase64 }`).
fn xterm_module() -> @js.Value? {
  @interop.js_prop(@js.globalThis, "__openseek_xterm")
}

///|
/// The emulator's color theme for the app's light/dark scheme.
fn terminal_theme(dark_mode : Bool) -> @js.Object {
  // Concrete values of the app's `--surface`/`--ink` design tokens (xterm
  // takes colors, not CSS variables).
  let theme = @js.Object::new()
  if dark_mode {
    theme["background"] = "#1c1f26"
    theme["foreground"] = "#e9ebf0"
    theme["cursor"] = "#e9ebf0"
  } else {
    theme["background"] = "#ffffff"
    theme["foreground"] = "#16171a"
    theme["cursor"] = "#16171a"
  }
  theme
}

///|
/// Mount the emulator into its host element after the next paint (a no-op
/// mount if it already exists), re-fit it to the panel's current size, and
/// report the resulting grid through `EmulatorReady`. The update loop calls
/// this on panel open and on restart; whether a ready report should spawn a
/// session is its decision, so re-reports are harmless.
fn request_terminal_mount(dispatch : @cmd.Emit[Msg], ctx : Ctx) -> @cmd.Cmd {
  @cmd.custom_cmd(
    scheduler => {
      guard xterm_module() is Some(module_) else { return }
      if term_host.term is None &&
        @dom.document().get_element_by_id(TerminalHostId).to_option()
        is Some(host) {
        let options = @js.Object::new()
        options["cursorBlink"] = true
        options["fontSize"] = 13
        options["fontFamily"] = "\"Geist Mono\", Menlo, monospace"
        options["scrollback"] = 10000
        options["theme"] = terminal_theme(ctx.dark_mode).to_value()
        let ctor : @js.Value = module_.get_with_string("Terminal")
        let term : @js.Value = ctor.new([options.to_value()])
        let fit_ctor : @js.Value = module_.get_with_string("FitAddon")
        let fit : @js.Value = fit_ctor.new(([] : Array[@js.Value]))
        let _ : @js.Value = term.apply_with_string("loadAddon", [fit])
        let _ : @js.Value = term.apply_with_string("open", [
          @js.Value::cast_from(host),
        ])
        // Keystrokes (already encoded as terminal input by xterm) go to the
        // update loop; whether a session receives them is its decision.
        let on_data = (data : @js.Value) => {
          let text : String = data.cast()
          scheduler.add(dispatch(UserInput(data=text)))
        }
        let _ : @js.Value = term.apply_with_string("onData", [
          @js.Value::cast_from(on_data),
        ])
        // Every re-fit lands here, including the initial one below; the
        // update loop forwards it to the PTY while a session runs.
        let on_resize = (size : @js.Value) => {
          let cols : Int = size.get_with_string("cols")
          let rows : Int = size.get_with_string("rows")
          scheduler.add(dispatch(ViewportResized(cols~, rows~)))
        }
        let _ : @js.Value = term.apply_with_string("onResize", [
          @js.Value::cast_from(on_resize),
        ])
        // The panel is laid out by CSS, so window resizes must re-measure
        // the emulator; the resulting onResize forwards to the PTY.
        @interop.add_capture_listener(@js.globalThis, "resize", _event => {
          refit()
        })
        term_host.term = Some(term)
        term_host.fit = Some(fit)
      }
      refit()
      guard term_host.term is Some(term) else { return }
      let cols : Int = term.get_with_string("cols")
      let rows : Int = term.get_with_string("rows")
      scheduler.add(dispatch(EmulatorReady(cols~, rows~)))
    },
    kind=@cmd.after_render,
  )
}

///|
/// Re-measure the emulator against its host element. A no-op while the
/// panel is hidden (`display: none` gives a zero-size host, which the fit
/// addon cannot measure).
fn refit() -> Unit {
  guard term_host.fit is Some(fit) else { return }
  guard @dom.document().get_element_by_id(TerminalHostId).to_option()
    is Some(host) else {
    return
  }
  let width : Int = @js.Value::cast_from(host).get_with_string("clientWidth")
  if width <= 0 {
    return
  }
  let _ : @js.Value = fit.apply_with_string("fit", ([] : Array[@js.Value]))
}

///|
/// Bind the emulator to a freshly opened PTY session and focus it.
fn wire_session(id : Int) -> @cmd.Cmd {
  @cmd.custom_cmd(_scheduler => {
    term_host.wired = Some(id)
    if term_host.term is Some(term) {
      let _ : @js.Value = term.apply_with_string(
        "focus",
        ([] : Array[@js.Value]),
      )
    }
  })
}

///|
/// Re-fit (the panel just became visible again) and focus.
fn focus_terminal() -> @cmd.Cmd {
  @cmd.custom_cmd(
    _scheduler => {
      refit()
      if term_host.term is Some(term) {
        let _ : @js.Value = term.apply_with_string(
          "focus",
          ([] : Array[@js.Value]),
        )
      }
    },
    kind=@cmd.after_render,
  )
}

///|
/// Decode one base64 output chunk into the emulator and report its byte
/// count back once xterm finished rendering it (the flow-control ack).
/// Dropped when the chunk is for a session the emulator is no longer wired
/// to.
fn write_output(dispatch : @cmd.Emit[Msg], id : Int, data : String) -> @cmd.Cmd {
  @cmd.custom_cmd(_scheduler => {
    guard term_host.wired is Some(wired) && wired == id else { return }
    guard term_host.term is Some(term) && xterm_module() is Some(module_) else {
      return
    }
    let done = (length : @js.Value) => {
      let bytes : Int = length.cast()
      _scheduler.add(dispatch(OutputRendered(id~, bytes~)))
    }
    let _ : @js.Value = module_.apply_with_string("writeBase64", [
      term,
      @js.Value::cast_from(data),
      @js.Value::cast_from(done),
    ])
  })
}

///|
/// Unbind and blank the emulator (a conversation switch or restart): the
/// widget survives, the screen and scrollback do not.
fn reset_emulator() -> @cmd.Cmd {
  @cmd.custom_cmd(_scheduler => {
    term_host.wired = None
    if term_host.term is Some(term) {
      let _ : @js.Value = term.apply_with_string(
        "reset",
        ([] : Array[@js.Value]),
      )
    }
  })
}
