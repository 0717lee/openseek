///|
/// Mount the visualizer onto `#app` and kick off the initial session-list fetch.
/// The frontend talks only to the read-only viz server's JSON/raw-file API.
#warnings("-alert_unstable")
fn main {
  let (emit, app_cell) = @rabbita.cell_with_emit(
    model=init_model(),
    update~,
    view~,
  )
  let app = @rabbita.new(app_cell)
  // Route the initial listing through fetch_text so a standalone export answers
  // it from the embedded data map instead of the (absent) server.
  app.with_init(
    @cmd.batch([
      fetch_text(emit, "/api/sessions", result => SessionsFetched(result)),
      install_shortcuts(emit),
      // Subrun chips navigate by writing `#s=…`; turn those hash changes
      // into selections.
      install_hash_navigation(emit),
      // Position tracking: keep `seq=` in the URL hash while scrolling and
      // make step-scrubber segments jump, so a refresh restores the spot.
      @cmd.effect(() => install_position_tracker()),
    ]),
  )
  app.mount("app")
}
