// dsh supplies external session facts to the shared composer and interprets
// only its deliberate actions. Editable text stays in the composer component
// instead of being copied into dsh's transcript-bearing State per keystroke.

///|
fn State::composer_identity(self : State) -> @composer.Identity {
  {
    owner: {
      channel: @interop.ChannelId::Local,
      session: self.active_id.unwrap_or("dsh.none"),
    },
    archive_generation: 0,
  }
}

///|
/// Resolve a deliberate mention-chip click against the dsh conversation that
/// still owns the composer entry. The root Desktop page owns Files, so dsh
/// exposes only the validated editor target instead of its internal action.
pub fn State::opened_mention(
  self : State,
  msg : Msg,
) -> (String, @common.Range?, String?)? {
  guard msg is ComposerAction(@composer.MentionOpened(identity~, mention~)) &&
    self.has_active() &&
    self.composer_identity() == identity &&
    @mention_context.target(mention.ref_) is Some(target) else {
    return None
  }
  Some(
    (
      target.file,
      // A draft chip retains the exact selection; the reference target is only
      // the fallback for durable envelopes that predate range preservation.
      if mention.range is Some(_) {
        mention.range
      } else {
        target.range
      },
      target.annotation,
    ),
  )
}

///|
/// Whether this dsh message deliberately opens Files during the root update.
/// The shell uses this only to avoid issuing a duplicate panel activation.
pub fn Msg::opens_editor(self : Msg) -> Bool {
  self is ComposerAction(@composer.MentionOpened(..))
}

///|
/// dsh receives the shared composer's durable text envelope, so an annotation
/// chip by itself is a valid submission even when the textarea is empty.
fn State::submission_empty(self : State) -> Bool {
  @composer.Draft::{ task: self.draft, mentions: self.mentions }
  .prompt()
  .is_empty()
}

///|
/// Project the selected dsh session into the same component contract used by
/// OpenSeek and Codex. dsh accepts one text content item; structured composer
/// chips are encoded into that durable text only at submission time.
pub fn State::composer_input(
  self : State,
  dispatch : @cmd.Emit[Msg],
) -> @composer.Input {
  let context : Array[@html.Html] = []
  let busy = self.busy()
  for pending in self.pending {
    // dsh can run several sessions concurrently. Keep background requests in
    // state for later, but render only cards owned by the selected session.
    if self.active_id == Some(pending.session_id()) {
      context.push(pending.view(dispatch, busy))
    }
  }
  let status : Array[@html.Html] = []
  let model_routable = if self.active_id is Some(session_id) {
    match self.models {
      DshModelsReady(options~, selected~, ..)
      | DshModelsSelecting(options~, selected~, ..) => {
        let model_options : Array[@composer.ModelOption] = options.map(option => {
          value: option.selection.key(),
          label: option.label,
        })
        status.push(
          @composer.ModelSelect::{
            groups: [{ label: "DeepSeek Harness", options: model_options }],
            selected: selected.key(),
            disabled: self.models.busy() || self.busy(),
            change: dispatch.map(value => ModelChanged(value)),
            title: "DeepSeek Harness model",
          }.render(),
        )
      }
      DshModelsIdle | DshModelsLoading(..) => ()
    }
    self.models.routable(session_id)
  } else {
    false
  }
  if self.active_blank() && self.active_workspace_path() is Some(_) {
    status.push(
      @composer.WorktreeControl::{
        choice: self.placement,
        enabled: !self.busy() && !self.is_running(),
        command: dispatch(ToggleWorktreeMode),
        content: @icons.icon(@icons.icon_worktree),
      }.render(),
    )
  }
  let disabled = !(self.connection is DshReady) ||
    !self.has_active() ||
    !model_routable
  let primary_action : @composer.PrimaryAction = if self.is_running() {
    @composer.Running(steer_available=!disabled && !busy, can_stop=!busy)
  } else {
    @composer.Send(available=!disabled && !busy)
  }
  {
    identity: self.composer_identity(),
    draft: { task: self.draft, mentions: self.mentions },
    // dsh exposes only whether the selected conversation is running, not its
    // start time, token usage, or numbered step. Project that exact knowledge
    // into the shared heartbeat instead of inventing finer progress.
    run: if self.is_running() {
      Some({ stage: Working, started_ms: None, tokens: 0 })
    } else {
      None
    },
    goal: { draft: None, standing: None, pending: None },
    slash_commands: [],
    root: None,
    installed_skills: [],
    context_generation: self.selection_generation,
    submission_sequence: self.prompt_generation,
    replacements: [],
    retirements: [],
    file_candidates: [],
    open_files: [],
    active_file: None,
    file_index: @composer.FileIndexEmpty(epoch=0),
    presentation: {
      context,
      status,
      placeholder: if self.has_active() {
        "Ask DeepSeek Harness…"
      } else {
        "Create or select a dsh conversation"
      },
      disabled,
      primary_action,
    },
  }
}

///|
/// Apply only actions issued for the currently selected dsh session. The
/// identity check prevents a delayed DOM command from targeting a session the
/// user selected afterward.
fn State::apply_composer_action(
  self : State,
  dispatch : @cmd.Emit[Msg],
  action : @composer.Action,
) -> (@cmd.Cmd, State) {
  let identity = match action {
    @composer.DraftSubmitted(identity~, ..)
    | @composer.DraftPresenceChanged(identity~, ..)
    | @composer.RootMentionRemoved(identity~, ..)
    | @composer.SlashCommand(identity~, ..)
    | @composer.MentionOpened(identity~, ..)
    | @composer.GoalEditStarted(identity~)
    | @composer.GoalCancelled(identity~)
    | @composer.GoalCleared(identity~)
    | @composer.GoalSubmitted(identity~, ..)
    | @composer.StopRequested(identity~)
    | @composer.FileIndexEnsured(identity~) => identity
  }
  guard self.has_active() && self.composer_identity() == identity else {
    return (@cmd.none, self)
  }
  match action {
    @composer.DraftSubmitted(draft~, ..) =>
      update(dispatch, Send, {
        ..self,
        draft: draft.task,
        mentions: draft.mentions,
      })
    @composer.DraftPresenceChanged(
      present=false,
      cleared_source=Some(source),
      ..
    ) => {
      let draft = if self.draft == source.task { "" } else { self.draft }
      let mentions = if self.mentions == source.mentions {
        []
      } else {
        self.mentions
      }
      let failed_prompts = match self.active_id {
        Some(session_id) =>
          self.failed_prompts.with_draft(session_id, { task: draft, mentions })
        None => self.failed_prompts
      }
      (@cmd.none, { ..self, draft, mentions, failed_prompts })
    }
    @composer.RootMentionRemoved(mention~, ..) => {
      let mentions = self.mentions.filter(existing => {
        existing.ref_ != mention.ref_
      })
      let failed_prompts = match self.active_id {
        Some(session_id) =>
          self.failed_prompts.with_draft(session_id, {
            task: self.draft,
            mentions,
          })
        None => self.failed_prompts
      }
      (@cmd.none, { ..self, mentions, failed_prompts })
    }
    @composer.StopRequested(..) => update(dispatch, Stop, self)
    @composer.DraftPresenceChanged(..)
    | @composer.SlashCommand(..)
    | @composer.MentionOpened(..)
    | @composer.GoalEditStarted(..)
    | @composer.GoalCancelled(..)
    | @composer.GoalCleared(..)
    | @composer.GoalSubmitted(..)
    | @composer.FileIndexEnsured(..) => (@cmd.none, self)
  }
}

///|
/// Add a Viewer selection comment to the active dsh composer as the same
/// structured annotation chip used by the other Desktop conversation types.
/// The textarea remains unchanged; submission encodes the chip into dsh's text
/// content item.
pub fn State::with_editor_comment(
  self : State,
  file : String,
  range : @common.Range,
  comment : String,
  quote : String,
) -> State {
  self.with_annotation({
    ref_: @mention_context.Annotation(
      file~,
      start_line=range.start_line_number,
      end_line=range.end_line_number,
      quote~,
      comment~,
      side=@mention_context.WorkingRevision,
    ),
    range: Some(range),
  })
}

///|
/// Add a full-diff comment while retaining whether its line belongs to the
/// working file or only to the original revision.
pub fn State::with_diff_comment(
  self : State,
  file : String,
  line : Int,
  range : @common.Range?,
  side : @mention_context.AnnotationSide,
  comment : String,
  quote : String,
) -> State {
  self.with_annotation({
    ref_: @mention_context.Annotation(
      file~,
      start_line=line,
      end_line=line,
      quote~,
      comment~,
      side~,
    ),
    range,
  })
}

///|
/// Keep annotation insertion and deduplication private to dsh; root callers
/// can use only the two editor-specific entry points above.
fn State::with_annotation(self : State, mention : @composer.Mention) -> State {
  guard self.has_active() else { return self }
  let draft : @composer.Draft = { task: self.draft, mentions: self.mentions }
  let draft = draft.with_mention(mention)
  let failed_prompts = match self.active_id {
    Some(session_id) => self.failed_prompts.with_draft(session_id, draft)
    None => self.failed_prompts
  }
  { ..self, draft: draft.task, mentions: draft.mentions, failed_prompts }
}

///|
test "dsh projects its selected session into the shared composer" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = {
    ..State(),
    connection: DshReady,
    sessions: [
      {
        id: "session-1",
        title: "Session 1",
        cwd: Some("/work/project"),
        running: false,
        blank: false,
      },
    ],
    active_id: Some("session-1"),
    models: DshModelsReady(
      session_id="session-1",
      options=[
        {
          selection: {
            provider: "deepseek",
            model: "deepseek-chat",
            reasoning_effort: None,
          },
          label: "DeepSeek / Chat",
        },
      ],
      selected={
        provider: "deepseek",
        model: "deepseek-chat",
        reasoning_effort: None,
      },
      routable=true,
    ),
  }
  let input = state.composer_input(dispatch)
  assert_eq(input.identity.owner.session, "session-1")
  assert_eq(input.presentation.placeholder, "Ask DeepSeek Harness…")
  assert_true(
    input.presentation.primary_action is @composer.Send(available=true),
  )
  assert_true(input.slash_commands.is_empty())
  assert_eq(input.presentation.status.length(), 1)
  let annotated = state.with_editor_comment(
    "src/main.mbt",
    @common.Range::Range(5, 1, 6, 3),
    "rename this",
    "fn parse_hover() {",
  )
  let duplicate = annotated.with_editor_comment(
    "src/main.mbt",
    @common.Range::Range(5, 1, 6, 3),
    "rename this",
    "fn parse_hover() {",
  )
  let annotated_input = duplicate.composer_input(dispatch)
  assert_eq(annotated_input.draft.task, "")
  assert_eq(annotated_input.draft.mentions.length(), 1)
  assert_true(
    annotated_input.draft.mentions[0].ref_
    is @mention_context.Annotation(
      file="src/main.mbt",
      start_line=5,
      end_line=6,
      comment="rename this",
      side=@mention_context.WorkingRevision,
      ..
    ),
  )
  let with_diff = duplicate.with_diff_comment(
    "src/main.mbt",
    3,
    None,
    @mention_context.OriginalRevision,
    "keep this removal",
    "obsolete()",
  )
  let diff_input = with_diff.composer_input(dispatch)
  assert_eq(diff_input.draft.mentions.length(), 2)
  assert_true(
    diff_input.draft.mentions[1].ref_
    is @mention_context.Annotation(
      file="src/main.mbt",
      start_line=3,
      end_line=3,
      side=@mention_context.OriginalRevision,
      ..
    ),
  )
  assert_true(diff_input.draft.mentions[1].range is None)
}

///|
test "dsh accepts a shared composer submission only for its active session" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = {
    ..State(),
    connection: DshReady,
    sessions: [
      {
        id: "session-1",
        title: "Session 1",
        cwd: None,
        running: false,
        blank: false,
      },
    ],
    active_id: Some("session-1"),
    models: DshModelsReady(
      session_id="session-1",
      options=[
        {
          selection: {
            provider: "deepseek",
            model: "deepseek-chat",
            reasoning_effort: None,
          },
          label: "DeepSeek / Chat",
        },
      ],
      selected={
        provider: "deepseek",
        model: "deepseek-chat",
        reasoning_effort: None,
      },
      routable=true,
    ),
  }
  let identity = state.composer_identity()
  let exact_range = @common.Range::Range(5, 2, 6, 4)
  guard state.opened_mention(
      Msg::composer_action(
        @composer.MentionOpened(identity~, mention={
          ref_: @mention_context.File(path="src/main.mbt"),
          range: Some(exact_range),
        }),
      ),
    )
    is Some(opened) else {
    fail("expected the active dsh mention to resolve")
  }
  assert_eq(opened.0, "src/main.mbt")
  assert_eq(opened.1, Some(exact_range))
  assert_true(
    Msg::composer_action(
      @composer.MentionOpened(identity~, mention={
        ref_: @mention_context.File(path="src/main.mbt"),
        range: Some(exact_range),
      }),
    ).opens_editor(),
  )
  let (_, submitted) = update(
    dispatch,
    ComposerAction(
      @composer.DraftSubmitted(identity~, draft={ task: "hello", mentions: [] }),
    ),
    state,
  )
  assert_eq(submitted.draft, "hello")
  assert_eq(submitted.prompt_generation, 1)
  assert_eq(submitted.prompt_pending_session, Some("session-1"))
  let stale_identity = {
    ..identity,
    owner: { ..identity.owner, session: "session-2" },
  }
  assert_true(
    state.opened_mention(
      Msg::composer_action(
        @composer.MentionOpened(identity=stale_identity, mention={
          ref_: @mention_context.File(path="src/main.mbt"),
          range: None,
        }),
      ),
    )
    is None,
  )
  let (_, stale) = update(
    dispatch,
    ComposerAction(
      @composer.DraftSubmitted(identity=stale_identity, draft={
        task: "wrong session",
        mentions: [],
      }),
    ),
    state,
  )
  assert_true(stale == state)
  let annotated = state.with_editor_comment(
    "src/main.mbt",
    @common.Range::Range(5, 1, 6, 3),
    "rename this",
    "fn parse_hover() {",
  )
  let mention_draft : @composer.Draft = {
    task: "",
    mentions: annotated.mentions,
  }
  guard @mention_context.parse(mention_draft.prompt()) is Some(encoded) else {
    fail("expected dsh annotation prompt envelope")
  }
  assert_eq(encoded.mentions.length(), 1)
  let (_, mention_submitted) = update(
    dispatch,
    ComposerAction(@composer.DraftSubmitted(identity~, draft=mention_draft)),
    annotated,
  )
  assert_eq(mention_submitted.prompt_generation, 1)
  assert_eq(mention_submitted.prompt_pending_session, Some("session-1"))
  assert_eq(mention_submitted.mentions.length(), 1)
  let (_, settled) = update(
    dispatch,
    Reply(
      kind=DshPromptReply(
        session_id="session-1",
        draft=mention_draft,
        generation=1,
      ),
      value={
        "type": "server-response",
        "rpcId": "prompt-annotation-1",
        "result": { "ok": true, "value": {} },
      },
    ),
    mention_submitted,
  )
  assert_true(settled.mentions.is_empty())
  assert_eq(settled.draft, "")
}
