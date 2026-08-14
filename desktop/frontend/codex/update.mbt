// Codex's complete update boundary. The OpenSeek shell supplies only the
// focused host channel and its external-link command; every app-server state
// transition remains inside this package.

///|
pub fn update(
  dispatch : @cmd.Emit[Msg],
  msg : Msg,
  state : State,
  channel : @interop.ChannelId,
  open_external : (String) -> @cmd.Cmd,
) -> (@cmd.Cmd, State) {
  match msg {
    Refresh =>
      (state.refresh(dispatch, channel), { ..state, loading: true, notice: "" })
    PollActivity => (state.poll_activity(dispatch, channel), state)
    DraftChanged(value) => state.change_draft(dispatch, channel, value)
    CompletionMove(delta) =>
      if state.completion is Some(completion) {
        (
          @cmd.none,
          {
            ..state,
            completion: Some({
              ..completion,
              menu: completion.menu.shifted(delta),
            }),
          },
        )
      } else {
        (@cmd.none, state)
      }
    CompletionAccept =>
      if state.completion is Some(completion) &&
        completion.menu.current() is Some(item) {
        state.accept_completion(dispatch, channel, item)
      } else {
        (@cmd.none, { ..state, completion: None })
      }
    CompletionPick(index) =>
      if state.completion is Some(completion) &&
        completion.menu.get(index) is Some(item) {
        state.accept_completion(dispatch, channel, item)
      } else {
        (@cmd.none, { ..state, completion: None })
      }
    CompletionDismiss => (@cmd.none, { ..state, completion: None })
    RemoveMention(index) => (@cmd.none, state.without_mention(index))
    SymbolSearchDue(owner~, generation~) =>
      state.begin_completion_search(
        dispatch,
        channel,
        CodexSymbols,
        owner,
        generation,
      )
    FilesIndexed(owner~, files~, truncated~) =>
      (@cmd.none, state.with_files(owner, files, truncated))
    FilesFailed(owner~) => (@cmd.none, state.with_file_failure(owner))
    SkillsLoaded(cwd~, skills~) => (@cmd.none, state.with_skills(cwd, skills))
    SkillsFailed(cwd~) => (@cmd.none, state.with_skill_failure(cwd))
    SymbolsLoaded(owner~, generation~, items~) =>
      (@cmd.none, state.with_symbols(owner, generation, items))
    SymbolsFailed(owner~, generation~) =>
      (@cmd.none, state.with_symbols(owner, generation, []))
    ModelChanged(value) => (@cmd.none, { ..state, selected_model: value })
    GitLoaded(thread_id~, reply~) =>
      (@cmd.none, state.with_git_reply(thread_id, reply))
    ToggleGitDetails =>
      (@cmd.none, { ..state, git_details_open: !state.git_details_open })
    CloseGitDetails => (@cmd.none, state.with_git_details_closed())
    ToggleWorktreeMode =>
      if state.can_choose_worktree() {
        (@cmd.none, { ..state, placement: state.placement.toggled() })
      } else {
        (@cmd.none, state)
      }
    StartDraft(id~, cwd~) => {
      let previous = state.active_draft().map(draft => draft.id)
      let next = state.select_draft(id, cwd)
      let commands : Array[@cmd.Cmd] = []
      if !cwd.trim().is_empty() {
        commands.push(next.open_draft(dispatch, channel, id, cwd))
      }
      if previous is Some(previous) && previous != id {
        commands.push(state.close_draft(channel, previous))
      }
      (@cmd.batch(commands), next)
    }
    OpenThread(thread_id) => {
      let commands : Array[@cmd.Cmd] = [
        state.open_thread(dispatch, channel, thread_id),
      ]
      if state.active_draft() is Some(draft) {
        commands.push(state.close_draft(channel, draft.id))
      }
      (
        @cmd.batch(commands),
        {
          ..state,
          git_details_open: false,
          write_access: CodexNeedsResume,
          loading: true,
          notice: "",
        },
      )
    }
    ArchiveThread(thread_id) =>
      (
        state.archive(dispatch, channel, thread_id, false),
        { ..state, archive_confirm: None, loading: true, notice: "" },
      )
    RepairWorktree =>
      if state.has_missing_worktree() {
        (
          state.repair_worktree(dispatch, channel),
          { ..state, loading: true, notice: "" },
        )
      } else {
        (@cmd.none, state)
      }
    ConfirmArchiveDiscard =>
      match state.archive_confirm {
        Some(confirm) =>
          (
            state.archive(dispatch, channel, confirm.thread_id, true),
            { ..state, archive_confirm: None, loading: true, notice: "" },
          )
        None => (@cmd.none, state)
      }
    CancelArchiveDiscard => (@cmd.none, { ..state, archive_confirm: None })
    Send =>
      if state.input_empty() ||
        !state.has_active() ||
        state.loading ||
        !state.can_prompt() {
        (@cmd.none, state)
      } else if state.active_draft() is Some(_) {
        (
          state.start_draft_thread(dispatch, channel),
          { ..state, loading: true, notice: "" },
        )
      } else if state.write_access is CodexWritable {
        (state.send(dispatch, channel), { ..state, loading: true, notice: "" })
      } else {
        (
          state.resume_for_send(dispatch, channel),
          { ..state, loading: true, notice: "" },
        )
      }
    WriterAcquired(thread_id) =>
      if state.active_thread() is Some(active) && active.id == thread_id {
        let next = {
          ..state,
          write_access: CodexWritable,
          loading: false,
          notice: "",
        }
        (next.send(dispatch, channel), { ..next, loading: true })
      } else {
        (@cmd.none, state)
      }
    WriterConflict(thread_id) =>
      if state.active_thread() is Some(active) && active.id == thread_id {
        (
          @cmd.none,
          {
            ..state,
            write_access: CodexActiveElsewhere,
            loading: false,
            notice: "This Codex task is active in another client. Its history is available here, but sending is read-only until that client releases it.",
          },
        )
      } else {
        (@cmd.none, state)
      }
    Stop => (state.interrupt(dispatch, channel), state)
    Login =>
      (state.login(dispatch, channel), { ..state, loading: true, notice: "" })
    CancelLogin =>
      (
        state.cancel_login(dispatch, channel),
        { ..state, loading: true, notice: "" },
      )
    Logout =>
      (state.logout(dispatch, channel), { ..state, loading: true, notice: "" })
    RequestAnswer(request_key~, question_id~, answer~) =>
      (@cmd.none, state.with_request_answer(request_key, question_id, answer))
    Respond(request_key~, decision~) =>
      (state.respond(dispatch, channel, request_key, decision), state)
    Reply(kind~, value~) => {
      // Activity polling is independent of user commands. Its reply must not
      // settle a simultaneous send/archive/login request's loading state.
      let mut next = if kind is CodexActivityReply {
        state
      } else {
        { ..state, loading: false }
      }
      let mut cmd = @cmd.none
      match kind {
        CodexStatusReply => next = next.with_status(value)
        CodexRequestsReply => next = next.with_requests(value)
        CodexAccountReply => next = next.with_account(value)
        CodexModelsReply => next = next.with_models(value)
        CodexThreadsReply => next = next.with_threads(value)
        CodexDraftOpenReply(draft_id) => {
          next = next.with_open_draft(draft_id, value).loading_context(false)
          cmd = @cmd.batch([
            next.load_files(dispatch, channel),
            next.load_skills(dispatch, channel, force_reload=false),
          ])
        }
        CodexThreadReply => {
          next = next.with_thread_reply(value)
          next = { ..next, write_access: CodexNeedsResume }
          next = next.loading_context(false)
          cmd = @cmd.batch([
            next.refresh_git(dispatch, channel),
            next.load_files(dispatch, channel),
            next.load_skills(dispatch, channel, force_reload=false),
          ])
        }
        CodexActivityReply => next = next.with_activity_reply(value)
        CodexDraftThreadReply => {
          next = next.with_thread_reply(value)
          // Install the real id before starting the turn so every app-server
          // notification observes the stored selection. The preserved draft
          // and placement now flow through the ordinary Local/Worktree send.
          next = { ..next, write_access: CodexWritable, loading: false }
          next = next.loading_context(false)
          cmd = @cmd.batch([
            next.send(dispatch, channel),
            next.refresh_git(dispatch, channel),
            next.load_files(dispatch, channel),
            next.load_skills(dispatch, channel, force_reload=false),
          ])
          next = { ..next, loading: true }
        }
        CodexTurnReply => next = next.with_turn_reply(value)
        CodexWorktreeTurnReply(worktree) => {
          next = next.with_created_worktree(worktree).with_turn_reply(value)
          cmd = @cmd.batch([
            next.refresh_git(dispatch, channel),
            next.load_files(dispatch, channel),
            next.load_skills(dispatch, channel, force_reload=false),
          ])
        }
        CodexWorktreeRepairReply(worktree) => {
          next = next.with_created_worktree(worktree)
          cmd = @cmd.batch([
            next.refresh_git(dispatch, channel),
            next.load_files(dispatch, channel),
            next.load_skills(dispatch, channel, force_reload=false),
          ])
        }
        CodexLoginReply => {
          next = next.with_login(value)
          if next.auth_url is Some(url) {
            cmd = open_external(url)
          }
        }
        CodexArchiveReply(thread_id) =>
          if value is Object(fields) &&
            @jsonx.json_text(fields, "kind") is Some("needs_force") {
            let refusal : @protocol.ArchiveNeedsForceReply = @json.from_json(
              value,
            ) catch {
              _ => {
                next = {
                  ..next,
                  notice: "Codex archive: malformed dirty-worktree reply",
                }
                return (@cmd.none, next)
              }
            }
            next = { ..next, archive_confirm: Some({ thread_id, refusal }) }
          } else {
            // App-server has archived the task. A last-second dirty checkout
            // can be retained, but the task still leaves the active catalog.
            let retained = value is Object(fields) &&
              @jsonx.json_text(fields, "kind")
              is Some("archived_worktree_retained")
            next = next.without_thread(thread_id)
            if retained {
              next = {
                ..next,
                notice: "Codex task archived, but its worktree was retained because new local changes appeared during archiving.",
              }
            }
            cmd = next.refresh(dispatch, channel)
          }
        CodexCompactReply(original) | CodexReviewReply(original) => {
          if next.draft == original {
            next = { ..next, draft: "" }
          }
          next = { ..next, completion: None }
        }
        CodexMutationReply => cmd = next.refresh(dispatch, channel)
        CodexApprovalReply =>
          // `serverRequest/resolved` authoritatively removes the request.
          ()
      }
      (cmd, next)
    }
    Failed(kind~, message~) => {
      // A status poll is best-effort. Older app-server builds or a transient
      // read race must not replace a healthy conversation with an error banner.
      if kind is CodexActivityReply {
        return (@cmd.none, state)
      }
      let subject = match kind {
        CodexStatusReply => "Codex status"
        CodexRequestsReply => "Codex requests"
        CodexAccountReply => "Codex account"
        CodexModelsReply => "Codex models"
        CodexThreadsReply => "Codex threads"
        CodexDraftOpenReply(_) => "Codex draft"
        CodexThreadReply | CodexDraftThreadReply => "Codex thread"
        CodexActivityReply => "Codex activity"
        CodexTurnReply | CodexWorktreeTurnReply(_) => "Codex turn"
        CodexWorktreeRepairReply(_) => "Codex worktree rebuild"
        CodexLoginReply => "Codex sign-in"
        CodexArchiveReply(_) => "Codex archive"
        CodexCompactReply(_) => "Codex compact"
        CodexReviewReply(_) => "Codex review"
        CodexMutationReply => "Codex action"
        CodexApprovalReply => "Codex response"
      }
      (@cmd.none, { ..state, loading: false, notice: subject + ": " + message })
    }
    StatusChanged(value) => {
      let next = state.with_status(value)
      let next = if next.connection is CodexReady {
        next
      } else {
        { ..next, write_access: CodexNeedsResume }
      }
      let cmd = if next.connection is CodexReady {
        if next.active_thread() is Some(active) {
          @cmd.batch([
            next.refresh(dispatch, channel),
            next.open_thread(dispatch, channel, active.id),
          ])
        } else if next.active_draft() is Some(draft) && !draft.cwd.is_empty() {
          @cmd.batch([
            next.refresh(dispatch, channel),
            next.open_draft(dispatch, channel, draft.id, draft.cwd),
          ])
        } else {
          next.refresh(dispatch, channel)
        }
      } else {
        @cmd.none
      }
      (cmd, next)
    }
    Notification(method_~, params~) => {
      let next = state.with_notification(method_, params)
      if method_ == "skills/changed" {
        let invalidated = next.loading_context(true)
        return (
          invalidated.load_skills(dispatch, channel, force_reload=false),
          invalidated,
        )
      }
      let cmd = if method_ == "account/updated" ||
        method_ == "account/login/completed" {
        CodexAccountReply.request(
          dispatch,
          channel,
          @commands.codex_account_read,
          { "refreshToken": false },
        )
      } else if method_ == "thread/archived" ||
        method_ == "thread/unarchived" ||
        method_ == "thread/name/updated" ||
        method_ == "thread/started" {
        CodexThreadsReply.request(
          dispatch,
          channel,
          @commands.codex_thread_list,
          { "limit": 100, "archived": false },
        )
      } else if method_ == "turn/completed" {
        // A turn may check out another branch or create a PR. Refresh the same
        // compact status chip OpenSeek updates at its run boundary.
        next.refresh_git(dispatch, channel)
      } else {
        @cmd.none
      }
      (cmd, next)
    }
    ServerRequest(request_id~, method_~, params~) =>
      (@cmd.none, state.with_pending_request(request_id, method_, params))
  }
}

///|
/// Settle either source of a turn reply. `turn/start` returns a full turn,
/// while `turn/steer` may return only its id; notifications remain the
/// authoritative item lifecycle in both cases.
fn State::with_turn_reply(self : State, value : Json) -> State {
  let next = if value is Object(fields) &&
    fields.get("turn") is Some(turn) &&
    CodexTurn::decode(turn) is Some(turn) &&
    self.active_thread() is Some(active) {
    { ..self, selection: CodexStoredTask(active.with_turn(turn)), draft: "" }
  } else {
    { ..self, draft: "" }
  }
  { ..next, mentions: [], completion: None }
}

///|
test "Codex project add stays local until the first prompt" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let open_external = (_ : String) => @cmd.none
  let (_, draft) = update(
    dispatch,
    StartDraft(id="desktop-draft-1", cwd="/work/project"),
    State(),
    @interop.ChannelId::Local,
    open_external,
  )
  // The add action owns panels with a client-local id, but app-server still
  // has no thread for resume/archive/polling to touch.
  assert_eq(draft.active_id(), Some("desktop-draft-1"))
  assert_true(draft.active_thread() is None)
  assert_false(draft.can_prompt())

  let (_, opened) = update(
    dispatch,
    Reply(kind=CodexDraftOpenReply("desktop-draft-1"), value={
      "draftId": "desktop-draft-1",
      "cwd": "/work/project",
      "projectRoot": "/work/project",
    }),
    draft,
    @interop.ChannelId::Local,
    open_external,
  )
  assert_true(opened.can_prompt())
  assert_eq(
    opened.worktree_launch_workspace(@interop.ChannelId::Local),
    @resource.of_path(@interop.ChannelId::Local, "/work/project"),
  )

  let (_, wants_worktree) = update(
    dispatch,
    ToggleWorktreeMode,
    opened,
    @interop.ChannelId::Local,
    open_external,
  )
  assert_true(wants_worktree.placement is @composer.FreshWorktree)
  let (_, adopted) = update(
    dispatch,
    Reply(kind=CodexDraftThreadReply, value={
      "thread": {
        "id": "thread-real-1",
        "cwd": "/work/project",
        "projectRoot": "/work/project",
        "turns": [],
      },
    }),
    wants_worktree,
    @interop.ChannelId::Local,
    open_external,
  )
  // `thread/start` is adopted before worktree/turn completion. A later error
  // therefore retries this stored empty thread instead of making another.
  assert_eq(adopted.active_id(), Some("thread-real-1"))
  assert_true(adopted.active_thread() is Some(_))
  assert_true(adopted.placement is @composer.FreshWorktree)
  assert_true(adopted.loading)
}

///|
test "Codex cwd-less draft remains a Local first prompt" {
  let draft = State().select_draft("desktop-draft-local", "")
  assert_true(draft.can_prompt())
  assert_true(
    draft.worktree_launch_workspace(@interop.ChannelId::Local) is None,
  )
}

///|
test "Codex update handlers are pure and idempotent" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = {
    ..State::from_thread_snapshot({
      "thread": {
        "id": "thread-1",
        "cwd": "/work/project",
        "preview": "Package test",
        "turns": [{ "id": "turn-1", "status": "inProgress", "items": [] }],
      },
    }),
    draft: "inspect this",
    login_id: Some("login-1"),
    pending_requests: [
      {
        request_id: Json::string("request-1"),
        method_: "item/commandExecution/requestApproval",
        params: { "reason": "test" },
        answers: Map([]),
      },
    ],
  }
  let messages : Array[Msg] = [
    Refresh,
    PollActivity,
    DraftChanged("next draft"),
    ModelChanged("gpt-test"),
    ToggleGitDetails,
    CloseGitDetails,
    ToggleWorktreeMode,
    StartDraft(id="desktop-test", cwd="/work/project"),
    OpenThread("thread-1"),
    ArchiveThread("thread-1"),
    RepairWorktree,
    ConfirmArchiveDiscard,
    CancelArchiveDiscard,
    Send,
    Stop,
    Login,
    CancelLogin,
    Logout,
    RequestAnswer(
      request_key=Json::string("request-1").stringify(),
      question_id="question-1",
      answer="yes",
    ),
    Respond(
      request_key=Json::string("request-1").stringify(),
      decision="accept",
    ),
    Reply(kind=CodexStatusReply, value={ "status": "ready" }),
    Reply(kind=CodexRequestsReply, value={ "data": [] }),
    Reply(kind=CodexAccountReply, value={
      "requiresOpenaiAuth": true,
      "account": Json::null(),
    }),
    Reply(kind=CodexModelsReply, value={ "data": [] }),
    Reply(kind=CodexThreadsReply, value={ "data": [] }),
    Reply(kind=CodexThreadReply, value={
      "thread": { "id": "thread-1", "turns": [] },
    }),
    Reply(kind=CodexActivityReply, value={
      "threadId": "thread-1",
      "turn": {
        "id": "turn-1",
        "status": "inProgress",
        "startedAt": 100,
        "completedAt": Json::null(),
        "items": [],
      },
    }),
    Reply(kind=CodexDraftThreadReply, value={
      "thread": { "id": "thread-2", "turns": [] },
    }),
    Reply(kind=CodexTurnReply, value={
      "turn": { "id": "turn-2", "status": "inProgress" },
    }),
    Reply(
      kind=CodexWorktreeTurnReply({
        name: "wt-1",
        path: "/work/project/.worktrees/wt-1",
        present: true,
      }),
      value={ "turn": { "id": "turn-2", "status": "inProgress" } },
    ),
    Reply(
      kind=CodexWorktreeRepairReply({
        name: "wt-1",
        path: "/work/project/.worktrees/wt-1",
        present: true,
      }),
      value={},
    ),
    Reply(kind=CodexLoginReply, value={
      "loginId": "login-2",
      "authUrl": "https://example.test",
    }),
    Reply(kind=CodexArchiveReply("thread-1"), value={}),
    Reply(kind=CodexMutationReply, value={}),
    Reply(kind=CodexApprovalReply, value={}),
    Failed(kind=CodexTurnReply, message="test failure"),
    Failed(
      kind=CodexWorktreeRepairReply({
        name: "wt-1",
        path: "/work/project/.worktrees/wt-1",
        present: false,
      }),
      message="test failure",
    ),
    Failed(kind=CodexActivityReply, message="poll failure"),
    StatusChanged({ "status": "ready" }),
    Notification(method_="thread/name/updated", params={
      "threadId": "thread-1",
      "name": "Renamed",
    }),
    ServerRequest(
      request_id=Json::string("request-2"),
      method_="item/commandExecution/requestApproval",
      params={ "reason": "test" },
    ),
  ]
  for message in messages {
    let (_, once) = update(
      dispatch,
      message,
      state,
      @interop.ChannelId::Local,
      _ => @cmd.none,
    )
    let (_, twice) = update(
      dispatch,
      message,
      state,
      @interop.ChannelId::Local,
      _ => @cmd.none,
    )
    assert_true(once == twice)
  }
}

///|
test "Codex missing worktree waits for rebuild or archive confirmation" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = State::from_thread_snapshot({
    "thread": {
      "id": "thread-1",
      "cwd": "/work/project/.worktrees/wt-1",
      "projectRoot": "/work/project",
      "openseekWorktree": {
        "name": "wt-1",
        "path": "/work/project/.worktrees/wt-1",
        "present": false,
      },
      "turns": [],
    },
  })
  assert_true(state.has_missing_worktree())
  assert_true(
    state.active_placement(@interop.ChannelId::Local)
    is Some(@interop.MissingWorktree(name="wt-1", ..)),
  )
  let (_, confirming) = update(
    dispatch,
    Reply(kind=CodexArchiveReply("thread-1"), value={
      "kind": "needs_force",
      "worktree": "wt-1",
      "dirty_paths": ["local.txt"],
      "dirty_path_count": 1,
    }),
    state,
    @interop.ChannelId::Local,
    _ => @cmd.none,
  )
  guard confirming.archive_confirm is Some(confirm) else {
    fail("dirty archive reply did not open confirmation")
  }
  assert_eq(confirm.thread_id, "thread-1")
  assert_eq(confirm.refusal.dirty_paths, ["local.txt"])
  let (_, cancelled) = update(
    dispatch,
    CancelArchiveDiscard,
    confirming,
    @interop.ChannelId::Local,
    _ => @cmd.none,
  )
  assert_true(cancelled.archive_confirm is None)
  let rebuilt : CodexWorktree = {
    name: "wt-1",
    path: "/work/project/.worktrees/wt-1",
    present: true,
  }
  let (_, ready) = update(
    dispatch,
    Reply(kind=CodexWorktreeRepairReply(rebuilt), value={}),
    state,
    @interop.ChannelId::Local,
    _ => @cmd.none,
  )
  assert_false(ready.has_missing_worktree())
  assert_eq(
    ready
    .active_placement(@interop.ChannelId::Local)
    .bind(placement => placement.checkout_root())
    .map(uri => uri.path),
    Some("/work/project/.worktrees/wt-1"),
  )
}

///|
test "Codex activity polling follows explicit turn status" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = {
    ..State::from_thread_snapshot({
      "thread": {
        "id": "thread-1",
        "turns": [
          {
            "id": "turn-1",
            "status": "completed",
            "startedAt": 80,
            "completedAt": 90,
            "items": [],
          },
        ],
      },
    })
    // A background poll must not settle an unrelated user operation.
    ,
    loading: true,
  }
  let (_, running) = update(
    dispatch,
    Reply(kind=CodexActivityReply, value={
      "threadId": "thread-1",
      "turn": {
        "id": "turn-2",
        "status": "inProgress",
        "startedAt": 100,
        "completedAt": Json::null(),
        "items": [],
      },
    }),
    state,
    @interop.ChannelId::Local,
    _ => @cmd.none,
  )
  assert_true(running.is_running())
  assert_false(running.is_active_elsewhere())
  assert_true(running.loading)

  let (_, completed) = update(
    dispatch,
    Reply(kind=CodexActivityReply, value={
      "threadId": "thread-1",
      "turn": {
        "id": "turn-2",
        "status": "completed",
        "startedAt": 100,
        "completedAt": 120,
        "items": [],
      },
    }),
    running,
    @interop.ChannelId::Local,
    _ => @cmd.none,
  )
  assert_false(completed.is_running())

  let (_, stale) = update(
    dispatch,
    Reply(kind=CodexActivityReply, value={
      "threadId": "thread-old",
      "turn": { "id": "turn-stale", "status": "inProgress", "items": [] },
    }),
    completed,
    @interop.ChannelId::Local,
    _ => @cmd.none,
  )
  assert_true(stale == completed)
}

///|
test "Codex writer conflict is the active-elsewhere signal" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = State::from_thread_snapshot({
    "thread": { "id": "thread-1", "turns": [] },
  })
  let (_, first) = update(
    dispatch,
    WriterConflict("thread-1"),
    state,
    @interop.ChannelId::Local,
    _ => @cmd.none,
  )
  let (_, repeated) = update(
    dispatch,
    WriterConflict("thread-1"),
    state,
    @interop.ChannelId::Local,
    _ => @cmd.none,
  )
  assert_true(first.is_active_elsewhere())
  assert_false(first.is_running())
  assert_true(first == repeated)

  let (_, stale) = update(
    dispatch,
    WriterConflict("thread-old"),
    state,
    @interop.ChannelId::Local,
    _ => @cmd.none,
  )
  assert_true(stale == state)
}

///|
test "Codex Git pill opens and closes its details" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = State::from_thread_snapshot({
    "thread": {
      "id": "thread-1",
      "cwd": "/work/project",
      "gitInfo": { "branch": "feature" },
      "turns": [],
    },
  })
  let (_, opened) = update(
    dispatch,
    ToggleGitDetails,
    state,
    @interop.ChannelId::Local,
    _ => @cmd.none,
  )
  assert_true(opened.git_details_open())
  let (_, closed) = update(
    dispatch,
    CloseGitDetails,
    opened,
    @interop.ChannelId::Local,
    _ => @cmd.none,
  )
  assert_false(closed.git_details_open())
}
