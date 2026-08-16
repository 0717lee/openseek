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
    DshReconnectReply | DshWorkspacesReply | DshPromptWorkspacesReply(..) =>
      Some("dsh-workspace-list")
    DshSessionsReply(..) => Some("dsh-session-list")
    DshHistoryReply(session_id) => Some("dsh-history-" + session_id)
    DshModelsReply(session_id) | DshSelectModelReply(session_id~) =>
      Some("dsh-models-" + session_id)
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
      let request : @protocol.DshRequestPayload = { method_, payload }
      let reply : @protocol.DshValueReply = try {
        if self.ordered_lane() is Some(lane) {
          @interop.bridge_request_in_order(
            @interop.ChannelId::Local,
            @commands.dsh_request,
            request,
            lane~,
          )
        } else {
          @interop.bridge_request(
            @interop.ChannelId::Local,
            @commands.dsh_request,
            request,
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
      let reply_kind = match self {
        DshSessionsReply(..) =>
          match reply.session_revision {
            Some(revision) => DshSessionsReply(session_revision=revision)
            None => {
              scheduler.add(
                dispatch(
                  Failed(
                    kind=self,
                    message="DeepSeek Harness session list omitted its dispatch revision",
                  ),
                ),
              )
              return
            }
          }
        _ => self
      }
      scheduler.add(dispatch(Reply(kind=reply_kind, value=reply.value)))
    })
  })
}

///|
test "dsh snapshot replies select independent ordered lanes" {
  assert_eq(DshReconnectReply.ordered_lane(), Some("dsh-workspace-list"))
  assert_eq(DshWorkspacesReply.ordered_lane(), Some("dsh-workspace-list"))
  assert_eq(
    DshPromptWorkspacesReply(
      session_id="session-1",
      generation=1,
      worktree_path="/work/project/.worktrees/wt-1",
      draft={ task: "inspect this project", mentions: [] },
    ).ordered_lane(),
    Some("dsh-workspace-list"),
  )
  assert_eq(
    DshSessionsReply(session_revision=-1).ordered_lane(),
    Some("dsh-session-list"),
  )
  assert_eq(
    DshHistoryReply("session-1").ordered_lane(),
    Some("dsh-history-session-1"),
  )
  assert_eq(
    DshHistoryReply("session-2").ordered_lane(),
    Some("dsh-history-session-2"),
  )
  assert_eq(DshCreateReply(0).ordered_lane(), None)
  assert_eq(
    DshPromptWorkspaceReply(
      session_id="session-1",
      generation=1,
      project="/work/project",
      worktree_name="wt-1",
      worktree_path="/work/project/.worktrees/wt-1",
      draft={ task: "inspect this project", mentions: [] },
    ).failed_worktree(),
    Some(("session-1", 1, "/work/project", "wt-1")),
  )
  assert_true(
    DshPromptWorkspacesReply(
      session_id="session-1",
      generation=1,
      worktree_path="/work/project/.worktrees/wt-1",
      draft={ task: "inspect this project", mentions: [] },
    ).failed_worktree()
    is None,
  )
}

///|
fn DshReplyKind::status(
  self : DshReplyKind,
  dispatch : @cmd.Emit[Msg],
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let reply : @protocol.DshValueReply = @interop.bridge_request(
        @interop.ChannelId::Local,
        @commands.dsh_status,
        @protocol.DshEmptyPayload::DshNoPayload,
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
      scheduler.add(dispatch(Reply(kind=self, value=reply.value)))
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
      let reply : @protocol.DshValueReply = @interop.bridge_request(
        @interop.ChannelId::Local,
        @commands.dsh_pending,
        @protocol.DshEmptyPayload::DshNoPayload,
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
      scheduler.add(dispatch(Reply(kind=self, value=reply.value)))
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
      let request : @protocol.DshRespondPayload = { message, }
      let reply : @protocol.DshValueReply = @interop.bridge_request(
        @interop.ChannelId::Local,
        @commands.dsh_respond,
        request,
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
      scheduler.add(dispatch(Reply(kind=self, value=reply.value)))
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
/// The native actor attaches the host/session-status revision captured when
/// this request actually dispatches. `-1` marks the frontend request kind and
/// is replaced before the reply reaches the reducer.
fn State::list_sessions(_self : State, dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  DshSessionsReply(session_revision=-1).request(dispatch, "session.list", {})
}

///|
/// Load the model directory owned by one dsh session. The reply shares a
/// session-specific ordered lane with selection so an older load cannot undo
/// a choice that completed later.
fn State::load_models(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  session_id : String,
) -> @cmd.Cmd {
  DshModelsReply(session_id).request(dispatch, "session.models", {
    "sessionId": session_id,
  })
}

///|
/// Submit dsh's complete provider/model/reasoning selection; the host remains
/// the authority for route validation and the selected value returned.
fn State::select_model(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  session_id : String,
  selection : DshModelSelection,
) -> @cmd.Cmd {
  let payload : Map[String, Json] = {
    "sessionId": Json::string(session_id),
    "provider": Json::string(selection.provider),
    "model": Json::string(selection.model),
  }
  if selection.reasoning_effort is Some(reasoning_effort) {
    payload["reasoningEffort"] = Json::string(reasoning_effort)
  }
  DshSelectModelReply(session_id~).request(
    dispatch,
    "session.selectModel",
    Json::object(payload),
  )
}

///|
fn State::create_session(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  workspace_id : String,
  selection_generation : Int,
) -> @cmd.Cmd {
  DshCreateReply(selection_generation).request(dispatch, "session.create", {
    "workspaceId": workspace_id,
  })
}

///|
fn State::create_workspace_session(
  self : State,
  dispatch : @cmd.Emit[Msg],
  path : String,
) -> @cmd.Cmd {
  DshWorkspaceCreateReply(self.selection_generation).request(
    dispatch,
    "workspace.create",
    { "path": path },
  )
}

///|
/// Ask the Desktop host to create or recover the checkout durably owned by
/// this dsh session. dsh sees the path only after this host operation commits.
fn State::create_worktree(
  self : State,
  dispatch : @cmd.Emit[Msg],
  session_id : String,
  generation : Int,
  project : String,
) -> @cmd.Cmd {
  let draft : @composer.Draft = { task: self.draft, mentions: self.mentions }
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let result : @protocol.WorktreeCreateResult = @interop.bridge_request(
        @interop.ChannelId::Local,
        @commands.worktree_create,
        {
          workspace: project,
          session: None,
          codex_thread: None,
          dsh_session: Some(session_id),
        },
      ) catch {
        error => {
          scheduler.add(
            dispatch(
              Failed(
                kind=DshPromptReply(session_id~, draft~, generation~),
                message="worktree setup failed: " +
                  @interop.bridge_error_text(error),
              ),
            ),
          )
          return
        }
      }
      let reply = match result {
        @protocol.WorktreeCreatedReply(reply) => reply
        @protocol.WorktreeCreateError(message) => {
          scheduler.add(
            dispatch(
              Failed(
                kind=DshPromptReply(session_id~, draft~, generation~),
                message="worktree setup failed: " + message,
              ),
            ),
          )
          return
        }
      }
      guard reply.worktrees
        .iter()
        .find_first(worktree => {
          worktree.name == reply.name &&
          worktree.dsh_session == Some(session_id) &&
          worktree.present
        })
        is Some(worktree) else {
        scheduler.add(
          dispatch(
            Failed(
              kind=DshPromptReply(session_id~, draft~, generation~),
              message="malformed worktree.create reply",
            ),
          ),
        )
        return
      }
      scheduler.add(
        dispatch(
          WorktreeReady(
            session_id~,
            generation~,
            project~,
            name=reply.name,
            path=worktree.path,
            draft~,
          ),
        ),
      )
    })
  })
}

///|
/// Adopt the already-created checkout into dsh's Workspace registry. This is
/// idempotent by canonical path, so retrying a lost reply creates no duplicate.
fn State::register_prompt_workspace(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  session_id : String,
  generation : Int,
  project : String,
  worktree_name : String,
  worktree_path : String,
  draft : @composer.Draft,
) -> @cmd.Cmd {
  DshPromptWorkspaceReply(
    session_id~,
    generation~,
    project~,
    worktree_name~,
    worktree_path~,
    draft~,
  ).request(dispatch, "workspace.create", { "path": worktree_path })
}

///|
/// Move the original blank conversation instead of creating a replacement in
/// the generated Workspace.
fn State::move_prompt_session(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  session_id : String,
  generation : Int,
  project : String,
  worktree_name : String,
  worktree_path : String,
  workspace_id : String,
  draft : @composer.Draft,
) -> @cmd.Cmd {
  DshPromptMoveReply(
    session_id~,
    generation~,
    project~,
    worktree_name~,
    worktree_path~,
    draft~,
  ).request(dispatch, "workspace.insertSessionBefore", {
    "workspaceId": workspace_id,
    "sessionId": session_id,
  })
}

///|
/// Release the exact host registry binding after dsh rejects setup before the
/// conversation move completes. The checkout and branch stay available for
/// ordinary worktree removal.
fn State::release_failed_worktree(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  session_id : String,
  generation : Int,
  project : String,
  name : String,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let _ : @protocol.EmptyReply = @interop.bridge_request(
        @interop.ChannelId::Local,
        @commands.worktree_release_dsh,
        { workspace: project, name, dsh_session: session_id },
      ) catch {
        error => {
          scheduler.add(
            dispatch(
              WorktreeCleanupFinished(
                session_id~,
                generation~,
                message=Some(@interop.bridge_error_text(error)),
              ),
            ),
          )
          return
        }
      }
      scheduler.add(
        dispatch(
          WorktreeCleanupFinished(session_id~, generation~, message=None),
        ),
      )
    })
  })
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
  let draft : @composer.Draft = { task: self.draft, mentions: self.mentions }
  guard !draft.prompt().is_empty() else { return @cmd.none }
  self.send_prompt(
    dispatch,
    session_id,
    draft,
    generation,
    mode=if self.is_running() { "steer" } else { "queue" },
  )
}

///|
/// Send the immutable submission captured when the user pressed Enter. The
/// worktree setup pipeline can call this after navigation without consulting
/// the newly active session, draft, or running state.
fn State::send_prompt(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  session_id : String,
  draft : @composer.Draft,
  generation : Int,
  mode~ : String,
) -> @cmd.Cmd {
  let text = draft.prompt()
  guard !text.is_empty() else { return @cmd.none }
  DshPromptReply(session_id~, draft~, generation~).request(
    dispatch,
    "session.prompt",
    {
      "sessionId": session_id,
      "mode": mode,
      "content": [{ "type": "text", "text": text }],
    },
  )
}

///|
fn State::cancel(self : State, dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  guard self.active_id is Some(session_id) else { return @cmd.none }
  DshCancelReply(session_id).request(dispatch, "session.cancel", {
    "sessionId": session_id,
  })
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
  DshResponseReply(rpc_id~, session_id~).respond(dispatch, {
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
  DshResponseReply(rpc_id~, session_id~).respond(dispatch, {
    "type": "client-response",
    "rpcId": rpc_id,
    "result": {
      "ok": true,
      "value": { "sessionId": session_id, "answer": { "answers": values } },
    },
  })
}
