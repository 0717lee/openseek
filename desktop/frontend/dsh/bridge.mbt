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
    DshCredentialDescribeReply | DshCredentialSetReply =>
      Some("dsh-credentials")
    DshSettingsDescribeReply | DshSettingsMutateReply => Some("dsh-settings")
    DshReconnectReply | DshWorkspacesReply => Some("dsh-workspace-list")
    DshSessionsReply(..) => Some("dsh-session-list")
    DshHistoryReply(session_id) => Some("dsh-history-" + session_id)
    DshPromptHistoryReply(reconciliation) =>
      Some("dsh-history-" + reconciliation.session_id)
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
      if reply.workspace_accepted == Some(false) {
        // The actor published a newer Workspace membership event while this
        // list was in flight. Its replacement list is already queued on the
        // same lane; never let the rejected rows reach the renderer.
        return
      }
      if (self is DshReconnectReply || self is DshWorkspacesReply) &&
        DshEnvelope(reply.value).value() is Some(_) &&
        reply.workspace_accepted is None {
        scheduler.add(
          dispatch(
            Failed(
              kind=self,
              message="DeepSeek Harness Workspace list omitted its authorization fence",
            ),
          ),
        )
        return
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
  assert_eq(DshCredentialDescribeReply.ordered_lane(), Some("dsh-credentials"))
  assert_eq(DshCredentialSetReply.ordered_lane(), Some("dsh-credentials"))
  assert_eq(DshSettingsDescribeReply.ordered_lane(), Some("dsh-settings"))
  assert_eq(DshSettingsMutateReply.ordered_lane(), Some("dsh-settings"))
  assert_eq(DshWorkspacesReply.ordered_lane(), Some("dsh-workspace-list"))
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
    DshPromptWorkspaceReply(session_id="session-1", generation=1, draft={
      task: "inspect this project",
      mentions: [],
    }).ordered_lane(),
    None,
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
/// Read only dsh's value-free facts for the one credential managed by the
/// Desktop Settings page. The native boundary rejects any other reference.
fn State::load_credential(_self : State, dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  DshCredentialDescribeReply.request(dispatch, "credentials.describe", {
    "refs": [DeepSeekCredentialRef],
  })
}

///|
/// Send the write draft directly to dsh. The response never echoes the secret;
/// a successful write is enough to project a configured file-backed key.
fn State::save_credential(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  value : String,
) -> @cmd.Cmd {
  DshCredentialSetReply.request(dispatch, "credentials.set", {
    "ref": DeepSeekCredentialRef,
    "value": value,
  })
}

///|
/// Read the one settings namespace projected by the native Desktop boundary.
/// dsh returns its complete redacted descriptor; native code reduces that to
/// the endpoint override, fallback, writability, and revision before the
/// browser sees it.
fn State::load_endpoint(_self : State, dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  DshSettingsDescribeReply.request(dispatch, "settings.describe", {})
}

///|
/// Store or remove exactly `llm-deepseek.baseURL` at the descriptor revision
/// the user edited. A blank draft is an unset operation, restoring dsh's
/// composition/environment/public fallback.
fn State::save_endpoint(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  value : String,
  revision : Int,
) -> @cmd.Cmd {
  let operation : Json = if value.is_empty() {
    { "op": "unset", "path": ["baseURL"] }
  } else {
    { "op": "set", "path": ["baseURL"], "value": value }
  }
  DshSettingsMutateReply.request(dispatch, "settings.mutate", {
    "ns": DeepSeekSettingsNamespace,
    "ops": [operation],
    "expectedRevision": Json::number(revision.to_double()),
  })
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
/// Ask the Desktop host for a fresh checkout to run this conversation in. The
/// session id authorizes the request against dsh's own Workspace list; the
/// resulting checkout is recorded with no owner, so there is nothing here to
/// reconcile, release, or leak.
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
      let payload : @protocol.WorktreeCreatePayload = {
        workspace: project,
        session: None,
        codex_thread: None,
        dsh_session: Some(session_id),
      }
      let result : @protocol.WorktreeCreateResult = @interop.bridge_request(
        @interop.ChannelId::Local,
        @commands.worktree_create,
        payload,
      ) catch {
        error => {
          // An unowned create has no idempotency key, so repeating it after a
          // lost reply would provision a second checkout rather than recover
          // the first. Report the failure instead and say so plainly: whatever
          // this call may have created is an ordinary spare checkout the user
          // can remove from the worktree list.
          let detail = @interop.bridge_error_text(error)
          let message = if @interop.bridge_failure(error) is Unknown {
            "worktree setup did not confirm; check the worktree list for an unused checkout: " +
            detail
          } else {
            "worktree setup failed: " + detail
          }
          scheduler.add(
            dispatch(
              Failed(
                kind=DshPromptReply(session_id~, draft~, generation~),
                message~,
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
        .find_first(worktree => worktree.name == reply.name && worktree.present)
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
  worktree_path : String,
  draft : @composer.Draft,
) -> @cmd.Cmd {
  DshPromptWorkspaceReply(session_id~, generation~, draft~).request(
    dispatch,
    "workspace.create",
    { "path": worktree_path },
  )
}

///|
/// Start the conversation inside the generated Workspace.
///
/// dsh has no operation that moves an existing conversation to another
/// directory. A session's cwd is fixed in its header when it is created, and
/// Workspace membership is derived from that cwd rather than stored:
/// `sessionIds` filters on `sessionPath(id) == record.path`, `attachSession`
/// refuses a session whose cwd resolves elsewhere, and `insertSessionBefore`
/// only reorders sessions a Workspace already accounts for. Creating the
/// session against `workspaceId` is what makes it belong here — dsh takes its
/// cwd from the Workspace path and attaches it in the same call.
///
/// `session_id` remains on the reply as the submission's origin: the composer
/// fence, the draft snapshot, and every failure message stay keyed to the
/// conversation the user typed in, even though the prompt goes to the session
/// this call creates. That blank conversation keeps its own directory.
fn State::create_prompt_session(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  session_id : String,
  generation : Int,
  workspace_id : String,
  draft : @composer.Draft,
) -> @cmd.Cmd {
  DshPromptSessionReply(session_id~, generation~, draft~).request(
    dispatch,
    "session.create",
    { "workspaceId": workspace_id },
  )
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
/// Re-read only the authoritative tail after a final prompt reply was lost.
/// This operation is side-effect-free, so Refresh may repeat it until a valid
/// history response decides whether the immutable submission was accepted.
fn DshPromptReconciliation::request(
  self : DshPromptReconciliation,
  dispatch : @cmd.Emit[Msg],
) -> @cmd.Cmd {
  DshPromptHistoryReply(self).request(dispatch, "session.history", {
    "sessionId": self.session_id,
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
  self : State,
  dispatch : @cmd.Emit[Msg],
  session_id : String,
  draft : @composer.Draft,
  generation : Int,
  mode~ : String,
) -> @cmd.Cmd {
  let text = draft.prompt()
  guard !text.is_empty() else { return @cmd.none }
  let reconciliation : DshPromptReconciliation = {
    session_id,
    draft,
    generation,
    after_seq: self.prompt_after_seq,
    transport_message: "",
  }
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let request : @protocol.DshRequestPayload = {
        method_: "session.prompt",
        payload: {
          "sessionId": session_id,
          "mode": mode,
          "content": [{ "type": "text", "text": text }],
        },
      }
      let reply : @protocol.DshValueReply = @interop.bridge_request(
        @interop.ChannelId::Local,
        @commands.dsh_request,
        request,
      ) catch {
        error => {
          let message = @interop.bridge_error_text(error)
          scheduler.add(
            dispatch(
              match @interop.bridge_failure(error) {
                Refused | Unsent =>
                  Failed(
                    kind=DshPromptReply(session_id~, draft~, generation~),
                    message~,
                  )
                Unknown =>
                  PromptDeliveryUnknown({
                    ..reconciliation,
                    transport_message: message,
                  })
              },
            ),
          )
          return
        }
      }
      scheduler.add(
        dispatch(
          Reply(
            kind=DshPromptReply(session_id~, draft~, generation~),
            value=reply.value,
          ),
        ),
      )
    })
  })
}

///|
/// Hide one conversation. dsh answers with its complete new archive set, so
/// the reply replaces the page's copy rather than editing it.
fn State::archive_session(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  session_id : String,
) -> @cmd.Cmd {
  DshArchiveReply.request(dispatch, "workspace.archiveSession", {
    "sessionId": session_id,
  })
}

///|
/// Drop one Workspace registration. dsh keeps the directory and every session
/// log; the sessions it grouped become ungrouped rather than disappearing.
fn State::remove_workspace(
  _self : State,
  dispatch : @cmd.Emit[Msg],
  workspace_id : String,
) -> @cmd.Cmd {
  DshWorkspaceDeleteReply.request(dispatch, "workspace.delete", {
    "workspaceId": workspace_id,
  })
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
