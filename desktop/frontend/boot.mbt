// The app's single entry, shared by the two shell executables:
// `frontend/desktop` (the window against the host's loopback origin) and
// `frontend/browser` (the console page openseek-api serves). Both are plain
// http pages now, so the shell names its own personality here.

///|
#warnings("-alert_unstable")
pub fn boot(desktop~ : Bool) -> Unit {
  let app = @rabbita.new(() => {
    let (state, emit) = @rabbita.create_state_with_init(
      // Init flows through `update` like any other message, as
      // `with_init(dispatch(Init))` did before the 0.13 migration.
      init=emit => (initial_model(desktop~), emit(Init)),
      update=(emit, msg, model) => {
        let (cmd, next) = update(emit, msg, model)
        (next, cmd)
      },
      // The narrow-layout flag must track the window: rotating a phone or
      // resizing a desktop window across the breakpoint re-lays the app out.
      subscriptions=(emit, _) => {
        @sub.batch([
          @sub.on_resize(
            emit.map(viewport => ViewportResized(width=viewport.width)),
          ),
          external_link_subscription(
            desktop~,
            emit.map(url => ExternalLinkClicked(url)),
          ),
        ])
      },
    )
    state.view(model => view(emit, model))
  })
  app.mount("app")
}
