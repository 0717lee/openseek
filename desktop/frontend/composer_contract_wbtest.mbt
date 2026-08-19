///|
test "composer input is a projection instead of the root model" {
  let mention : Mention = { ref_: Skill(name="review"), range: None }
  let model = test_model().replace_conversation({
    ..test_conversation(),
    task: "local draft",
    mentions: [mention],
  })
  let input = model.composer_input(test_dispatch())
  inspect(input.identity.owner.session, content="desktop-test")
  inspect(input.draft.task, content="local draft")
  assert_true(input.draft.mentions == [mention])
  assert_eq(input.identity.archive_generation, 0)
}

///|
#warnings("-alert_unstable")
test "the composer docks the turn's heartbeat only while one is open" {
  let running = running_model()
  guard running.active_conversation() is Some(conv) else {
    fail("expected a running conversation")
  }
  let idle = running.replace_conversation({
    ..conv,
    run: NoRun(ended=None),
    run_started_ms: None,
  })
  let context_of = (model : Model) => {
    model.composer_input(test_dispatch()).presentation.context
  }
  // The slot is permanent, its contents are not. `context` is diffed by
  // position, so a row that came and went on every run start and end would
  // shift the goal row below it and rebuild that element twice a turn.
  assert_eq(context_of(running).length(), context_of(idle).length())
  let markup_of = (model : Model) => {
    @rabbita.render_to_string(() => {
      @rabbita.Val::constant(@html.div(class="probe", context_of(model)))
    })
  }
  let running_markup = markup_of(running)
  assert_true(running_markup.contains("composer-running-mark"))
  assert_true(running_markup.contains("Thinking…"))
  // Idle keeps the element and empties it — `.composer-running:empty` is what
  // takes it off screen, so the contents must be gone, not merely hidden.
  let idle_markup = markup_of(idle)
  assert_true(idle_markup.contains("composer-running"))
  assert_false(idle_markup.contains("composer-running-mark"))
  assert_false(idle_markup.contains("Thinking…"))
}

///|
test "composer submission stays bound to its originating conversation" {
  let origin = test_conversation()
  let visible = empty_conversation(
    @interop.ChannelId::Local,
    "visible-session",
    @interop.ChannelId::Local.test_project(),
  )
  let model = {
    ..test_model(),
    active_session: visible.session_id,
    conversations: [origin, visible],
  }
  let identity : @composer.Identity = {
    owner: { channel: @interop.ChannelId::Local, session: origin.session_id },
    archive_generation: 0,
  }
  let (_, submitted) = update(
    test_dispatch(),
    ComposerAction(
      @composer.DraftSubmitted(identity~, draft={
        task: "send to origin",
        mentions: [],
      }),
    ),
    model,
  )
  // Running the root operation may temporarily select the owner, but the
  // user's visible navigation is restored before the action returns.
  inspect(submitted.active_session, content="visible-session")
  guard submitted.find_conversation(
      @interop.ChannelId::Local,
      origin.session_id,
    )
    is Some(origin_after) else {
    fail("the originating conversation disappeared")
  }
  guard submitted.find_conversation(
      @interop.ChannelId::Local,
      visible.session_id,
    )
    is Some(visible_after) else {
    fail("the visible conversation disappeared")
  }
  assert_true(origin_after.run is Starting(..))
  assert_false(visible_after.run is Starting(..))
}

///|
test "annotation-only composer submission starts its conversation" {
  let model = test_model()
  let identity : @composer.Identity = {
    owner: {
      channel: @interop.ChannelId::Local,
      session: model.active().session_id,
    },
    archive_generation: 0,
  }
  let mention : Mention = {
    ref_: @mention_context.Annotation(
      file="bench/bench.mbt",
      start_line=69,
      end_line=69,
      quote="bench()",
      comment="inspect this selection",
      side=@mention_context.WorkingRevision,
    ),
    range: Some(@common.Range::Range(69, 1, 69, 1)),
  }
  let (_, submitted) = update(
    test_dispatch(),
    ComposerAction(
      @composer.DraftSubmitted(identity~, draft={
        task: "",
        mentions: [mention],
      }),
    ),
    model,
  )
  assert_true(submitted.active().run is Starting(..))
  assert_true(submitted.active().task.is_empty())
  assert_true(submitted.active().mentions.is_empty())
  guard submitted.active().input_ledger is [pending] else {
    fail("expected the annotation-only submission in the input ledger")
  }
  assert_true(pending.content.contains("<user_mentions>"))
  assert_true(pending.content.contains("bench/bench.mbt"))
  assert_true(pending.mentions == [mention])
}

///|
test "archive cursor separates transferred actions from a reopened id" {
  let archived : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "desktop-test",
  }
  let fresh : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "archive-replacement",
  }
  let reopened = test_conversation()
  let replacement = empty_conversation(
    fresh.channel,
    fresh.session,
    fresh.channel.test_project(),
  )
  let model = {
    ..test_model(),
    conversations: [reopened, replacement],
    composer_entry_retirements: [archived],
    composer_entry_replacements: [{ archived, fresh, archive_generation: 1 }],
  }
  let old_identity : @composer.Identity = {
    owner: archived,
    archive_generation: 0,
  }
  let reopened_identity : @composer.Identity = {
    owner: archived,
    archive_generation: 1,
  }
  guard model.conversation_for_composer_action(old_identity) is Some(old) else {
    fail("the old entry should follow its recorded replacement")
  }
  guard model.conversation_for_composer_action(reopened_identity) is Some(new) else {
    fail("the reopened entry should resolve to the reused id")
  }
  inspect(old.session_id, content="archive-replacement")
  inspect(new.session_id, content="desktop-test")
}

///|
test "a background retirement expires old actions without poisoning a reopened id" {
  let owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "desktop-test",
  }
  let model = {
    ..test_model(),
    composer_entry_retirements: [owner],
    composer_entry_replacements: [],
  }
  assert_true(
    model.conversation_for_composer_action({ owner, archive_generation: 0 })
    is None,
  )
  assert_true(
    model.conversation_for_composer_action({ owner, archive_generation: 1 })
    is Some(_),
  )
}
