// Browser-side calls into the three Desktop-local dsh commands. dsh's own
// method names remain payload data, while the native endpoint applies the
// reviewed allowlist before using the HTTP carrier.

///|
/// Snapshot replies replace a complete frontend baseline. Keep each baseline
/// on its own ordered lane so unrelated Workspace, session, and transcript
/// reads do not block one another, while older reads of the same baseline
/// cannot arrive after newer ones. Reconnect uses the Workspace lane because
/// its probe is a `workspace.list` request too.
fn DshReplyKind::ordered_lane(self : DshReplyKind) -> String? {
  match self {
    DshReconnectReply | DshWorkspacesReply => Some("dsh-workspace-list")
    DshSessionsReply => Some("dsh-session-list")
    DshHistoryReply(session_id) => Some("dsh-history-" + session_id)
    _ => None
  }
}

///|
fn DshReplyKind::request(
  self : DshReplyKind,
  dispatch : @cmd.Emit[Msg],
  method_ : String,
  payload : Json,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      // Hold list lanes across the complete bridge call. For Workspace this
      // includes the native Files/Terminal authorization update, so neither
      // native authority nor either frontend baseline can be rolled back by
      // an older reply.
      let value : Json = try {
        if self.ordered_lane() is Some(lane) {
          @interop.bridge_request_in_order(
            @interop.ChannelId::Local,
            @commands.dsh_request,
            { "method": method_, "payload": payload },
            lane~,
          )
        } else {
          @interop.bridge_request(
            @interop.ChannelId::Local,
            @commands.dsh_request,
            { "method": method_, "payload": payload },
          )
        }
      } catch {
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
test "dsh snapshot replies select independent ordered lanes" {
  assert_eq(DshReconnectReply.ordered_lane(), Some("dsh-workspace-list"))
  assert_eq(DshWorkspacesReply.ordered_lane(), Some("dsh-workspace-list"))
  assert_eq(DshSessionsReply.ordered_lane(), Some("dsh-session-list"))
  assert_eq(
    DshHistoryReply("session-1").ordered_lane(),
    Some("dsh-history-session-1"),
  )
  assert_eq(
    DshHistoryReply("session-2").ordered_lane(),
    Some("dsh-history-session-2"),
  )
  assert_eq(DshCreateReply.ordered_lane(), None)
}

///|
fn DshReplyKind::status(
  self : DshReplyKind,
  dispatch : @cmd.Emit[Msg],
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let value : Json = @interop.bridge_request(
        @interop.ChannelId::Local,
        @commands.dsh_status,
        {},
      ) catch {
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
/// Read the actor-owned interaction baseline after a page attaches. The actor
/// serializes this snapshot with live mux events and supplies their generation.
fn DshReplyKind::pending(
  self : DshReplyKind,
  dispatch : @cmd.Emit[Msg],
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let value : Json = @interop.bridge_request(
        @interop.ChannelId::Local,
        @commands.dsh_pending,
        {},
      ) catch {
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
fn DshReplyKind::respond(
  self : DshReplyKind,
  dispatch : @cmd.Emit[Msg],
  message : Json,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let value : Json = @interop.bridge_request(
        @interop.ChannelId::Local,
        @commands.dsh_respond,
        message,
      ) catch {
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
/// A status read cannot wake the actor after startup has failed: only a queued
/// dsh request asks it to connect again. Use the Workspace baseline as that
/// retry request, while ordinary refreshes keep the cheap status read.
fn State::refresh(self : State, dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  match self.connection {
    DshUnavailable(_) =>
      DshReconnectReply.request(dispatch, "workspace.list", {})
    DshStarting | DshReady => DshStatusReply.status(dispatch)
  }
}

///|
fn State::create_session(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  workspace_id : String,
) -> @cmd.Cmd {
  DshCreateReply.request(dispatch, "session.create", {
    "workspaceId": workspace_id,
  })
}

///|
fn State::create_workspace_session(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  path : String,
) -> @cmd.Cmd {
  DshWorkspaceCreateReply.request(dispatch, "workspace.create", { "path": path })
}

///|
fn State::load_history(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  session_id : String,
) -> @cmd.Cmd {
  DshHistoryReply(session_id).request(dispatch, "session.history", {
    "sessionId": session_id,
    "maxMessages": 200,
  })
}

///|
fn State::send(
  self : State,
  dispatch : @cmd.Emit[Msg],
  generation : Int,
) -> @cmd.Cmd {
  guard self.active_id is Some(session_id) else { return @cmd.none }
  let text = self.draft.trim().to_owned()
  guard !text.is_empty() else { return @cmd.none }
  DshPromptReply(session_id~, draft=self.draft, generation~).request(
    dispatch,
    "session.prompt",
    {
      "sessionId": session_id,
      "mode": if self.is_running() {
        "steer"
      } else {
        "queue"
      },
      "content": [{ "type": "text", "text": text }],
    },
  )
}

///|
fn State::cancel(self : State, dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  guard self.active_id is Some(session_id) else { return @cmd.none }
  DshCancelReply.request(dispatch, "session.cancel", { "sessionId": session_id })
}

///|
fn State::respond_approval(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  rpc_id : String,
  outcome : String,
  pending : DshPendingInteraction,
) -> @cmd.Cmd {
  guard pending is DshApproval(session_id~, approval_id~, ..) else {
    return @cmd.none
  }
  DshResponseReply(rpc_id).respond(dispatch, {
    "type": "client-response",
    "rpcId": rpc_id,
    "result": {
      "ok": true,
      "value": {
        "sessionId": session_id,
        "approvalId": approval_id,
        "outcome": outcome,
      },
    },
  })
}

///|
fn State::respond_questions(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  rpc_id : String,
  pending : DshPendingInteraction,
) -> @cmd.Cmd {
  guard pending is DshQuestions(session_id~, questions~, answers~, ..) else {
    return @cmd.none
  }
  let values : Array[Json] = []
  for question in questions {
    let answer = answers
      .get(question.id)
      .unwrap_or_else(() => DshQuestionAnswer::empty())
    let fields : Map[String, Json] = {
      "id": Json::string(question.id),
      "selected": answer.selected.to_json(),
    }
    if !answer.custom.trim().is_empty() {
      fields["custom"] = Json::string(answer.custom.trim().to_owned())
    }
    values.push(Json::object(fields))
  }
  DshResponseReply(rpc_id).respond(dispatch, {
    "type": "client-response",
    "rpcId": rpc_id,
    "result": {
      "ok": true,
      "value": { "sessionId": session_id, "answer": { "answers": values } },
    },
  })
}
