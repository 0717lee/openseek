///|
/// Monaco's shared Definition/References Peek controller id. Each
/// CodeEditorWidget owns one shared-controller instance; Markdown surfaces
/// construct a separate instance with their own host adapter.
let references_contribution_id : String = "editor.contrib.referencesController"

///|
priv struct ReferencesContributionState {
  controller : @references_browser.ReferencesController
  mut disposed : Bool
}

///|
fn ReferencesContributionState::ReferencesContributionState(
  viewer : CodeEditorWidget,
) -> ReferencesContributionState {
  { controller: viewer.create_references_controller(), disposed: false, }
}

///|
fn ReferencesContributionState::dispose(
  self : ReferencesContributionState,
  _viewer : CodeEditorWidget,
) -> Unit {
  if self.disposed {
    return
  }
  self.disposed = true
  self.controller.dispose()
}

///|
fn register_references_contribution(
  registry : EditorContributionRegistry,
) -> Unit {
  registry.register_editor_contribution(
    references_contribution_id,
    References,
    Lazy,
    viewer => References(ReferencesContributionState(viewer)),
    _viewer => [],
  )
  let goto_references = @goto_symbol.GoToReferences
  registry.register_editor_command(
    goto_references.id(),
    viewer => viewer.references_action_available(),
    viewer => viewer.start_goto_references(),
    [],
    shift_keybindings=[("F12", false, false)],
    title=goto_references.title(),
    menu_keybinding_label=goto_references.keybinding_label().unwrap(),
    menu_placements=[
      { menu_id: EditorContext, group: "navigation", order: 1.3, },
    ],
  )
  let peek_references = @goto_symbol.PeekReferences
  registry.register_editor_command(
    peek_references.id(),
    viewer => viewer.references_action_available(),
    viewer => viewer.start_peek_references(),
    [],
    title=peek_references.title(),
    menu_placements=[
      { menu_id: EditorContext, group: "navigation", order: 1.4, },
    ],
  )
}

///|
fn CodeEditorWidget::references_contribution(
  self : CodeEditorWidget,
) -> ReferencesContributionState? {
  match self.contributions.lookup(references_contribution_id) {
    Some(entry) =>
      match entry.instance {
        References(state) => Some(state)
        _ => None
      }
    None => None
  }
}
