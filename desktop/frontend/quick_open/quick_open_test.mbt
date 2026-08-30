// The palette's contract as the shell sees it: what it draws, what it accepts,
// and what makes it close. Nothing here reads inside `State` — a run is built
// by driving the same entry points `frontend` drives.

///|
fn emit() -> @cmd.Emit[@quick_open.Msg] {
  @cmd.Emit(_ => @cmd.none)
}

///|
fn owner() -> @interop.ConversationKey {
  { channel: @interop.ChannelId::Local, session: "desktop-test", }
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
/// The palette as the browser would see it. `component` is the only rendering
/// entry the shell has, so the tests use it too.
#warnings("-alert_unstable")
fn markup(state : @quick_open.State) -> String {
  @rabbita.render_to_string(() => {
    @quick_open.component(@rabbita.Val::constant(state), emit())
  })
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
        range: @common.Range(5, 2, 5, 13),
      },
    ]),
    input,
  )
  ready
}

///|
test "a closed palette draws nothing at all" {
  let state = @quick_open.State::empty()
  assert_false(state.is_open())
  assert_false(markup(state).contains("quick-open-dialog"))
}

///|
test "each provider names itself in the dialog it opens" {
  let (_, files) = @quick_open.State::empty().open(
    emit(),
    input(),
    @quick_open.Files,
  )
  assert_true(files.is_open())
  let files_markup = markup(files)
  assert_true(files_markup.contains("Search workspace files"))
  assert_true(files_markup.contains("Search files"))
  assert_true(files_markup.contains("Indexing files…"))
  let (_, symbols) = @quick_open.State::empty().open(
    emit(),
    input(),
    @quick_open.Symbols,
  )
  let symbols_markup = markup(symbols)
  assert_true(symbols_markup.contains("Search workspace symbols"))
  assert_true(symbols_markup.contains("Searching symbols…"))
}

///|
test "open editor tabs are offered before the Host index answers" {
  let (_, opened) = @quick_open.State::empty().open(
    emit(),
    input(
      open_files=[Relative("src/open.mbt"), Relative("src/active.mbt")],
      active_file=Relative("src/active.mbt"),
    ),
    @quick_open.Files,
  )
  let rendered = markup(opened)
  assert_true(rendered.contains("src/open.mbt"))
  // The active file leads, and the leading row is the selected one.
  assert_true(
    rendered.contains(
      "<div id=\"quick-open-row-0\" role=\"option\" aria-selected=\"true\" class=\"quick-open-row selected\"><span aria-hidden=\"true\" class=\"quick-open-kind codicon codicon-symbol-file\"></span><div class=\"quick-open-row-text\"><div class=\"quick-open-name\">active.mbt</div><div class=\"quick-open-detail\">src/active.mbt</div>",
    ),
  )
}

///|
test "accepting a row closes the palette and hands back its editor target" {
  let ready = symbol_run("parse_hover", "src/main.mbt")
  assert_true(markup(ready).contains("parse_hover"))
  let (_, accepted, target) = ready.handle(emit(), @quick_open.Pick(0), input())
  assert_false(accepted.is_open())
  assert_eq(
    target,
    Some({ path: "src/main.mbt", range: Some(@common.Range(5, 2, 5, 13)), }),
  )
  // A file row opens without a range: the whole document is the destination.
  let (_, files) = @quick_open.State::empty().open(
    emit(),
    input(open_files=[Relative("src/open.mbt")]),
    @quick_open.Files,
  )
  let (_, _, file_target) = files.handle(emit(), @quick_open.Pick(0), input())
  assert_eq(file_target, Some({ path: "src/open.mbt", range: None, }))
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
  let (_, up, _) = ready.handle(emit(), @quick_open.Move(-1), input())
  // One row, so either direction returns to it and it stays selected.
  assert_true(markup(up).contains("quick-open-row selected"))
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
    owner={ channel: @interop.ChannelId::Local, session: "desktop-second", },
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

///|
#warnings("-alert_unstable")
test "the palette keeps its separator neutral while owning input focus" {
  let (_, opened) = @quick_open.State::empty().open(
    emit(),
    input(),
    @quick_open.Files,
  )
  let rendered = markup(opened)
  // The wrapper's bottom border is a structural separator, not a focus ring.
  assert_true(rendered.contains("<div class=\"quick-open-input-wrap\">"))
  assert_true(rendered.contains("data-focus-owner=\"\""))
  assert_false(rendered.contains("data-focus-target=\"\""))
  for tag in ["<input", "<textarea", "<select"] {
    let parts = rendered.split(tag).collect()
    for index, part in parts {
      if index > 0 {
        guard part.split_once(">") is Some((opening, _)) else {
          fail("unterminated form element in rendered markup")
        }
        assert_true(
          opening.contains("data-focus-owner") ||
          opening.contains("data-focus-target"),
        )
      }
    }
  }
}
