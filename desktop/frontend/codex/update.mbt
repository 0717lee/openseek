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
    StartThread(cwd) =>
      (
        state.start_thread(dispatch, channel, cwd),
        {
          ..state,
          git_details_open: false,
          write_access: CodexNeedsResume,
          loading: true,
          notice: "",
        },
      )
    OpenThread(thread_id) =>
      (
        state.open_thread(dispatch, channel, thread_id),
        {
          ..state,
          git_details_open: false,
          write_access: CodexNeedsResume,
          loading: true,
          notice: "",
        },
      )
    ArchiveThread(thread_id) =>
      (
        state.archive(dispatch, channel, thread_id),
        { ..state, loading: true, notice: "" },
      )
    Send =>
      if state.input_empty() || state.active is None || state.loading {
        (@cmd.none, state)
      } else if state.write_access is CodexWritable {
        (state.send(dispatch, channel), { ..state, loading: true, notice: "" })
      } else {
        (
          state.resume_for_send(dispatch, channel),
          { ..state, loading: true, notice: "" },
        )
      }
    WriterAcquired(thread_id) =>
      if state.active is Some(active) && active.id == thread_id {
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
      if state.active is Some(active) && active.id == thread_id {
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
        CodexActivityReply => {
          let was_running_elsewhere = next.is_running_elsewhere()
          next = next.with_activity_reply(value)
          // Once another client finishes, reload exactly once so its final
          // messages become visible. Running polls keep only lifecycle fields.
          if was_running_elsewhere &&
            !next.is_running() &&
            next.active is Some(active) {
            cmd = next.open_thread(dispatch, channel, active.id)
          }
        }
        CodexNewThreadReply => {
          next = next.with_thread_reply(value)
          next = { ..next, write_access: CodexWritable }
          next = next.loading_context(false)
          cmd = @cmd.batch([
            CodexThreadsReply.request(
              dispatch,
              channel,
              @commands.codex_thread_list,
              { "limit": 100, "archived": false },
            ),
            next.refresh_git(dispatch, channel),
            next.load_files(dispatch, channel),
            next.load_skills(dispatch, channel, force_reload=false),
          ])
        }
        CodexTurnReply => {
          // `turn/start` returns a turn while `turn/steer` may return only its
          // id. The notification stream remains the canonical item lifecycle.
          if value is Object(fields) &&
            fields.get("turn") is Some(turn) &&
            CodexTurn::decode(turn) is Some(turn) &&
            next.active is Some(active) {
            next = { ..next, active: Some(active.with_turn(turn)), draft: "" }
          } else {
            next = { ..next, draft: "" }
          }
          next = { ..next, mentions: [], completion: None }
        }
        CodexLoginReply => {
          next = next.with_login(value)
          if next.auth_url is Some(url) {
            cmd = open_external(url)
          }
        }
        CodexArchiveReply(thread_id) => {
          // The successful reply is the durable acknowledgement. Remove the
          // row immediately, then refresh to verify the catalog snapshot.
          next = next.without_thread(thread_id)
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
        CodexThreadReply | CodexNewThreadReply => "Codex thread"
        CodexActivityReply => "Codex activity"
        CodexTurnReply => "Codex turn"
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
        match next.active {
          Some(active) =>
            @cmd.batch([
              next.refresh(dispatch, channel),
              next.open_thread(dispatch, channel, active.id),
            ])
          None => next.refresh(dispatch, channel)
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
    StartThread("/work/project"),
    OpenThread("thread-1"),
    ArchiveThread("thread-1"),
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
    Reply(kind=CodexNewThreadReply, value={
      "thread": { "id": "thread-2", "turns": [] },
    }),
    Reply(kind=CodexTurnReply, value={
      "turn": { "id": "turn-2", "status": "inProgress" },
    }),
    Reply(kind=CodexLoginReply, value={
      "loginId": "login-2",
      "authUrl": "https://example.test",
    }),
    Reply(kind=CodexArchiveReply("thread-1"), value={}),
    Reply(kind=CodexMutationReply, value={}),
    Reply(kind=CodexApprovalReply, value={}),
    Failed(kind=CodexTurnReply, message="test failure"),
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
test "Codex activity polling tracks another client's turn" {
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
        "status": "interrupted",
        "startedAt": 100,
        "completedAt": Json::null(),
        "items": [],
      },
    }),
    state,
    @interop.ChannelId::Local,
    _ => @cmd.none,
  )
  assert_true(running.is_running_elsewhere())
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
