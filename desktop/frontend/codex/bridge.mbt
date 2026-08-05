// Browser-side calls into the Desktop's curated Codex catalog. Every command
// returns parsed JSON to update; Codex never exposes account tokens or an
// arbitrary app-server method proxy to this page.

///|
fn CodexReplyKind::request(
  self : CodexReplyKind,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  command : @commands.Command[Json, Json],
  payload : Json,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let value : Json = @interop.bridge_request(channel, command, payload) catch {
        error => {
          scheduler.add(
            dispatch(
              Failed(kind=self, message=@interop.bridge_error_text(error)),
            ),
          )
          return
        }
      }
      scheduler.add(dispatch(Reply(kind=self, value~)))
    })
  })
}

///|
pub fn State::refresh(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
) -> @cmd.Cmd {
  let account : Json = { "refreshToken": false }
  let models : Json = { "limit": 100, "includeHidden": false }
  let threads : Json = { "limit": 100, "archived": false }
  // The global sidebar is the conversation switcher for both products, so it
  // shows the Codex account's interactive history instead of silently hiding
  // threads outside OpenSeek's currently selected workspace. New threads
  // still receive that workspace as their cwd in `start_thread` below.
  @cmd.batch([
    CodexStatusReply.request(dispatch, channel, @commands.codex_status, {}),
    CodexAccountReply.request(
      dispatch, channel, @commands.codex_account_read, account,
    ),
    CodexRequestsReply.request(
      dispatch,
      channel,
      @commands.codex_server_request_list,
      {},
    ),
    CodexModelsReply.request(
      dispatch, channel, @commands.codex_model_list, models,
    ),
    CodexThreadsReply.request(
      dispatch, channel, @commands.codex_thread_list, threads,
    ),
  ])
}

///|
fn State::start_thread(
  self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  cwd : String,
) -> @cmd.Cmd {
  let fields : Map[String, Json] = Map([])
  let model = self.selected_model.trim()
  if !model.is_empty() {
    fields["model"] = Json::string(model.to_owned())
  }
  let cwd = cwd.trim()
  if !cwd.is_empty() {
    fields["cwd"] = Json::string(cwd.to_owned())
  }
  CodexNewThreadReply.request(
    dispatch,
    channel,
    @commands.codex_thread_start,
    Json::object(fields),
  )
}

///|
fn State::open_thread(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  thread_id : String,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let _ : Json = @interop.bridge_request(
        channel,
        @commands.codex_thread_resume,
        { "threadId": thread_id },
      ) catch {
        error => {
          scheduler.add(
            dispatch(
              Failed(
                kind=CodexThreadReply,
                message=@interop.bridge_error_text(error),
              ),
            ),
          )
          return
        }
      }
      // Resume subscribes this connection to future item events. A separate
      // full read is still the authoritative history snapshot and closes the
      // gap between the stored log and subscription setup.
      let value : Json = @interop.bridge_request(
        channel,
        @commands.codex_thread_read,
        { "threadId": thread_id, "includeTurns": true },
      ) catch {
        error => {
          scheduler.add(
            dispatch(
              Failed(
                kind=CodexThreadReply,
                message=@interop.bridge_error_text(error),
              ),
            ),
          )
          return
        }
      }
      scheduler.add(dispatch(Reply(kind=CodexThreadReply, value~)))
    })
  })
}

///|
fn State::send(
  self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
) -> @cmd.Cmd {
  guard self.active is Some(active) else { return @cmd.none }
  let text = self.draft.trim().to_owned()
  guard !text.is_empty() else { return @cmd.none }
  let fields : Map[String, Json] = {
    "threadId": active.id,
    "input": [{ "type": "text", "text": text }],
  }
  if self.active_turn_id() is Some(turn_id) {
    fields["expectedTurnId"] = Json::string(turn_id)
    CodexTurnReply.request(
      dispatch,
      channel,
      @commands.codex_turn_steer,
      Json::object(fields),
    )
  } else {
    let model = self.selected_model.trim()
    if !model.is_empty() {
      fields["model"] = Json::string(model.to_owned())
    }
    CodexTurnReply.request(
      dispatch,
      channel,
      @commands.codex_turn_start,
      Json::object(fields),
    )
  }
}

///|
fn State::interrupt(
  self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
) -> @cmd.Cmd {
  guard self.active is Some(active) && self.active_turn_id() is Some(turn_id) else {
    return @cmd.none
  }
  CodexMutationReply.request(
    dispatch,
    channel,
    @commands.codex_turn_interrupt,
    { "threadId": active.id, "turnId": turn_id },
  )
}

///|
fn State::archive(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  thread_id : String,
) -> @cmd.Cmd {
  CodexArchiveReply(thread_id).request(
    dispatch,
    channel,
    @commands.codex_thread_archive,
    { "threadId": thread_id },
  )
}

///|
fn State::login(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
) -> @cmd.Cmd {
  CodexLoginReply.request(
    dispatch,
    channel,
    @commands.codex_account_login_start,
    {
      "type": "chatgpt",
      "useHostedLoginSuccessPage": true,
      "appBrand": "codex",
    },
  )
}

///|
fn State::logout(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
) -> @cmd.Cmd {
  CodexMutationReply.request(
    dispatch,
    channel,
    @commands.codex_account_logout,
    {},
  )
}

///|
fn State::cancel_login(
  self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
) -> @cmd.Cmd {
  guard self.login_id is Some(login_id) else { return @cmd.none }
  CodexMutationReply.request(
    dispatch,
    channel,
    @commands.codex_account_login_cancel,
    { "loginId": login_id },
  )
}

///|
fn State::respond(
  self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  request_key : String,
  decision : String,
) -> @cmd.Cmd {
  let mut selected : CodexPendingRequest? = None
  for request in self.pending_requests {
    if request.request_id.stringify() == request_key {
      selected = Some(request)
      break
    }
  }
  guard selected is Some(request) && request.response(decision) is Some(result) else {
    return @cmd.none
  }
  let payload : Json = { "request_id": request.request_id, "result": result }
  CodexApprovalReply.request(
    dispatch, channel, @commands.codex_server_request_respond, payload,
  )
}
