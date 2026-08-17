// What the dialog says and which row it points at, read off the values the
// markup is built from. Rendering these to a string is browser-only now —
// rabbita 0.15.1 removed the js-target `render_to_string` — so the wording and
// the seeded ordering are pinned here instead.

///|
test "each provider names its own dialog" {
  let (files_label, files_placeholder, files_group) = Provider::Files.labels()
  assert_eq(files_label, "Search workspace files")
  assert_eq(files_placeholder, "Search files")
  assert_eq(files_group, "Files")
  let (symbol_label, symbol_placeholder, symbol_group) = Provider::Symbols.labels()
  assert_eq(symbol_label, "Search workspace symbols")
  assert_eq(symbol_placeholder, "Search symbols")
  assert_eq(symbol_group, "Symbols")
}

///|
test "an empty list says which phase it is empty in" {
  fn empty(provider : Provider, phase : Phase) -> (String, String) {
    Open::{
      owner: { channel: @interop.ChannelId::Local, session: "desktop-test" },
      root: None,
      value: if provider is Files {
        ""
      } else {
        "#"
      },
      items: [],
      selected: 0,
      phase,
      generation: 1,
    }.empty_state()
  }

  // Still working: the list is busy, not wrong.
  assert_eq(empty(Files, Loading), ("quick-open-empty", "Indexing files…"))
  assert_eq(
    empty(Symbols, Debouncing),
    ("quick-open-empty", "Searching symbols…"),
  )
  // A request that failed is the one empty state carrying an error class.
  assert_eq(
    empty(Files, Failed),
    ("quick-open-empty error", "File search failed"),
  )
  assert_eq(
    empty(Symbols, Failed),
    ("quick-open-empty error", "Symbol search failed"),
  )
  // A finished search with nothing in it is ordinary.
  assert_eq(empty(Files, Ready), ("quick-open-empty", "No files found"))
  assert_eq(empty(Symbols, Ready), ("quick-open-empty", "No symbols found"))
}

///|
test "open editor tabs are offered before the Host index answers" {
  guard @resource.of_path(@interop.ChannelId::Local, "/work/proj") is Some(root) else {
    fail("test resource path was invalid")
  }
  let (_, opened) = State::empty().open(
    @cmd.Emit(_ => @cmd.none),
    Input(
      owner={ channel: @interop.ChannelId::Local, session: "desktop-test" },
      root=Some(root),
      open_files=[Relative("src/open.mbt"), Relative("src/active.mbt")],
      active_file=Some(Relative("src/active.mbt")),
    ),
    Files,
  )
  guard opened.open is Some(run) else { fail("opening must leave a run") }
  // The active file leads, and the leading row is the selected one.
  assert_eq(run.selected, 0)
  assert_eq(run.items.map(item => (item.name(), item.detail())), [
    ("active.mbt", "src/active.mbt"),
    ("open.mbt", "src/open.mbt"),
  ])
}
