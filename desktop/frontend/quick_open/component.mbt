///|
/// Build the palette's independently updating Html. It re-renders when the
/// palette's own state changes and at no other time.
///
/// The shell holds the `State` rather than the package: opening is a global
/// shortcut whose capture-phase listener the shell already owns, the palette's
/// openness decides whether native browser views may stay on screen, and an
/// accepted row must reach the editor inside the same root transition that
/// closed the palette. Everything the palette draws is derived from `State`;
/// `Input` reaches the package only through `open`, `handle`, and `reconcile`,
/// so nothing here can read the application model.
pub fn component(
  state : @rabbita.Val[State],
  emit : @cmd.Emit[Msg],
) -> @rabbita.Val[@html.Html] {
  state.view(state => state.view(emit))
}
