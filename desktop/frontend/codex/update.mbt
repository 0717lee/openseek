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
    DraftChanged(value) => (@cmd.none, { ..state, draft: value })
    ModelChanged(value) => (@cmd.none, { ..state, selected_model: value })
    StartThread(cwd) =>
      (
        state.start_thread(dispatch, channel, cwd),
        { ..state, loading: true, notice: "" },
      )
    OpenThread(thread_id) =>
      (
        state.open_thread(dispatch, channel, thread_id),
        { ..state, loading: true, notice: "" },
      )
    ArchiveThread(thread_id) =>
      (
        state.archive(dispatch, channel, thread_id),
        { ..state, loading: true, notice: "" },
      )
    Send =>
      if state.draft.trim().is_empty() || state.active is None || state.loading {
        (@cmd.none, state)
      } else {
        (state.send(dispatch, channel), { ..state, loading: true, notice: "" })
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
      let mut next = { ..state, loading: false }
      let mut cmd = @cmd.none
      match kind {
        CodexStatusReply => next = next.with_status(value)
        CodexRequestsReply => next = next.with_requests(value)
        CodexAccountReply => next = next.with_account(value)
        CodexModelsReply => next = next.with_models(value)
        CodexThreadsReply => next = next.with_threads(value)
        CodexThreadReply => next = next.with_thread_reply(value)
        CodexNewThreadReply => {
          next = next.with_thread_reply(value)
          cmd = CodexThreadsReply.request(
            dispatch,
            channel,
            @commands.codex_thread_list,
            { "limit": 100, "archived": false },
          )
        }
        CodexTurnReply =>
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
        CodexMutationReply => cmd = next.refresh(dispatch, channel)
        CodexApprovalReply =>
          // `serverRequest/resolved` authoritatively removes the request.
          ()
      }
      (cmd, next)
    }
    Failed(kind~, message~) => {
      let subject = match kind {
        CodexStatusReply => "Codex status"
        CodexRequestsReply => "Codex requests"
        CodexAccountReply => "Codex account"
        CodexModelsReply => "Codex models"
        CodexThreadsReply => "Codex threads"
        CodexThreadReply | CodexNewThreadReply => "Codex thread"
        CodexTurnReply => "Codex turn"
        CodexLoginReply => "Codex sign-in"
        CodexArchiveReply(_) => "Codex archive"
        CodexMutationReply => "Codex action"
        CodexApprovalReply => "Codex response"
      }
      (@cmd.none, { ..state, loading: false, notice: subject + ": " + message })
    }
    StatusChanged(value) => {
      let next = state.with_status(value)
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
    DraftChanged("next draft"),
    ModelChanged("gpt-test"),
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
