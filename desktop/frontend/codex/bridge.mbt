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
  // The host keeps this read-only across both legacy inline histories and
  // paginated histories. Selecting a row never resumes the task or claims its
  // writer merely to render the transcript.
  CodexThreadReply.request(
    dispatch,
    channel,
    @commands.codex_thread_history_read,
    { "threadId": thread_id },
  )
}

///|
/// Poll one summary turn instead of the complete history. This is the only
/// periodic Codex request and runs only while its conversation page is visible.
fn State::poll_activity(
  self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
) -> @cmd.Cmd {
  guard self.active is Some(active) else { return @cmd.none }
  CodexActivityReply.request(
    dispatch,
    channel,
    @commands.codex_thread_activity_read,
    { "threadId": active.id },
  )
}

///|
/// Re-read the selected checkout's current branch and pull request. App-server
/// `gitInfo` is creation-time metadata; this host operation is the same GitHub
/// lookup used by OpenSeek's composer and therefore follows branch changes
/// made during a Codex turn.
fn State::refresh_git(
  self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
) -> @cmd.Cmd {
  guard self.active is Some(active) && active.cwd is Some(cwd) else {
    return @cmd.none
  }
  let thread_id = active.id
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let reply : @protocol.GitPullRequestReply = @interop.bridge_request(
        channel,
        @commands.git_pull_request,
        { session: thread_id, cwd: Some(cwd), branch_hint: active.branch },
      ) catch {
        // Git/gh decoration never blocks the conversation. Keep app-server's
        // captured branch label when the live lookup is unavailable.
        _ => return
      }
      scheduler.add(dispatch(GitLoaded(thread_id~, reply~)))
    })
  })
}

///|
/// Claim the selected task's writer only when the user intends to append a
/// turn. A conflicting Codex client leaves the transcript and draft intact.
fn State::resume_for_send(
  self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
) -> @cmd.Cmd {
  guard self.active is Some(active) else { return @cmd.none }
  let thread_id = active.id
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let value : Json = @interop.bridge_request(
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
      if value is Object(fields) &&
        @jsonx.json_text(fields, "status") is Some("activeWriter") {
        scheduler.add(dispatch(WriterConflict(thread_id)))
      } else {
        scheduler.add(dispatch(WriterAcquired(thread_id)))
      }
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
  guard !self.input_empty() else { return @cmd.none }
  let inputs : Array[Json] = []
  if !text.is_empty() {
    inputs.push({ "type": "text", "text": text })
  }
  for mention in self.mentions {
    inputs.push(mention.to_input())
  }
  let fields : Map[String, Json] = {
    "threadId": Json::string(active.id),
    "input": Json::array(inputs),
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
fn CodexMention::to_input(self : CodexMention) -> Json {
  match self {
    CodexFileMention(name~, path~) =>
      { "type": "mention", "name": name, "path": path }
    CodexEditorAnnotation(file~, range~, quote~, comment~) =>
      {
        "type": "text",
        "text": @mention_context.encode(
          [
            @mention_context.Annotation(
              file~,
              start_line=range.start_line_number,
              end_line=range.end_line_number,
              quote~,
              comment~,
              side=@mention_context.WorkingRevision,
            ),
          ],
          "",
        ),
      }
  }
}

///|
fn State::search_files(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  owner : CodexFileSearchOwner,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let value : Json = @interop.bridge_request(
        channel,
        @commands.codex_file_search,
        { "thread_id": owner.thread_id, "cwd": owner.cwd, "query": owner.query },
      ) catch {
        _ => {
          scheduler.add(dispatch(FilesFailed(owner~)))
          return
        }
      }
      guard value is Object(fields) &&
        fields.get("files") is Some(Array(values)) else {
        scheduler.add(dispatch(FilesFailed(owner~)))
        return
      }
      let items : Array[CodexCompletionItem] = []
      for value in values {
        if CodexCompletionItem::decode_file(value) is Some(item) {
          items.push(item)
        }
      }
      scheduler.add(dispatch(FilesLoaded(owner~, items~)))
    })
  })
}

///|
fn State::compact(
  self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  original : String,
) -> @cmd.Cmd {
  guard self.active is Some(active) else { return @cmd.none }
  CodexCompactReply(original).request(
    dispatch,
    channel,
    @commands.codex_thread_compact,
    { "threadId": active.id },
  )
}

///|
fn State::review(
  self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  original : String,
) -> @cmd.Cmd {
  guard self.active is Some(active) else { return @cmd.none }
  CodexReviewReply(original).request(
    dispatch,
    channel,
    @commands.codex_review_start,
    { "threadId": active.id, "target": { "type": "uncommittedChanges" } },
  )
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
