///|
/// Rabbita 0.13 only propagates a state value when its `Eq` comparison changes.
/// The visualizer rebuilds mutable containers before changing them, but its
/// parsed-log and session types do not expose structural `Eq` yet. Preserve the
/// old full-view refresh until equality is available through that type graph.
priv struct AppState(Model)

///|
impl Eq for AppState with fn equal(_, _) {
  false
}

///|
/// Mount the visualizer onto `#app` and kick off the initial session-list fetch.
/// The frontend talks only to the read-only viz server's JSON/raw-file API.
#warnings("-alert_unstable")
fn main {
  let app = @rabbita.new(() => {
    let (state, emit) = @rabbita.create_state_with_init(
      init=emit => {
        (
          AppState(init_model()),
          // Route the initial listing through fetch_text so a standalone export
          // answers it from the embedded data map instead of the absent server.
          @cmd.batch([
            fetch_text(emit, "/api/sessions", result => SessionsFetched(result)),
            install_shortcuts(emit),
            // Subrun chips navigate by writing `#s=…`; turn those hash changes
            // into selections.
            install_hash_navigation(emit),
            // Keep `seq=` in the URL hash while scrolling and make scrubber
            // segments jump, so a refresh restores the position.
            @cmd.effect(() => install_position_tracker()),
          ]),
        )
      },
      update=(emit, msg, state) => {
        let (cmd, model) = update(emit, msg, state.0)
        (AppState(model), cmd)
      },
    )
    state.view(state => view(emit, state.0))
  })
  app.mount("app")
}
