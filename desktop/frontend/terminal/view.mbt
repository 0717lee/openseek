// The panel: a titlebar (status + restart/hide) over the emulator's stable
// host element. Rendered on every screen from the first paint — CSS hides
// the whole panel while closed — so the attached emulator is never torn
// down (see host.mbt).

///|
pub fn panel_view(
  dispatch : @cmd.Emit[Msg],
  state : State,
  _ctx : Ctx,
) -> @html.Html {
  let items : Array[@html.Html] = [
    @html.span(class="terminal-title", "Terminal"),
  ]
  match state.phase {
    Opening(..) =>
      items.push(@html.span(class="terminal-status", "starting…"))
    Exited(code~, ..) => {
      items.push(@html.span(class="terminal-status", "exited (\{code})"))
      items.push(
        @html.button(
          class="terminal-action",
          on_click=dispatch(RestartTerminal),
          "Restart",
        ),
      )
    }
    Failed(message~, ..) => {
      items.push(@html.span(class="terminal-status terminal-error", message))
      items.push(
        @html.button(
          class="terminal-action",
          on_click=dispatch(RestartTerminal),
          "Retry",
        ),
      )
    }
    Idle | Running(..) => ()
  }
  items.push(
    @html.button(
      class="terminal-close",
      title="Hide terminal",
      on_click=dispatch(ToggleTerminal),
      "✕",
    ),
  )
  // The stable element the emulator attaches into; it must stay empty and
  // never be re-keyed (see host.mbt).
  let host = @html.div(
    attrs=@html.Attrs::build().id(TerminalHostId).class("terminal-host"),
    ([] : Array[@html.Html]),
  )
  @html.div(
    class=if state.open { "terminal-panel open" } else { "terminal-panel" },
    [@html.div(class="terminal-titlebar", items), host],
  )
}
