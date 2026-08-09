// The standing goal's UI: one row above the composer input carrying both
// the goal-editing mode behind `/goal` and the goal the durable `[goal]`
// markers left standing (see `composer_view`). The mirror itself lives on
// `Conversation.goal` and is written only by durable commits/snapshots —
// see `apply_commit` — so nothing here ever claims a goal the engine has
// not persisted.

///|
/// The composer's goal row, riding the same slot as the compaction notice
/// above the input. It says one of four things, in this order: that the
/// composer is editing the goal (while `/goal` holds it), that a command is
/// waiting for its marker, what the standing goal is, or nothing at all.
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
  pending~ : GoalRequest?,
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
  //
  // It keeps Edit and ✕. Withholding them reads as the safer choice — a
  // second command over the first only earns the host's `GoalPending`
  // refusal — but it makes this row a state the user cannot leave except by
  // an event that, for a command whose reply was lost and which the engine
  // never appended, does not exist. A row that can only be exited from
  // outside is a wedge waiting for the one delivery that goes wrong; the
  // duplicate it guards against is a notice, which is the smaller harm and
  // the one the host is already positioned to report.
  let (row_class, text, title, editable) = if pending is Some(request) {
    match request {
      Setting(text) =>
        (
          "composer-goal pending",
          "Setting goal: \{goal_first_line(text)}",
          text,
          true,
        )
      Clearing =>
        (
          "composer-goal pending", "Clearing goal…", "Waiting for the engine to record it",
          false,
        )
    }
  } else {
    guard goal is Some(goal) else {
      return @html.div(class="composer-goal hidden", "")
    }
    // The goal at a glance, warning-styled while the agent has durably
    // declared it blocked. The full text (and the blocked reason) ride the
    // tooltip; Edit opens goal mode, ✕ clears the goal outright.
    if goal.blocked is Some(reason) {
      (
        "composer-goal blocked",
        "Goal blocked: \{goal_first_line(reason)}",
        "Goal: \{goal.text}\n\nBlocked: \{reason}",
        true,
      )
    } else {
      ("composer-goal", "Goal: \{goal_first_line(goal.text)}", goal.text, true)
    }
  }
  // A clear in flight has no text to edit into; every other row does.
  let edit : Array[@html.Html] = if editable {
    [
      @html.button(
        class="composer-goal-action",
        type_="button",
        title="Edit the standing goal",
        on_click=dispatch(OpenGoalEditor),
        "Edit",
      ),
    ]
  } else {
    []
  }
  @html.div(
    class=row_class,
    [
      @html.span(class="composer-notice-icon", icon(icon_target)),
      @html.span(class="composer-goal-text", title~, text),
      ..edit,
      @html.button(
        class="composer-goal-action",
        type_="button",
        title="Clear the standing goal",
        on_click=dispatch(ClearGoal),
        icon(icon_close),
      ),
    ],
  )
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
test "the row's Edit takes the prompt's menu down with it" {
  let dispatch = test_dispatch()
  let conv : Conversation = {
    ..test_conversation(),
    goal: Some({ text: "ship the feature", blocked: None }),
    task: "/",
  }
  // The `/` menu belongs to the prompt draft. A goal draft has no slash
  // commands to offer, so leaving it up would let a stale row replace the
  // goal being written — or run something else entirely.
  guard compute_completion(conv.task, [], empty_symbol_cache(), {
      channel: conv.device,
      session: conv.session_id,
    })
    is Some(menu) else {
    fail("the slash menu should be open")
  }
  let model = {
    ..test_model().replace_conversation(conv),
    completion: Some(menu),
  }
  let (_, editing) = update(dispatch, OpenGoalEditor, model)
  assert_true(editing.active().goal_edit is Some(_))
  assert_true(editing.completion is None)
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
  assert_true(submitted.active().goal_pending is Some(Setting("ship it")))
  // The mirror is untouched: only the durable `[goal]` commit moves it.
  assert_true(submitted.active().goal is None)
}

///|
test "only the matching set marker settles the pending text" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    goal_pending: Some(Setting("ship the feature")),
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
  assert_true(
    other_set.active().goal_pending is Some(Setting("ship the feature")),
  )
  let blocked = commit(other_set, 2, "[goal blocked]\nneeds a decision")
  assert_true(
    blocked.active().goal_pending is Some(Setting("ship the feature")),
  )
  let cleared = commit(blocked, 3, "[goal cleared]")
  assert_true(
    cleared.active().goal_pending is Some(Setting("ship the feature")),
  )
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
  // The clear is in flight, so the row stops offering Edit and ✕ — the goal
  // is still mirrored underneath it, and a second command sent over this one
  // only earns the host's `GoalPending` refusal.
  assert_true(from_row.active().goal_pending is Some(Clearing))
}

///|
test "a clear waits for its tombstone, not for any goal marker" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    goal: Some({ text: "ship the feature", blocked: None }),
    goal_pending: Some(Clearing),
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

  // Someone else's set, and a block on the goal this clear is removing,
  // both leave it in flight: neither is the tombstone it asked for.
  let other = commit(model, 1, "[goal]\nsomething else")
  assert_true(other.active().goal_pending is Some(Clearing))
  let blocked = commit(other, 2, "[goal blocked]\nneeds a decision")
  assert_true(blocked.active().goal_pending is Some(Clearing))
  // The tombstone settles it, and the mirror empties with it.
  let settled = commit(blocked, 3, "[goal cleared]")
  assert_true(settled.active().goal_pending is None)
  assert_true(settled.active().goal is None)
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
    goal_pending: Some(Setting("ship the feature")),
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
#warnings("-alert_unstable")
test "a request in flight never strands the row" {
  let dispatch = test_dispatch()
  // A set whose reply was lost and which the engine never appended has no
  // event coming that could retire it. If the row withheld its actions while
  // waiting, that would be a state with no exit; both are here, so the user
  // can always overwrite or clear their way out.
  let setting = @rabbita.render_to_string(() => {
    @rabbita.Val::constant(
      goal_banner(
        dispatch,
        None,
        editing=None,
        pending=Some(Setting("ship the feature")),
      ),
    )
  })
  assert_true(setting.contains("Setting goal: ship the feature"))
  assert_true(setting.contains(">Edit</button>"))
  inspect(setting.split("composer-goal-action").count(), content="3")
  // A clear has no text to edit into, so it offers the one action that can
  // still end it — sending the clear again.
  let clearing = @rabbita.render_to_string(() => {
    @rabbita.Val::constant(
      goal_banner(dispatch, None, editing=None, pending=Some(Clearing)),
    )
  })
  assert_true(clearing.contains("Clearing goal…"))
  assert_false(clearing.contains(">Edit</button>"))
  inspect(clearing.split("composer-goal-action").count(), content="2")
}

///|
test "the editor opens on the newest text, not on the retired one" {
  // Mid-flight, the mirror still holds what the set is replacing. Seeding
  // from it would silently revert the user's own sent text.
  let conv : Conversation = {
    ..test_conversation(),
    goal: Some({ text: "the old goal", blocked: None }),
    goal_pending: Some(Setting("the goal just sent")),
  }
  inspect(conv.goal_draft_seed(), content="the goal just sent")
  inspect(
    { ..conv, goal_pending: Some(Clearing) }.goal_draft_seed(),
    content="",
  )
  inspect(
    { ..conv, goal_pending: None }.goal_draft_seed(),
    content="the old goal",
  )
  let dispatch = test_dispatch()
  let (_, opened) = update(
    dispatch,
    OpenGoalEditor,
    test_model().replace_conversation(conv),
  )
  guard opened.active().goal_edit is Some(edit) else { fail("editor lost") }
  inspect(edit.draft, content="the goal just sent")
}

///|
test "re-asserting a blocked goal waits for its own marker" {
  let dispatch = test_dispatch()
  // Edit on a blocked goal seeds from the mirror, so resubmitting unchanged
  // is the ordinary way to re-assert one. The record already spells that
  // text, and a set clears the block — so matching on text alone would let
  // the goal being replaced stand in for its replacement, and the next
  // durable item of any kind would retire the request and its recovery copy.
  let model = test_model().replace_conversation({
    ..test_conversation(),
    goal: Some({ text: "ship the feature", blocked: Some("needs a decision") }),
    goal_pending: Some(Setting("ship the feature")),
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

  let unrelated = commit(model, 1, "just some runtime notice")
  assert_true(
    unrelated.active().goal_pending is Some(Setting("ship the feature")),
  )
  // Its own marker is what unblocks it, and that is the state it was waiting
  // for.
  let settled = commit(unrelated, 2, "[goal]\nship the feature")
  assert_true(settled.active().goal_pending is None)
  assert_true(
    settled.active().goal is Some({ text: "ship the feature", blocked: None }),
  )
}

///|
test "a request in flight is reason enough to re-read the record" {
  // An otherwise-empty conversation has nothing else worth reloading for, so
  // without this the reconnect that follows a lost reply would never ask the
  // record the one question the transport could not answer.
  let fresh = empty_conversation(@interop.ChannelId::Local, "desktop-fresh")
  let model = test_model()
  assert_false(model.can_reload_transcript(fresh))
  assert_true(
    model.can_reload_transcript({
      ..fresh,
      goal_pending: Some(Setting("ship the feature")),
    }),
  )
  assert_true(
    model.can_reload_transcript({ ..fresh, goal_pending: Some(Clearing) }),
  )
  // The reconnect's own load can race persistence and come back empty. The
  // session list arriving is later proof the record exists, and that retry
  // gates on the same predicate — so a pending goal earns it too.
  let dispatch = test_dispatch()
  let (_, empty) = update_dev(
    dispatch,
    SessionRefreshed(
      goal=None,
      session="desktop-test",
      items=[],
      watermark=0,
      event_boundaries=[],
      generation=1,
    ),
    {
      ..test_model().replace_conversation({
        ..test_conversation(),
        goal_pending: Some(Setting("ship the feature")),
        sync: test_reloading([]),
      }),
      transcript_request_generation: 1,
    },
  )
  assert_true(empty.active().sync is Synced)
  assert_true(empty.active().goal_pending is Some(_))
  let (_, proved) = update(
    dispatch,
    sessions_loaded([
      {
        id: "desktop-test",
        title: Some("persisted"),
        workspace: None,
        workspace_name: "",
      },
    ]),
    empty,
  )
  guard proved.active().sync is Reloading(generation=2, ..) else {
    fail("durable session-list proof did not retry the pending goal")
  }
}

///|
test "a dead request cannot retire the one that replaced it" {
  let dispatch = test_dispatch()
  // The row keeps its actions while a command is out, so a second set can go
  // over the first. When the first is then refused, retiring "whatever is
  // pending" would drop the second — its marker would arrive with nothing
  // waiting for it, and its text would be held nowhere.
  let model = test_model().replace_conversation({
    ..test_conversation(),
    goal_pending: Some(Setting("the second goal")),
  })
  let (_, next) = update_dev(
    dispatch,
    GoalRejected(
      session="desktop-test",
      draft=Some("the first goal"),
      message="a goal command is already in flight",
    ),
    model,
  )
  inspect(next.active().overlay.length(), content="1")
  assert_true(next.active().goal_pending is Some(Setting("the second goal")))
  // Nor does the superseded text come back: the user replaced it themselves,
  // so restoring it would read as the goal they are actually setting failing.
  assert_true(next.active().goal_edit is None)
  // Its own rejection does retire it, and hands its text back.
  let (_, own) = update_dev(
    dispatch,
    GoalRejected(
      session="desktop-test",
      draft=Some("the second goal"),
      message="no engine",
    ),
    model,
  )
  assert_true(own.active().goal_pending is None)
  guard own.active().goal_edit is Some(edit) else { fail("the text is lost") }
  inspect(edit.draft, content="the second goal")
}

///|
test "an unconfirmed delivery keeps waiting instead of handing the text back" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    goal_pending: Some(Setting("ship the feature")),
  })
  // The socket dropped; the host may have taken the command already. Saying
  // "rejected" here would reopen the editor over a goal the record can still
  // be about to carry, and the resend that invites races its own marker.
  let (_, next) = update_dev(
    dispatch,
    GoalUndelivered(
      session="desktop-test",
      draft=Some("ship the feature"),
      message="bridge unavailable",
    ),
    model,
  )
  inspect(next.active().overlay.length(), content="1")
  assert_true(next.active().goal_edit is None)
  assert_true(next.active().goal_pending is Some(Setting("ship the feature")))
  // The writing is not lost either way — it rides the notice, the way an
  // unconfirmed prompt's does.
  guard next.active().overlay.last() is Some(notice) else {
    fail("the failure should be reported")
  }
  assert_true(notice.content.has_suffix("ship the feature"))
}

///|
test "a reload settles a request the transport never answered" {
  let dispatch = test_dispatch()
  // Sent, unanswered, and then the connection came back. The snapshot is a
  // complete durable read: it can say what the reply could not.
  let model = test_model().replace_conversation({
    ..test_conversation(),
    goal_pending: Some(Setting("ship the feature")),
    sync: test_reloading([]),
  })
  fn refresh(model, goal) {
    let (_, next) = update_dev(
      dispatch,
      SessionRefreshed(
        goal~,
        session="desktop-test",
        items=[],
        watermark=1,
        event_boundaries=[],
        generation=1,
      ),
      model,
    )
    next
  }

  // A record that does not carry it settles nothing: the append may still be
  // queued behind this read.
  let absent = refresh(model, None)
  assert_true(absent.active().goal_pending is Some(Setting("ship the feature")))
  let landed = refresh(
    {
      ..absent,
      conversations: [{ ..absent.active(), sync: test_reloading([]) }],
    },
    Some({ text: "ship the feature", blocked: None }),
  )
  assert_true(landed.active().goal_pending is None)
  assert_true(landed.active().goal is Some(_))
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
    { ..fresh, goal_pending: Some(Setting("awaiting its marker")) }.draft_empty(),
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
