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
/// Project the selected dsh session into the same component contract used by
/// OpenSeek and Codex. dsh currently accepts plain text only, so completion
/// providers and mention sources are deliberately empty.
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
            options: model_options,
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
    draft: { task: self.draft, mentions: [] },
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
      update(dispatch, Send, { ..self, draft: draft.task })
    @composer.DraftPresenceChanged(
      present=false,
      cleared_source=Some(source),
      ..
    ) =>
      (
        @cmd.none,
        if self.draft == source.task {
          { ..self, draft: "" }
        } else {
          self
        },
      )
    @composer.StopRequested(..) => update(dispatch, Stop, self)
    @composer.DraftPresenceChanged(..)
    | @composer.RootMentionRemoved(..)
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
}
