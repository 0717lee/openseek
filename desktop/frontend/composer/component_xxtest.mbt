///|
fn Input::fixture(task : String) -> Input {
  let owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "composer-test",
  }
  {
    identity: { owner, archive_generation: 0 },
    draft: { task, mentions: [] },
    goal: { draft: None, standing: None, pending: None },
    slash_commands: [],
    root: Some(@common.Uri::file("/workspace")),
    installed_skills: [],
    context_generation: 0,
    submission_sequence: 0,
    replacements: [],
    retirements: [],
    file_candidates: [],
    open_files: [],
    active_file: None,
    file_index: FileIndexReady(epoch=0, truncated=false),
    presentation: {
      context: [],
      status: [],
      placeholder: "Prompt",
      disabled: false,
      primary_action: Send(available=true),
    },
  }
}

///|
fn Msg::test_emit() -> @cmd.Emit[Msg] {
  @cmd.Emit(_ => @cmd.none)
}

///|
fn Action::test_emit() -> @cmd.Emit[Action] {
  @cmd.Emit(_ => @cmd.none)
}

///|
test "typing is local, pure, and idempotent" {
  let input = Input::fixture("")
  let initial = Model(input)
  let (once, _) = initial.update(
    input,
    TextChanged("a local draft"),
    Msg::test_emit(),
    Action::test_emit(),
  )
  let (twice, _) = initial.update(
    input,
    TextChanged("a local draft"),
    Msg::test_emit(),
    Action::test_emit(),
  )
  assert_true(once == twice)
  inspect(input.draft.task, content="")
  inspect(once.active(input).draft.task, content="a local draft")
}

///|
test "each conversation keeps an independent local draft" {
  let first = Input::fixture("")
  let second_owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "composer-second",
  }
  let second = {
    ..first,
    identity: { owner: second_owner, archive_generation: 0 },
  }
  let (with_first, _) = Model(first).update(
    first,
    TextChanged("first draft"),
    Msg::test_emit(),
    Action::test_emit(),
  )
  let (with_both, _) = with_first.update(
    second,
    TextChanged("second draft"),
    Msg::test_emit(),
    Action::test_emit(),
  )
  inspect(with_both.active(first).draft.task, content="first draft")
  inspect(with_both.active(second).draft.task, content="second draft")
}

///|
test "background retirement prevents an old draft from reviving" {
  let input = Input::fixture("")
  let (drafted, _) = Model(input).update(
    input,
    TextChanged("retired draft"),
    Msg::test_emit(),
    Action::test_emit(),
  )
  let retired = { ..input, retirements: [input.identity.owner] }
  let (without_old, _) = drafted.update(
    retired,
    EntriesRetired,
    Msg::test_emit(),
    Action::test_emit(),
  )
  inspect(without_old.active(retired).draft.task, content="")
}

///|
test "queued archive replacements preserve every draft handoff" {
  let input = Input::fixture("")
  let (drafted, _) = Model(input).update(
    input,
    TextChanged("draft through two rotations"),
    Msg::test_emit(),
    Action::test_emit(),
  )
  let first_fresh : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "composer-fresh-one",
  }
  let second_fresh : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "composer-fresh-two",
  }
  let rotated = {
    ..input,
    identity: { owner: second_fresh, archive_generation: 2 },
    replacements: [
      {
        archived: input.identity.owner,
        fresh: first_fresh,
        archive_generation: 1,
      },
      { archived: first_fresh, fresh: second_fresh, archive_generation: 2 },
    ],
    retirements: [input.identity.owner, first_fresh],
  }
  let (moved, _) = drafted.update(
    rotated,
    EntriesTransferred,
    Msg::test_emit(),
    Action::test_emit(),
  )
  let entry = moved.active(rotated)
  inspect(entry.draft.task, content="draft through two rotations")
  assert_true(entry.owner == second_fresh)
  // The moved draft keeps the generation at which it was authored. The root
  // follows later archive facts from that cursor to resolve queued actions.
  inspect(entry.identity().archive_generation, content="0")
}

///|
test "file completion accepts a local candidate inside the component" {
  let input = {
    ..Input::fixture(""),
    file_candidates: [@pathx.Relative("src/main.mbt")],
  }
  let (searching, _) = Model(input).update(
    input,
    TextChanged("Inspect @main"),
    Msg::test_emit(),
    Action::test_emit(),
  )
  let entry = searching.active(input)
  guard entry.completion is Some(menu) else {
    fail("the file token should open completion")
  }
  assert_true(menu.kind is Files)
  assert_false(menu.menu.loading())
  inspect(menu.menu.length(), content="1")
  let (accepted, _) = searching.update(
    input,
    CompletionAccept,
    Msg::test_emit(),
    Action::test_emit(),
  )
  let draft = accepted.active(input).draft
  inspect(draft.task, content="Inspect ")
  assert_true(
    draft.mentions ==
    [{ ref_: @mention_context.File(path="src/main.mbt"), range: None }],
  )
}

///|
test "a symbols reply settles the menu through its declared identity" {
  let input = Input::fixture("")
  let (typing, _) = Model(input).update(
    input,
    TextChanged("inspect #Sy"),
    Msg::test_emit(),
    Action::test_emit(),
  )
  let searching = typing.active(input)
  guard searching.completion is Some(open_menu) else {
    fail("the symbol token should open completion")
  }
  assert_true(open_menu.kind is Symbols)
  assert_true(open_menu.menu.loading())
  let root = @common.Uri::file("/workspace")
  let symbol : @symbols.Symbol = {
    name: "SymbolTable",
    kind: None,
    container: None,
    path: "src/table.mbt",
    range: @common.Range(1, 1, 1, 1),
  }
  let reply = SymbolsLoaded(owner=input.identity.owner, root~, query="Sy", items=[
    symbol,
  ])
  let (settled, _) = typing.update(
    input,
    reply,
    Msg::test_emit(),
    Action::test_emit(),
  )
  let (settled_again, _) = typing.update(
    input,
    reply,
    Msg::test_emit(),
    Action::test_emit(),
  )
  assert_true(settled == settled_again)
  let entry = settled.active(input)
  guard entry.completion is Some(menu) else {
    fail("the settled menu should stay open")
  }
  assert_false(menu.menu.loading())
  inspect(menu.menu.length(), content="1")
}

///|
test "a symbols reply for another root cannot settle the menu" {
  let input = Input::fixture("")
  let (typing, _) = Model(input).update(
    input,
    TextChanged("inspect #Sy"),
    Msg::test_emit(),
    Action::test_emit(),
  )
  let symbol : @symbols.Symbol = {
    name: "SymbolTable",
    kind: None,
    container: None,
    path: "src/table.mbt",
    range: @common.Range(1, 1, 1, 1),
  }
  let (unchanged, _) = typing.update(
    input,
    SymbolsLoaded(
      owner=input.identity.owner,
      root=@common.Uri::file("/elsewhere"),
      query="Sy",
      items=[symbol],
    ),
    Msg::test_emit(),
    Action::test_emit(),
  )
  let entry = unchanged.active(input)
  guard entry.completion is Some(menu) else {
    fail("the menu should stay open and loading")
  }
  assert_true(menu.menu.loading())
  inspect(menu.menu.length(), content="0")
}

///|
test "a context switch drops a late symbols reply instead of reopening" {
  let input = Input::fixture("")
  let (typing, _) = Model(input).update(
    input,
    TextChanged("inspect #Sy"),
    Msg::test_emit(),
    Action::test_emit(),
  )
  let switched = { ..input, context_generation: 1 }
  let (after, _) = typing.update(
    switched,
    SymbolsLoaded(
      owner=input.identity.owner,
      root=@common.Uri::file("/workspace"),
      query="Sy",
      items=[],
    ),
    Msg::test_emit(),
    Action::test_emit(),
  )
  assert_true(after.active(switched).completion is None)
}

///|
test "a remote file reply settles a truncated index menu, stale epochs do not" {
  let input = {
    ..Input::fixture(""),
    file_candidates: [@pathx.Relative("src/local.mbt")],
    file_index: FileIndexReady(epoch=3, truncated=true),
  }
  let (typing, _) = Model(input).update(
    input,
    TextChanged("open @ma"),
    Msg::test_emit(),
    Action::test_emit(),
  )
  let searching = typing.active(input)
  guard searching.completion is Some(open_menu) else {
    fail("the file token should open completion")
  }
  assert_true(open_menu.kind is Files)
  assert_true(open_menu.menu.loading())
  let root = @common.Uri::file("/workspace")
  let (stale, _) = typing.update(
    input,
    FilesLoaded(owner=input.identity.owner, root~, query="ma", epoch=2, files=[
      @pathx.Relative("src/main.mbt"),
    ]),
    Msg::test_emit(),
    Action::test_emit(),
  )
  guard stale.active(input).completion is Some(still_loading) else {
    fail("a stale epoch must not settle the menu")
  }
  assert_true(still_loading.menu.loading())
  let (settled, _) = typing.update(
    input,
    FilesLoaded(owner=input.identity.owner, root~, query="ma", epoch=3, files=[
      @pathx.Relative("src/main.mbt"),
      @pathx.Relative("docs/notes.md"),
    ]),
    Msg::test_emit(),
    Action::test_emit(),
  )
  let entry = settled.active(input)
  guard entry.completion is Some(menu) else {
    fail("the settled menu should stay open")
  }
  assert_false(menu.menu.loading())
  inspect(menu.menu.length(), content="1")
}

///|
test "goal submission acknowledgement preserves the prompt underneath" {
  let prompt = Input::fixture("waiting prompt")
  let goal = { ..prompt, goal: { ..prompt.goal, draft: Some("old goal") } }
  let (edited, _) = Model(goal).update(
    goal,
    TextChanged("new goal"),
    Msg::test_emit(),
    Action::test_emit(),
  )
  let (submitted, _) = edited.update(
    goal,
    SubmitRequested,
    Msg::test_emit(),
    Action::test_emit(),
  )
  let accepted = { ..prompt, submission_sequence: 1 }
  let entry = submitted.active(accepted)
  inspect(entry.draft.task, content="waiting prompt")
  assert_true(entry.goal_draft is None)
  assert_true(entry.pending_submission is None)
}

///|
test "draft prompt encoding belongs to composer" {
  let draft : Draft = {
    task: "inspect this",
    mentions: [
      { ref_: @mention_context.File(path="src/main.mbt"), range: None },
    ],
  }
  assert_true(draft.prompt().contains("<user_mentions>"))
  assert_true(draft.prompt().contains("inspect this"))
}

// The focus-ownership markers the composer renders (`data-focus-owner` /
// `data-focus-target` on `composer-inner`) are browser-only assertions now:
// rabbita 0.15.1 removed the js-target `render_to_string`.

///|
test "a mention-only draft is a submit-ready prompt" {
  let input = {
    ..Input::fixture(""),
    file_candidates: [@pathx.Relative("src/main.mbt")],
  }
  let (searching, _) = Model(input).update(
    input,
    TextChanged("@main"),
    Msg::test_emit(),
    Action::test_emit(),
  )
  let (accepted, _) = searching.update(
    input,
    CompletionAccept,
    Msg::test_emit(),
    Action::test_emit(),
  )
  let (submitted, _) = accepted.update(
    input,
    SubmitRequested,
    Msg::test_emit(),
    Action::test_emit(),
  )
  assert_true(
    submitted.active(input).pending_submission
    is Some(PromptSubmission(sequence_before=_, _)),
  )
}

///|
test "a goal request in flight never strands the row" {
  // A set whose reply was lost and which the engine never appended has no
  // event coming that could retire it. If the row withheld its actions while
  // waiting, that would be a state with no exit; Edit is here, so the user
  // can always overwrite or clear their way out.
  guard GoalInput::{
      draft: None,
      standing: None,
      pending: Some(GoalSetting("ship the feature")),
    }.row()
    is Some((class_, text, title, editable)) else {
    fail("a request in flight must show a row")
  }
  assert_eq(class_, "composer-goal pending")
  assert_eq(text, "Setting goal: ship the feature")
  assert_eq(title, "ship the feature")
  assert_true(editable)
  // A clear has no text to edit into, so it offers the one action that can
  // still end it — sending the clear again.
  guard GoalInput::{ draft: None, standing: None, pending: Some(GoalClearing) }.row()
    is Some((_, clearing, _, clearing_editable)) else {
    fail("a clear in flight must show a row")
  }
  assert_eq(clearing, "Clearing goal…")
  assert_false(clearing_editable)
  // Nothing standing and nothing in flight is the hidden row.
  assert_true(
    GoalInput::{ draft: None, standing: None, pending: None }.row() is None,
  )
}

///|
test "a blocked goal says what stopped it, keeping the goal in its tooltip" {
  guard GoalInput::{
      draft: None,
      standing: Some({
        text: "ship the feature",
        blocked: Some("upstream API is down"),
      }),
      pending: None,
    }.row()
    is Some((class_, text, title, editable)) else {
    fail("a standing goal must show a row")
  }
  assert_eq(class_, "composer-goal blocked")
  assert_eq(text, "Goal blocked: upstream API is down")
  assert_eq(title, "Goal: ship the feature\n\nBlocked: upstream API is down")
  assert_true(editable)
  // Only the first line rides the row; the whole wording stays in the tooltip.
  guard GoalInput::{
      draft: None,
      standing: Some({
        text: "ship the feature\nwith tests passing",
        blocked: None,
      }),
      pending: None,
    }.row()
    is Some((plain_class, plain_text, plain_title, _)) else {
    fail("a standing goal must show a row")
  }
  assert_eq(plain_class, "composer-goal")
  assert_eq(plain_text, "Goal: ship the feature")
  assert_eq(plain_title, "ship the feature\nwith tests passing")
}
