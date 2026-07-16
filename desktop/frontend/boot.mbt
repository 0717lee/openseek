// The app's single entry, shared by the two shell executables:
// `frontend/desktop` (the proton webview) and `frontend/browser` (the
// console page openseek-api serves). Which personality the page runs is
// still decided at runtime by `@interop.page_channel()`.

///|
/// Bridge to rabbita 0.13's signal runtime: the root model predates
/// signal-granular change detection, so its equality deliberately reports
/// "changed" and every message re-renders the whole view — exactly the
/// 0.12 behavior (rabbita's own compatibility shim does the same).
/// Honest per-component `Eq` arrives with the component split.
priv struct RootModel(Model)

///|
impl Eq for RootModel with fn equal(_, _) {
  false
}

///|
#warnings("-alert_unstable")
pub fn boot() -> Unit {
  let app = @rabbita.new(() => {
    let (model, emit) = @rabbita.create_state_with_init(
      // Init flows through `update` like any other message, as
      // `with_init(dispatch(Init))` did before the 0.13 migration.
      init=emit => (RootModel(initial_model()), emit(Init)),
      update=(emit, msg, model : RootModel) => {
        let (cmd, next) = update(emit, msg, model.0)
        (RootModel(next), cmd)
      },
      // The narrow-layout flag must track the window: rotating a phone or
      // resizing a desktop window across the breakpoint re-lays the app out.
      subscriptions=(emit, _) => {
        @sub.on_resize(
          emit.map(viewport => ViewportResized(width=viewport.width)),
        )
      },
    )
    model.map(model => view(emit, model.0))
  })
  app.mount("app")
}
