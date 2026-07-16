///|
/// Bridge to rabbita 0.13's signal runtime: the viz model has no
/// signal-granular change detection, so its equality deliberately reports
/// "changed" and every message re-renders — the 0.12 behavior.
priv struct RootModel(Model)

///|
impl Eq for RootModel with fn equal(_, _) {
  false
}

///|
/// Mount the visualizer onto `#app` and kick off the initial session-list fetch.
/// The frontend talks only to the read-only viz server's JSON/raw-file API.
#warnings("-alert_unstable")
fn main {
  let app = @rabbita.new(() => {
    let (model, emit) = @rabbita.create_state_with_init(
      // Route the initial listing through fetch_text so a standalone export
      // answers it from the embedded data map instead of the (absent) server.
      init=emit => {
        (
          RootModel(init_model()),
          @cmd.batch([
            fetch_text(emit, "/api/sessions", result => SessionsFetched(result)),
            install_shortcuts(emit),
            // Subrun chips navigate by writing `#s=…`; turn those hash changes
            // into selections.
            install_hash_navigation(emit),
            // Position tracking: keep `seq=` in the URL hash while scrolling
            // and make step-scrubber segments jump, so a refresh restores the
            // spot.
            @cmd.effect(() => install_position_tracker()),
          ]),
        )
      },
      update=(emit, msg, model : RootModel) => {
        let (cmd, next) = update(emit, msg, model.0)
        (RootModel(next), cmd)
      },
    )
    model.map(model => view(emit, model.0))
  })
  app.mount("app")
}
