// The standing goal's UI: one row above the composer input carrying both
// the goal-editing mode behind `/goal` and the goal the durable `[goal]`
// markers left standing (see `composer_view`). The mirror itself lives on
// `Conversation.goal` and is written only by durable commits/snapshots —
// see `apply_commit` — so nothing here ever claims a goal the engine has
// not persisted.

///|
/// The composer's goal row, riding the same slot as the compaction notice
/// above the input. It says one of three things: that the composer is
/// currently editing the goal (while `/goal` holds it), what the standing
/// goal is otherwise, or nothing at all.
///
/// Both states lead with the bullseye — never the sparkle, which means
/// "model" elsewhere in this app (Settings → Model) and pointed at the
/// wrong subject on a row about the goal.
///
/// The row is *always* in the DOM — collapsed by CSS when it has nothing to
/// say. Appearing and disappearing would shift `composer-inner`'s child
/// index, and index-based vdom diffing would then rebuild the textarea and
/// drop its focus at exactly the moments this row changes: entering goal
/// mode, leaving it, and the durable `[goal]` commit that lands mid-edit.
fn goal_banner(
  dispatch : @cmd.Emit[Msg],
  goal : @transcript.GoalStanding?,
  editing~ : GoalEdit?,
  pending~ : String?,
) -> @html.Html {
  // Editing wins over the mirror: while the composer is the goal's editor,
  // what it is about to write matters more than what stands today, and two
  // stacked goal rows would say the same thing twice.
  if editing is Some(_) {
    // Both states wear the bullseye and align on it, so the row reads as
    // one thing changing rather than two rows swapping. ✕ dismisses either
    // — but it means *stop editing* here and *clear the goal* there, which
    // only the titles separate.
    return @html.div(class="composer-goal editing", [
      @html.span(class="composer-notice-icon", icon(icon_target)),
      // The keys belong to the placeholder, right above the caret that
      // obeys them; saying them here too just doubled the sentence.
      @html.span(
        class="composer-goal-text",
        "You're editing this conversation's standing goal.",
      ),
      @html.button(
        id="goal-cancel",
        class="composer-goal-action",
        type_="button",
        title="Stop editing the standing goal — the goal itself is left alone (Esc)",
        on_click=dispatch(CloseGoalEditor),
        icon(icon_close),
      ),
    ])
  }
  // Sent, not yet confirmed. `agent.goal` returns once the command reaches
  // the engine's stdin, so this waits for the durable marker — and says so,
  // rather than showing a goal the record may never carry.
  if pending is Some(text) {
    return @html.div(class="composer-goal pending", [
      @html.span(class="composer-notice-icon", icon(icon_target)),
      @html.span(
        class="composer-goal-text",
        title=text,
        "Setting goal: \{goal_first_line(text)}",
      ),
    ])
  }
  guard goal is Some(goal) else {
    return @html.div(class="composer-goal hidden", "")
  }
  // The goal at a glance, warning-styled while the agent has durably
  // declared it blocked. The full text (and the blocked reason) ride the
  // tooltip; Edit opens goal mode, ✕ clears the goal outright.
  let (row_class, text, title) = if goal.blocked is Some(reason) {
    (
      "composer-goal blocked",
      "Goal blocked: \{goal_first_line(reason)}",
      "Goal: \{goal.text}\n\nBlocked: \{reason}",
    )
  } else {
    ("composer-goal", "Goal: \{goal_first_line(goal.text)}", goal.text)
  }
  @html.div(class=row_class, [
    @html.span(class="composer-notice-icon", icon(icon_target)),
    @html.span(class="composer-goal-text", title~, text),
    @html.button(
      class="composer-goal-action",
      type_="button",
      title="Edit the standing goal",
      on_click=dispatch(OpenGoalEditor),
      "Edit",
    ),
    @html.button(
      class="composer-goal-action",
      type_="button",
      title="Clear the standing goal",
      on_click=dispatch(ClearGoal),
      icon(icon_close),
    ),
  ])
}

///|
fn goal_first_line(text : String) -> String {
  if text.split_once("\n") is Some((first, _)) {
    first.to_owned()
  } else {
    text
  }
}

///|
/// Composer key handling while editing the goal: Enter sets it, Shift+Enter
/// keeps inserting newlines (goals may span lines), Escape cancels back to
/// the prompt draft.
fn goal_attrs(dispatch : @cmd.Emit[Msg]) -> @html.Attrs {
  @html.Attrs::build().on_keydown(fn(event) {
    match event.key() {
      "Enter" =>
        if !event.shift_key() && !event.is_composing() {
          event.prevent_default()
          dispatch(SubmitGoal)
        } else {
          @cmd.none
        }
      "Escape" => {
        event.prevent_default()
        dispatch(CloseGoalEditor)
      }
      _ => @cmd.none
    }
  })
}

///|
test "the goal slash command opens the editor prefilled from the mirror" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    goal: Some({ text: "ship the feature", blocked: None }),
    task: "/goal",
  })
  let (_, opened) = run_slash_command(dispatch, model, "goal")
  guard opened.active().goal_edit is Some(edit) else {
    fail("the editor should open")
  }
  inspect(edit.draft, content="ship the feature")
  // Whole-draft semantics, like /compact: accepting clears the typed command.
  inspect(opened.active().task, content="")
  assert_true(opened.completion is None)
}

///|
test "submit holds the text until its marker lands" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    goal_edit: Some({ draft: "   " }),
  })
  // A blank draft has nothing to set (the button is disabled; this also
  // catches Enter); goal mode stays open for the user to finish.
  let (_, still_open) = update(dispatch, SubmitGoal, model)
  assert_true(still_open.active().goal_edit is Some(_))
  let (_, edited) = update(dispatch, GoalDraftEdited("ship it"), still_open)
  guard edited.active().goal_edit is Some(edit) else { fail("editor lost") }
  inspect(edit.draft, content="ship it")
  let (_, submitted) = update(dispatch, SubmitGoal, edited)
  assert_true(submitted.active().goal_edit is None)
  // `agent.goal` returning is not persistence, so the text waits for the
  // durable marker rather than being dropped on the send.
  assert_true(submitted.active().goal_pending is Some("ship it"))
  // The mirror is untouched: only the durable `[goal]` commit moves it.
  assert_true(submitted.active().goal is None)
}

///|
test "only the matching set marker settles the pending text" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    goal_pending: Some("ship the feature"),
  })
  fn commit(model, sequence, content) {
    let (_, next) = update_dev(
      dispatch,
      SessionCommitted(
        session="desktop-test",
        sequence~,
        ts=None,
        item=@protocol.RuntimeNotice({ content, }),
      ),
      model,
    )
    next
  }

  // A marker proves the engine is committing, not that this command landed.
  // An earlier set from a second submit, and a block on the goal that still
  // stands, both leave the recovery copy alone — the append it belongs to
  // can still fail.
  let other_set = commit(model, 1, "[goal]\nan earlier goal")
  assert_true(other_set.active().goal_pending is Some("ship the feature"))
  let blocked = commit(other_set, 2, "[goal blocked]\nneeds a decision")
  assert_true(blocked.active().goal_pending is Some("ship the feature"))
  let cleared = commit(blocked, 3, "[goal cleared]")
  assert_true(cleared.active().goal_pending is Some("ship the feature"))
  // Its own set does settle it, and moves the mirror.
  let settled = commit(cleared, 4, "[goal]\nship the feature")
  assert_true(settled.active().goal_pending is None)
  assert_true(
    settled.active().goal is Some({ text: "ship the feature", blocked: None }),
  )
}

///|
test "the row's Cancel leaves the edit and the prompt draft alone" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    task: "half-typed prompt",
    goal_edit: Some({ draft: "a goal being written" }),
  })
  // The row's ✕ and Escape are the same message: leave goal mode, send
  // nothing, and hand the composer back its prompt draft untouched.
  let (_, cancelled) = update(dispatch, CloseGoalEditor, model)
  assert_true(cancelled.active().goal_edit is None)
  inspect(cancelled.active().task, content="half-typed prompt")
  assert_true(cancelled.active().goal is None)
}

///|
test "clear sends from goal mode and from the standing row alike" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    goal_edit: Some({ draft: "" }),
  })
  let (_, cleared) = update(dispatch, ClearGoal, model)
  assert_true(cleared.active().goal_edit is None)
  // The row's ✕ clears with no editor open; the mirror stays untouched until
  // the durable tombstone commits.
  let standing = test_model().replace_conversation({
    ..test_conversation(),
    goal: Some({ text: "ship the feature", blocked: None }),
  })
  let (_, from_row) = update(dispatch, ClearGoal, standing)
  assert_true(from_row.active().goal_edit is None)
  assert_true(from_row.active().goal is Some(_))
}

///|
test "each conversation owns its own goal edit" {
  let dispatch = test_dispatch()
  // An edit left open on one conversation while another is active. Both the
  // clear and a new edit act on what is on screen, and neither can reach the
  // draft waiting next door — the reason the draft lives on the conversation
  // rather than in one model-wide slot.
  let neighbour : Conversation = {
    ..empty_conversation(@interop.ChannelId::Local, "desktop-other"),
    goal: Some({ text: "the visible goal", blocked: None }),
  }
  let model = {
    ..test_model(),
    conversations: [
      {
        ..test_conversation(),
        goal_edit: Some({ draft: "an edit left open next door" }),
      },
      neighbour,
    ],
    active_session: "desktop-other",
  }
  for msg in [ClearGoal, OpenGoalEditor, CloseGoalEditor] {
    let (_, next) = update(dispatch, msg, model)
    guard next.find_conversation(@interop.ChannelId::Local, "desktop-test")
      is Some(hidden) else {
      fail("the neighbour should survive")
    }
    guard hidden.goal_edit is Some(edit) else {
      fail("a neighbour's edit should survive every goal message")
    }
    inspect(edit.draft, content="an edit left open next door")
  }
}

///|
test "goal marker commits write the mirror and render cards" {
  let dispatch = test_dispatch()
  let (_, set) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=1,
      ts=None,
      item=@protocol.RuntimeNotice({ content: "[goal]\nship the feature" }),
    ),
    test_model(),
  )
  guard set.active().goal is Some(goal) else {
    fail("the set marker should write the mirror")
  }
  inspect(goal.text, content="ship the feature")
  assert_true(goal.blocked is None)
  inspect(set.active().messages.length(), content="1")
  let (_, blocked) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=2,
      ts=None,
      item=@protocol.RuntimeNotice({
        content: "[goal blocked]\nneeds a decision",
      }),
    ),
    set,
  )
  guard blocked.active().goal is Some(goal) else {
    fail("a blocked goal keeps standing")
  }
  assert_true(goal.blocked is Some("needs a decision"))
  let (_, cleared) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=3,
      ts=None,
      item=@protocol.RuntimeNotice({ content: "[goal cleared]" }),
    ),
    blocked,
  )
  assert_true(cleared.active().goal is None)
  inspect(cleared.active().messages.length(), content="3")
}

///|
test "a rejected goal request reports it and hands the text back" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    goal_pending: Some("ship the feature"),
  })
  let (_, next) = update_dev(
    dispatch,
    GoalRejected(
      session="desktop-test",
      draft=Some("ship the feature"),
      message="no engine",
    ),
    model,
  )
  inspect(next.active().overlay.length(), content="1")
  // Nothing durable will ever carry this text, so dropping it loses the
  // user's writing for good — a rejected prompt restores its draft too.
  guard next.active().goal_edit is Some(edit) else {
    fail("the goal text should come back")
  }
  inspect(edit.draft, content="ship the feature")
  // Nothing is still in flight once the rejection has settled.
  assert_true(next.active().goal_pending is None)
}

///|
test "a rejected clear has nothing to restore, and never steals goal mode" {
  let dispatch = test_dispatch()
  // A clear carries no draft.
  let (_, cleared) = update_dev(
    dispatch,
    GoalRejected(session="desktop-test", draft=None, message="no engine"),
    test_model(),
  )
  inspect(cleared.active().overlay.length(), content="1")
  assert_true(cleared.active().goal_edit is None)
  // A newer edit belongs to the user, not to this dead request.
  let editing = test_model().replace_conversation({
    ..test_conversation(),
    goal_edit: Some({ draft: "something newer" }),
  })
  let (_, kept) = update_dev(
    dispatch,
    GoalRejected(
      session="desktop-test",
      draft=Some("the request that died"),
      message="no engine",
    ),
    editing,
  )
  guard kept.active().goal_edit is Some(edit) else { fail("editor lost") }
  inspect(edit.draft, content="something newer")
}

///|
test "a goal on an unbound worktree conversation creates the worktree first" {
  let workspace = @interop.ChannelId::Local.test_resource("/proj")
  // Worktree mode chosen, nothing started: the goal has to establish the
  // environment, or the engine spawns in the workspace root and the goal's
  // own durable card retires the mode before the first prompt runs.
  let unbound : Conversation = {
    ..test_conversation(),
    workspace: Some(workspace),
    worktree_mode: true,
  }
  assert_true(unbound.goal_creates_worktree() is Some(_))
  // Already bound: placement is settled, so the goal goes straight out.
  assert_true(
    { ..unbound, worktree: Some("wt-1") }.goal_creates_worktree() is None,
  )
  // Local mode is a deliberate choice to run in the workspace itself.
  assert_true(
    { ..unbound, worktree_mode: false }.goal_creates_worktree() is None,
  )
  // A conversation that has begun cannot still be waiting for placement.
  assert_true(
    {
      ..unbound,
      messages: [{ kind: User, content: "already talking", ts: None }],
    }.goal_creates_worktree()
    is None,
  )
}

///|
test "a fresh conversation survives on its goal draft alone" {
  // `/goal` moves the text out of `task`, so retention must count the goal
  // halves — otherwise activating a neighbour prunes the conversation and
  // takes the only copy of the draft with it.
  let fresh = empty_conversation(@interop.ChannelId::Local, "desktop-fresh")
  assert_true(fresh.draft_empty())
  assert_false(
    { ..fresh, goal_edit: Some({ draft: "still writing" }) }.draft_empty(),
  )
  assert_false(
    { ..fresh, goal_pending: Some("awaiting its marker") }.draft_empty(),
  )
  // A blank editor is not a draft: an untouched `/goal` still lets the husk go.
  assert_true({ ..fresh, goal_edit: Some({ draft: "   " }) }.draft_empty())
  let model = {
    ..test_model(),
    conversations: [
      { ..fresh, goal_edit: Some({ draft: "a goal still being written" }) },
      empty_conversation(@interop.ChannelId::Local, "desktop-other"),
    ],
    active_session: "desktop-fresh",
  }
  let switched = model.activate(@interop.ChannelId::Local, "desktop-other")
  assert_true(
    switched.find_conversation(@interop.ChannelId::Local, "desktop-fresh")
    is Some(_),
  )
}
