// The palette's contract as the shell sees it: what it accepts and what makes
// it close. Nothing here reads inside `State` — a run is built by driving the
// same entry points `frontend` drives.
//
// What it *draws* is browser-only now: rabbita 0.15.1 removed the js-target
// `render_to_string`. The wording and row ordering moved to `view_wbtest.mbt`,
// which reads the values the markup is built from; the focus-ownership
// invariant over rendered form elements has no counterpart outside a browser.

///|
fn emit() -> @cmd.Emit[@quick_open.Msg] {
  @cmd.Emit(_ => @cmd.none)
}

///|
fn owner() -> @interop.ConversationKey {
  { channel: @interop.ChannelId::Local, session: "desktop-test" }
}

///|
fn workspace_root() -> @common.Uri raise {
  guard @resource.of_path(@interop.ChannelId::Local, "/work/proj")
    is Some(resource) else {
    fail("test resource path was invalid")
  }
  resource
}

///|
fn input(
  open_files? : Array[@pathx.Relative] = [],
  active_file? : @pathx.Relative,
) -> @quick_open.Input raise {
  @quick_open.Input(
    owner=owner(),
    root=Some(workspace_root()),
    open_files~,
    active_file~,
  )
}

///|
/// A palette showing one workspace symbol. `SymbolsLoaded` carries the
/// generation its request was minted with; standing in for the effect layer
/// means minting it here too, and a run opened out of `State::empty` is the
/// first, so it is generation 1.
fn symbol_run(name : String, path : String) -> @quick_open.State raise {
  let input = input()
  let (_, opened) = @quick_open.State::empty().open(
    emit(),
    input,
    @quick_open.Symbols,
  )
  let (_, ready, _) = opened.handle(
    emit(),
    @quick_open.SymbolsLoaded(owner=owner(), query="", generation=1, items=[
      {
        name,
        kind: Some(12),
        container: Some("Parser"),
        path,
        range: @common.Range::Range(5, 2, 5, 13),
      },
    ]),
    input,
  )
  ready
}

///|
test "opening and closing are the palette's only two states" {
  assert_false(@quick_open.State::empty().is_open())
  let (_, files) = @quick_open.State::empty().open(
    emit(),
    input(),
    @quick_open.Files,
  )
  assert_true(files.is_open())
  let (_, symbols) = @quick_open.State::empty().open(
    emit(),
    input(),
    @quick_open.Symbols,
  )
  assert_true(symbols.is_open())
}

///|
test "accepting a row closes the palette and hands back its editor target" {
  let ready = symbol_run("parse_hover", "src/main.mbt")
  let (_, accepted, target) = ready.handle(emit(), @quick_open.Pick(0), input())
  assert_false(accepted.is_open())
  assert_eq(
    target,
    Some({
      path: "src/main.mbt",
      range: Some(@common.Range::Range(5, 2, 5, 13)),
    }),
  )
  // A file row opens without a range: the whole document is the destination.
  let (_, files) = @quick_open.State::empty().open(
    emit(),
    input(open_files=[Relative("src/open.mbt")]),
    @quick_open.Files,
  )
  let (_, _, file_target) = files.handle(emit(), @quick_open.Pick(0), input())
  assert_eq(file_target, Some({ path: "src/open.mbt", range: None }))
}

///|
test "accepting nothing is not an accept" {
  let (_, opened) = @quick_open.State::empty().open(
    emit(),
    input(),
    @quick_open.Symbols,
  )
  let (_, unchanged, target) = opened.handle(
    emit(),
    @quick_open.Pick(0),
    input(),
  )
  assert_eq(target, None)
  assert_true(unchanged == opened)
}

///|
test "selection wraps in both directions" {
  let ready = symbol_run("parse_hover", "src/main.mbt")
  // One row, so either direction returns to it — the run is its own neighbour
  // in both directions and neither move can leave it.
  let (_, up, _) = ready.handle(emit(), @quick_open.Move(-1), input())
  assert_true(up == ready)
  let (_, down, _) = up.handle(emit(), @quick_open.Move(1), input())
  assert_true(down == up)
}

///|
test "dismissing closes the palette" {
  let (_, opened) = @quick_open.State::empty().open(
    emit(),
    input(),
    @quick_open.Files,
  )
  let (_, dismissed, _) = opened.handle(emit(), @quick_open.Dismiss, input())
  assert_false(dismissed.is_open())
}

///|
test "a conversation switch retires the run that opened before it" {
  let (_, opened) = @quick_open.State::empty().open(
    emit(),
    input(),
    @quick_open.Files,
  )
  let elsewhere = @quick_open.Input(
    owner={ channel: @interop.ChannelId::Local, session: "desktop-second" },
    root=Some(workspace_root()),
    open_files=[],
    active_file=None,
  )
  let (_, switched) = opened.reconcile(emit(), elsewhere)
  assert_false(switched.is_open())
  // The same conversation reconciles to a no-op, however often it is asked.
  let (_, settled) = opened.reconcile(emit(), input())
  assert_true(settled == opened)
}
