// The embedded terminal emulators (vendored xterm.js, loaded as the
// `__openseek_xterm` global by an index.html script tag). Rabbita has no
// escape hatch for foreign DOM widgets, so the panel owns one stable,
// never-diffed container element (`#terminal-host`), and each tab attaches
// its own imperative child element with its own xterm instance — hidden,
// not disposed, while another tab (or none) shows, so every shell's screen
// and scrollback survive tab and conversation switches.

///|
/// The id of the stable container the tab emulators attach into; the panel
/// view must render exactly one empty element with this id.
const TerminalHostId = "terminal-host"

///|
priv struct TermEntry {
  term : @js.Value
  fit : @js.Value
  element : @js.Value
}

///|
/// The emulators' imperative state, keyed by tab key. `pending` buffers
/// output chunks that arrived before any tab claimed their session id (the
/// host streams from spawn, so a session's first output can beat the
/// `terminal_open` reply that names it); `Opened` flushes them into the
/// claiming tab.
priv struct TermHost {
  entries : Map[Int, TermEntry]
  pending : Map[Int, Array[(String, Int)]]
  mut resize_wired : Bool
}

///|
let term_host : TermHost = {
  entries: Map([]),
  pending: Map([]),
  resize_wired: false,
}

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
fn no_args() -> Array[@js.Value] {
  []
}

///|
/// Show `key`'s element, hide the rest, then re-fit and focus the shown one
/// (its `onResize` keeps the PTY's grid in sync). Imperative display state:
/// the elements are outside the virtual DOM.
fn show_only(key : Int) -> Unit {
  for entry_key, entry in term_host.entries {
    let style : @js.Value = entry.element.get_with_string("style")
    style.set_with_string(
      "display",
      if entry_key == key {
        "block"
      } else {
        "none"
      },
    )
  }
  guard term_host.entries.get(key) is Some(entry) else { return }
  let width : Int = entry.element.get_with_string("clientWidth")
  if width > 0 {
    let _ : @js.Value = entry.fit.apply_with_string("fit", no_args())
  }
  let _ : @js.Value = entry.term.apply_with_string("focus", no_args())
}

///|
/// Re-fit whichever tab element is currently visible (window resizes change
/// the panel's CSS layout without any tab switch).
fn refit_visible() -> Unit {
  for _, entry in term_host.entries {
    let width : Int = entry.element.get_with_string("clientWidth")
    if width > 0 {
      let _ : @js.Value = entry.fit.apply_with_string("fit", no_args())
    }
  }
}

///|
/// Mount the tab's emulator into the container (a no-op if it already
/// exists), make it the visible one, and report its grid size through
/// `EmulatorReady`. Idempotent: the update loop decides whether a ready
/// report should spawn a session, so re-reports are harmless.
fn mount_tab(
  dispatch : @cmd.Emit[Msg],
  key : Int,
  dark_mode : Bool,
) -> @cmd.Cmd {
  @cmd.custom_cmd(
    scheduler => {
      guard xterm_module() is Some(module_) else { return }
      if term_host.entries.get(key) is None {
        guard @dom.document().get_element_by_id(TerminalHostId).to_option()
          is Some(host) else {
          return
        }
        let document = @js.Value::cast_from(@dom.document())
        let element : @js.Value = document.apply_with_string("createElement", [
          @js.Value::cast_from("div"),
        ])
        element.set_with_string("className", "terminal-instance")
        let _ : @js.Value = @js.Value::cast_from(host).apply_with_string(
          "appendChild",
          [element],
        )
        let options = @js.Object::new()
        options["cursorBlink"] = true
        options["fontSize"] = 13
        options["fontFamily"] = "\"Geist Mono\", Menlo, monospace"
        options["scrollback"] = 10000
        options["theme"] = terminal_theme(dark_mode).to_value()
        let ctor : @js.Value = module_.get_with_string("Terminal")
        let term : @js.Value = ctor.new([options.to_value()])
        let fit_ctor : @js.Value = module_.get_with_string("FitAddon")
        let fit : @js.Value = fit_ctor.new(no_args())
        let _ : @js.Value = term.apply_with_string("loadAddon", [fit])
        let _ : @js.Value = term.apply_with_string("open", [element])
        // Keystrokes (already encoded as terminal input by xterm) go to the
        // update loop tagged with this tab.
        let on_data = (data : @js.Value) => {
          let text : String = data.cast()
          scheduler.add(dispatch(UserInput(key~, data=text)))
        }
        let _ : @js.Value = term.apply_with_string("onData", [
          @js.Value::cast_from(on_data),
        ])
        // Every re-fit lands here, including reveal-time ones; the update
        // loop forwards it to the tab's PTY while its session runs.
        let on_resize = (size : @js.Value) => {
          let cols : Int = size.get_with_string("cols")
          let rows : Int = size.get_with_string("rows")
          scheduler.add(dispatch(ViewportResized(key~, cols~, rows~)))
        }
        let _ : @js.Value = term.apply_with_string("onResize", [
          @js.Value::cast_from(on_resize),
        ])
        term_host.entries[key] = { term, fit, element }
        if !term_host.resize_wired {
          term_host.resize_wired = true
          @interop.add_capture_listener(@js.globalThis, "resize", _event => {
            refit_visible()
          })
        }
      }
      show_only(key)
      guard term_host.entries.get(key) is Some(entry) else { return }
      let cols : Int = entry.term.get_with_string("cols")
      let rows : Int = entry.term.get_with_string("rows")
      scheduler.add(dispatch(EmulatorReady(key~, cols~, rows~)))
    },
    kind=@cmd.after_render,
  )
}

///|
fn hide_all() -> Unit {
  for _, entry in term_host.entries {
    let style : @js.Value = entry.element.get_with_string("style")
    style.set_with_string("display", "none")
  }
}

///|
/// Aim the display at one tab's emulator (or none, while the panel is
/// closed): show it, hide the rest, re-fit and focus. `sync` dispatches
/// this whenever the tab that should be on screen changes — including
/// conversation switches, which produce no terminal message of their own.
fn apply_shown(key : Int?) -> @cmd.Cmd {
  @cmd.custom_cmd(
    _scheduler => {
      match key {
        Some(key) => show_only(key)
        None => hide_all()
      }
    },
    kind=@cmd.after_render,
  )
}

///|
/// Decode one base64 output chunk into the tab's emulator and report its
/// byte count back once xterm finished rendering it (the flow-control ack).
/// A chunk with no emulator to land in is acknowledged outright — an
/// unacknowledged chunk leaks the host's flow-control window and eventually
/// stalls the session.
fn write_to_tab(
  dispatch : @cmd.Emit[Msg],
  key : Int,
  id : Int,
  data : String,
  bytes : Int,
) -> @cmd.Cmd {
  @cmd.custom_cmd(_scheduler => {
    guard term_host.entries.get(key) is Some(entry) &&
      xterm_module() is Some(module_) else {
      _scheduler.add(dispatch(OutputRendered(id~, bytes~)))
      return
    }
    let done = (length : @js.Value) => {
      let rendered : Int = length.cast()
      _scheduler.add(dispatch(OutputRendered(id~, bytes=rendered)))
    }
    let _ : @js.Value = module_.apply_with_string("writeBase64", [
      entry.term,
      @js.Value::cast_from(data),
      @js.Value::cast_from(done),
    ])
  })
}

///|
/// Stash an output chunk whose session id no tab has claimed yet.
fn buffer_pending(id : Int, data : String, bytes : Int) -> @cmd.Cmd {
  @cmd.custom_cmd(_scheduler => {
    let chunks = term_host.pending.get(id).unwrap_or([])
    chunks.push((data, bytes))
    term_host.pending[id] = chunks
  })
}

///|
/// Flush chunks buffered for `id` into the tab that just claimed it. Every
/// flushed chunk goes through the normal write path, so each one is
/// acknowledged as it renders.
fn flush_pending(dispatch : @cmd.Emit[Msg], key : Int, id : Int) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    guard term_host.pending.get(id) is Some(chunks) else { return }
    term_host.pending.remove(id)
    for chunk in chunks {
      scheduler.add(write_to_tab(dispatch, key, id, chunk.0, chunk.1))
    }
  })
}

///|
/// Drop any buffer for a session that ended unclaimed, acknowledging the
/// bytes so the host's window is released before the session's teardown.
fn drop_pending(dispatch : @cmd.Emit[Msg], id : Int) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    guard term_host.pending.get(id) is Some(chunks) else { return }
    term_host.pending.remove(id)
    for chunk in chunks {
      scheduler.add(dispatch(OutputRendered(id~, bytes=chunk.1)))
    }
  })
}

///|
/// Blank a tab's emulator for a restart: the widget survives, the screen
/// and scrollback do not.
fn reset_tab(key : Int) -> @cmd.Cmd {
  @cmd.custom_cmd(_scheduler => {
    guard term_host.entries.get(key) is Some(entry) else { return }
    let _ : @js.Value = entry.term.apply_with_string("reset", no_args())
  })
}

///|
/// Dispose a closed tab's emulator and remove its element.
fn dispose_tab(key : Int) -> @cmd.Cmd {
  @cmd.custom_cmd(_scheduler => {
    guard term_host.entries.get(key) is Some(entry) else { return }
    term_host.entries.remove(key)
    let _ : @js.Value = entry.term.apply_with_string("dispose", no_args())
    let _ : @js.Value = entry.element.apply_with_string("remove", no_args())
  })
}
