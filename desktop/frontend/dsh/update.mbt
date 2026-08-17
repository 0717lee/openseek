// All dsh-local transitions. Full ApiProxy envelopes and WebSocket frames are
// decoded here, never in the root OpenSeek model.

///|
pub fn update(
  dispatch : @cmd.Emit[Msg],
  msg : Msg,
  state : State,
) -> (@cmd.Cmd, State) {
  match msg {
    Refresh => {
      let commands = [state.refresh(dispatch)]
      if state.prompt_reconciliation is Some(reconciliation) {
        // Refresh is the explicit recovery gesture after a read-only history
        // failure. Re-run the proof without releasing the submission fence.
        commands.push(reconciliation.request(dispatch))
      }
      let models = if state.connection is DshReady &&
        state.active_id is Some(session_id) {
        commands.push(state.load_models(dispatch, session_id))
        DshModelsLoading(session_id~)
      } else {
        state.models
      }
      (@cmd.batch(commands), { ..state, models, loading: true, notice: "" })
    }
    NewSession(workspace_id) =>
      if state.creation_pending {
        (@cmd.none, state)
      } else if workspace_id is Some(workspace_id) {
        (
          state.create_session(
            dispatch,
            workspace_id,
            state.selection_generation,
          ),
          { ..state, creation_pending: true, loading: true, notice: "" },
        )
      } else {
        (
          @cmd.none,
          {
            ..state,
            loading: false,
            notice: "Create or select a DeepSeek Harness workspace first",
          },
        )
      }
    NewWorkspaceSession(path) =>
      if state.creation_pending {
        (@cmd.none, state)
      } else if path.trim().is_empty() {
        (
          @cmd.none,
          {
            ..state,
            loading: false,
            notice: "Cannot create a DeepSeek Harness workspace without a path",
          },
        )
      } else {
        (
          state.create_workspace_session(dispatch, path),
          { ..state, creation_pending: true, loading: true, notice: "" },
        )
      }
    OpenSession(session_id) => {
      let selection_changed = state.active_id != Some(session_id)
      let selection_generation = if selection_changed {
        state.selection_generation + 1
      } else {
        state.selection_generation
      }
      let failed_prompt = state.failed_prompts.get(session_id)
      (
        @cmd.batch([
          state.load_history(dispatch, session_id),
          state.load_models(dispatch, session_id),
        ]),
        {
          ..state,
          active_id: Some(session_id),
          selection_generation,
          draft: if selection_changed {
            failed_prompt.map(prompt => prompt.draft.task).unwrap_or("")
          } else {
            state.draft
          },
          mentions: if selection_changed {
            failed_prompt.map(prompt => prompt.draft.mentions).unwrap_or([])
          } else {
            state.mentions
          },
          events: [],
          event_sequence: -1,
          streaming: "",
          models: DshModelsLoading(session_id~),
          placement: if selection_changed {
            @composer.LocalCheckout
          } else {
            state.placement
          },
          worktree_project: if selection_changed {
            None
          } else {
            state.worktree_project
          },
          loading: true,
          notice: if selection_changed {
            failed_prompt.map(prompt => prompt.message).unwrap_or("")
          } else {
            ""
          },
        },
      )
    }
    ComposerAction(action) => state.apply_composer_action(dispatch, action)
    ToggleWorktreeMode =>
      if state.busy() || state.is_running() || !state.active_blank() {
        (@cmd.none, state)
      } else {
        match (state.placement, state.active_workspace_path()) {
          (@composer.LocalCheckout, Some(project)) =>
            (
              @cmd.none,
              {
                ..state,
                placement: @composer.FreshWorktree,
                worktree_project: Some(project),
                notice: "",
              },
            )
          (@composer.FreshWorktree, _) =>
            (
              @cmd.none,
              {
                ..state,
                placement: @composer.LocalCheckout,
                worktree_project: None,
                notice: "",
              },
            )
          (@composer.BoundWorktree(_), _) | (_, None) => (@cmd.none, state)
        }
      }
    ModelChanged(key) => {
      guard state.active_id is Some(session_id) &&
        !state.busy() &&
        !state.is_running() &&
        state.models.option(session_id, key) is Some(option) else {
        return (@cmd.none, state)
      }
      (
        state.select_model(dispatch, session_id, option.selection),
        {
          ..state,
          models: state.models.selecting(session_id, option.selection),
          notice: "",
        },
      )
    }
    WorktreeReady(session_id~, generation~, project~, path~, draft~) => {
      guard state.owns_submission(session_id, generation) else {
        return (@cmd.none, state)
      }
      (
        state.register_prompt_workspace(
          dispatch, session_id, generation, path, draft,
        ),
        if state.active_id == Some(session_id) {
          { ..state, worktree_project: Some(project), loading: true }
        } else {
          // The immutable first-send pipeline continues for its originating
          // conversation without changing the newly selected page.
          state
        },
      )
    }
    PromptDeliveryUnknown(reconciliation) => {
      guard state.prompt_generation == reconciliation.generation &&
        state.prompt_pending_session == Some(reconciliation.session_id) else {
        return (@cmd.none, state)
      }
      (
        reconciliation.request(dispatch),
        {
          ..state,
          prompt_reconciliation: Some(reconciliation),
          loading: if state.active_id == Some(reconciliation.session_id) {
            true
          } else {
            state.loading
          },
          notice: if state.active_id == Some(reconciliation.session_id) {
            "Verifying whether DeepSeek Harness accepted the prompt…"
          } else {
            state.notice
          },
        },
      )
    }
    Send =>
      if state.busy() ||
        state.submission_empty() ||
        state.active_id is None ||
        !state.models.routable(state.active_id.unwrap()) {
        (@cmd.none, state)
      } else {
        let generation = state.prompt_generation + 1
        // Build the next state before the command: a worktree pipeline may
        // reach `send_prompt` after navigation, but the final reconciliation
        // baseline must remain the originating conversation's sequence.
        let sending = {
          ..state,
          prompt_generation: generation,
          prompt_pending_session: state.active_id,
          prompt_after_seq: state.event_sequence,
          prompt_reconciliation: None,
          failed_prompts: match state.active_id {
            Some(session_id) => state.failed_prompts.remove(session_id)
            None => state.failed_prompts
          },
          loading: true,
          notice: "",
        }
        let command = if sending.active_blank() &&
          sending.placement.wants_fresh() &&
          sending.worktree_project is Some(project) &&
          sending.active_id is Some(session_id) {
          sending.create_worktree(dispatch, session_id, generation, project)
        } else {
          sending.send(dispatch, generation)
        }
        (command, sending)
      }
    Stop =>
      if state.busy() || !state.is_running() {
        (@cmd.none, state)
      } else {
        (
          state.cancel(dispatch),
          {
            ..state,
            cancel_pending_sessions: match state.active_id {
              Some(id) => state.cancel_pending_sessions + [id]
              None => state.cancel_pending_sessions
            },
            loading: true,
            notice: "",
          },
        )
      }
    ApprovalDecision(rpc_id~, outcome~) =>
      match
        (
          state.pending_for_rpc(rpc_id),
          state.response_pending_rpcs.contains(rpc_id),
        ) {
        (_, true) => (@cmd.none, state)
        (Some(pending), false) =>
          (
            state.respond_approval(
              dispatch,
              rpc_id,
              if outcome == "allowed-once" {
                "allowed-once"
              } else {
                "rejected"
              },
              pending,
            ),
            {
              ..state,
              response_pending_rpcs: state.response_pending_rpcs + [rpc_id],
              loading: true,
              notice: "",
            },
          )
        (None, false) => (@cmd.none, state)
      }
    QuestionOption(rpc_id~, question_id~, label~) =>
      (@cmd.none, state.with_question_option(rpc_id, question_id, label))
    QuestionCustom(rpc_id~, question_id~, value~) =>
      (@cmd.none, state.with_question_custom(rpc_id, question_id, value))
    SubmitQuestions(rpc_id) =>
      match
        (
          state.pending_for_rpc(rpc_id),
          state.response_pending_rpcs.contains(rpc_id),
        ) {
        (_, true) => (@cmd.none, state)
        (Some(pending), false) if pending.questions_answered() =>
          (
            state.respond_questions(dispatch, rpc_id, pending),
            {
              ..state,
              response_pending_rpcs: state.response_pending_rpcs + [rpc_id],
              loading: true,
              notice: "",
            },
          )
        _ => (@cmd.none, state)
      }
    ArchiveSession(session_id) =>
      if state.busy() {
        (@cmd.none, state)
      } else {
        (
          state.archive_session(dispatch, session_id),
          { ..state, loading: true, notice: "" },
        )
      }
    RemoveWorkspace(workspace_id) =>
      if state.busy() {
        (@cmd.none, state)
      } else {
        (
          state.remove_workspace(dispatch, workspace_id),
          { ..state, loading: true, notice: "" },
        )
      }
    Reply(kind~, value~) => {
      if kind.prompt_origin() is Some((_, generation)) {
        if state.prompt_generation != generation {
          return (@cmd.none, state)
        }
      }
      // dsh reports application failures inside successful HTTP responses.
      // Apply the same origin checks used by `Failed` before `with_reply`
      // reaches its generic business-error envelope branch.
      if kind is DshHistoryReply(session_id) &&
        state.active_id != Some(session_id) {
        return (@cmd.none, state)
      }
      // Model requests use per-session lanes. Their successful values already
      // guard inside `with_reply`; apply that same guard before a business
      // error can reach the generic notice branch.
      if kind.model_session() is Some(session_id) &&
        state.active_id != Some(session_id) {
        return (@cmd.none, state)
      }
      if kind is DshCancelReply(session_id) &&
        state.active_id != Some(session_id) {
        return (
          @cmd.none,
          {
            ..state,
            cancel_pending_sessions: state.cancel_pending_sessions.filter(id => {
              id != session_id
            }),
          },
        )
      }
      state.with_reply(dispatch, kind, value)
    }
    Failed(kind~, message~) => {
      if kind is DshPromptHistoryReply(reconciliation) {
        guard state.prompt_generation == reconciliation.generation &&
          state.prompt_pending_session == Some(reconciliation.session_id) else {
          return (@cmd.none, state)
        }
        // A read failure is not evidence about prompt admission. Keep the
        // global fence and immutable draft; Refresh repeats this safe query.
        return (
          @cmd.none,
          {
            ..state,
            prompt_reconciliation: Some({
              ..reconciliation,
              transport_message: message,
            }),
            loading: if state.active_id == Some(reconciliation.session_id) {
              false
            } else {
              state.loading
            },
            notice: if state.active_id == Some(reconciliation.session_id) {
              "Could not verify whether DeepSeek Harness accepted the prompt; Refresh to retry verification: " +
              message
            } else {
              state.notice
            },
          },
        )
      }
      let failed_prompts = match kind.prompt_draft() {
        Some((session_id, draft)) =>
          state.failed_prompts.put(session_id, draft, message)
        None => state.failed_prompts
      }
      // A reply belongs to the page state that submitted it. Session changes
      // and later sends must not clear another conversation's draft/loading.
      if kind.prompt_origin() is Some((session_id, generation)) {
        if state.prompt_generation != generation {
          return (@cmd.none, state)
        }
        if state.active_id != Some(session_id) {
          // No failure leaves cleanup work behind any more, so every stage
          // settles its global submission fence even after navigation while
          // preserving the newly selected conversation's draft and notice.
          return (
            @cmd.none,
            {
              ..state,
              failed_prompts,
              prompt_reconciliation: None,
              prompt_pending_session: if state.prompt_pending_session ==
                Some(session_id) {
                None
              } else {
                state.prompt_pending_session
              },
            },
          )
        }
      }
      // History lanes are ordered only within one session. A failure from a
      // previously open session must not clear or annotate the current page.
      if kind is DshHistoryReply(session_id) &&
        state.active_id != Some(session_id) {
        return (@cmd.none, state)
      }
      if kind is DshCancelReply(session_id) &&
        state.active_id != Some(session_id) {
        return (
          @cmd.none,
          {
            ..state,
            cancel_pending_sessions: state.cancel_pending_sessions.filter(id => {
              id != session_id
            }),
          },
        )
      }
      if kind is DshResponseReply(rpc_id~, session_id~) &&
        state.active_id != Some(session_id) {
        return (
          @cmd.none,
          {
            ..state,
            response_pending_rpcs: state.response_pending_rpcs.filter(id => {
              id != rpc_id
            }),
          },
        )
      }
      if kind is DshCreateReply(selection_generation) &&
        state.selection_generation != selection_generation {
        return (@cmd.none, { ..state, creation_pending: false })
      }
      if kind is DshWorkspaceCreateReply(selection_generation) &&
        state.selection_generation != selection_generation {
        return (@cmd.none, { ..state, creation_pending: false })
      }
      if kind.model_session() is Some(session_id) &&
        state.active_id != Some(session_id) {
        return (@cmd.none, state)
      }
      (
        @cmd.none,
        {
          ..state,
          failed_prompts,
          prompt_reconciliation: if kind.prompt_origin() is Some(_) {
            None
          } else {
            state.prompt_reconciliation
          },
          connection: if kind is DshStatusReply {
            DshUnavailable(message)
          } else {
            state.connection
          },
          loading: if kind is DshPendingReply || kind.model_session() is Some(_) {
            state.loading
          } else {
            false
          },
          prompt_pending_session: if kind.prompt_origin() is Some(_) {
            None
          } else {
            state.prompt_pending_session
          },
          response_pending_rpcs: match kind {
            DshResponseReply(rpc_id~, ..) =>
              state.response_pending_rpcs.filter(id => id != rpc_id)
            _ => state.response_pending_rpcs
          },
          creation_pending: if kind is DshCreateReply(_) ||
            kind is DshWorkspaceCreateReply(_) {
            false
          } else {
            state.creation_pending
          },
          cancel_pending_sessions: match kind {
            DshCancelReply(session_id) =>
              state.cancel_pending_sessions.filter(id => id != session_id)
            _ => state.cancel_pending_sessions
          },
          models: if kind.model_session() is Some(session_id) {
            state.models.failed(session_id)
          } else {
            state.models
          },
          // Connection failures belong to the root toast queue. Other dsh
          // request failures remain attached to the dsh transcript surface.
          // A reconnect request is paired with the actor's authoritative
          // status notification, so its transport rejection adds no second
          // toast or transcript error.
          notice: if kind is DshStatusReply || kind is DshReconnectReply {
            ""
          } else {
            message
          },
        },
      )
    }
    StatusChanged(value) => state.with_status(dispatch, value)
    Event(value) => state.with_event(dispatch, value)
  }
}

///|
/// Settle one dsh reply without letting an independent success erase a newer
/// diagnostic. User actions clear the preceding notice before dispatch; list,
/// history, and model snapshots therefore preserve any notice present when
/// they complete.
fn State::with_reply(
  self : State,
  dispatch : @cmd.Emit[Msg],
  kind : DshReplyKind,
  reply : Json,
) -> (@cmd.Cmd, State) {
  if kind is DshStatusReply {
    return self.with_status(dispatch, reply)
  }
  if kind is DshPendingReply {
    return self.with_pending_snapshot(dispatch, reply)
  }
  if kind is DshResponseReply(rpc_id~, session_id~) {
    let receipt = DshResponseReceipt(reply)
    let response_pending_rpcs = self.response_pending_rpcs.filter(id => {
      id != rpc_id
    })
    guard receipt.accepted() else {
      if self.active_id == Some(session_id) {
        return (
          @cmd.none,
          {
            ..self,
            response_pending_rpcs,
            loading: false,
            notice: receipt.error(),
          },
        )
      }
      return (@cmd.none, { ..self, response_pending_rpcs, })
    }
    let generation = receipt.generation().unwrap()
    let pending = self.pending.filter(item => item.rpc_id() != rpc_id)
    let settled_interactions = self.settled_interactions.filter(item => {
      item.rpc_id != rpc_id
    })
    settled_interactions.push({ rpc_id, generation })
    return (
      @cmd.none,
      if self.active_id == Some(session_id) {
        {
          ..self,
          pending,
          settled_interactions,
          response_pending_rpcs,
          loading: false,
        }
      } else {
        { ..self, pending, settled_interactions, response_pending_rpcs }
      },
    )
  }
  let envelope = DshEnvelope(reply)
  if kind is DshPromptHistoryReply(reconciliation) {
    guard self.prompt_generation == reconciliation.generation &&
      self.prompt_pending_session == Some(reconciliation.session_id) else {
      return (@cmd.none, self)
    }
    guard envelope.value() is Some(history) else {
      // A business or malformed envelope is no more authoritative than a
      // transport failure. Preserve the draft and fence until Refresh can
      // obtain a valid history page.
      return (
        @cmd.none,
        {
          ..self,
          prompt_reconciliation: Some(reconciliation),
          loading: if self.active_id == Some(reconciliation.session_id) {
            false
          } else {
            self.loading
          },
          notice: if self.active_id == Some(reconciliation.session_id) {
            "Could not verify whether DeepSeek Harness accepted the prompt; Refresh to retry verification: " +
            envelope.error()
          } else {
            self.notice
          },
        },
      )
    }
    match reconciliation.accepted(history) {
      Some(true) =>
        // The history record is the durable receipt. Reuse normal prompt
        // settlement so draft edits/navigation retain their existing rules.
        return { ..self, prompt_reconciliation: None }.with_reply(
          dispatch,
          DshPromptReply(
            session_id=reconciliation.session_id,
            draft=reconciliation.draft,
            generation=reconciliation.generation,
          ),
          reply,
        )
      Some(false) =>
        return update(
          dispatch,
          Failed(
            kind=DshPromptReply(
              session_id=reconciliation.session_id,
              draft=reconciliation.draft,
              generation=reconciliation.generation,
            ),
            message="DeepSeek Harness did not record the prompt after its reply was lost: " +
              reconciliation.transport_message,
          ),
          { ..self, prompt_reconciliation: None },
        )
      None =>
        return (
          @cmd.none,
          {
            ..self,
            prompt_reconciliation: Some(reconciliation),
            loading: if self.active_id == Some(reconciliation.session_id) {
              false
            } else {
              self.loading
            },
            notice: if self.active_id == Some(reconciliation.session_id) {
              "DeepSeek Harness returned malformed history while verifying the prompt; Refresh to retry verification"
            } else {
              self.notice
            },
          },
        )
    }
  }
  guard envelope.value() is Some(value) else {
    // A successful create reply still has global work to do after navigation:
    // workspace.create must continue to session.create, and session.create
    // must refresh the lists. Only stale business errors stop here.
    if kind is DshCreateReply(selection_generation) &&
      self.selection_generation != selection_generation {
      return (@cmd.none, { ..self, creation_pending: false })
    }
    if kind is DshWorkspaceCreateReply(selection_generation) &&
      self.selection_generation != selection_generation {
      return (@cmd.none, { ..self, creation_pending: false })
    }
    let background_prompt = kind
      .prompt_origin()
      .map(origin => self.active_id != Some(origin.0))
      .unwrap_or(false)
    let failed_prompts = match kind.prompt_draft() {
      Some((session_id, draft)) =>
        self.failed_prompts.put(session_id, draft, envelope.error())
      None => self.failed_prompts
    }
    return (
      @cmd.none,
      {
        ..self,
        failed_prompts,
        prompt_pending_session: if kind.prompt_origin() is Some(_) {
          None
        } else {
          self.prompt_pending_session
        },
        creation_pending: if kind is DshCreateReply(_) ||
          kind is DshWorkspaceCreateReply(_) {
          false
        } else {
          self.creation_pending
        },
        cancel_pending_sessions: match kind {
          DshCancelReply(session_id) =>
            self.cancel_pending_sessions.filter(id => id != session_id)
          _ => self.cancel_pending_sessions
        },
        models: if kind.model_session() is Some(session_id) {
          self.models.failed(session_id)
        } else {
          self.models
        },
        loading: if background_prompt || kind.model_session() is Some(_) {
          self.loading
        } else {
          false
        },
        notice: if background_prompt {
          self.notice
        } else {
          envelope.error()
        },
      },
    )
  }
  match kind {
    DshReconnectReply | DshWorkspacesReply => {
      let workspaces : Array[DshWorkspaceRow] = []
      let archived_session_ids : Array[String] = []
      if value is Object(fields) {
        if fields.get("items") is Some(Array(items)) {
          for item in items {
            if DshWorkspaceRow::decode(item) is Some(workspace) {
              workspaces.push(workspace)
            }
          }
        }
        // The archive set is registry-global and travels with every list, so
        // it replaces the page's copy whole rather than merging.
        if fields.get("archivedSessionIds") is Some(Array(ids)) {
          for id in ids {
            if id is String(session_id) {
              archived_session_ids.push(session_id)
            }
          }
        }
      }
      (
        if kind is DshReconnectReply {
          @cmd.batch([
            self.list_sessions(dispatch),
            DshPendingReply.pending(dispatch),
          ])
        } else {
          @cmd.none
        },
        { ..self, workspaces, archived_session_ids },
      )
    }
    DshWorkspaceCreateReply(selection_generation) => {
      let current = self.selection_generation == selection_generation
      guard value is Object(fields) &&
        fields.get("workspace") is Some(Object(workspace)) &&
        @jsonx.json_text(workspace, "workspaceId") is Some(workspace_id) else {
        if !current {
          return (@cmd.none, { ..self, creation_pending: false })
        }
        return (
          @cmd.none,
          {
            ..self,
            creation_pending: false,
            loading: false,
            notice: "DeepSeek Harness returned a malformed workspace.create reply",
          },
        )
      }
      (
        @cmd.batch([
          DshWorkspacesReply.request(dispatch, "workspace.list", {}),
          self.create_session(dispatch, workspace_id, selection_generation),
        ]),
        if current {
          { ..self, creation_pending: true, loading: true, notice: "" }
        } else {
          { ..self, creation_pending: true }
        },
      )
    }
    DshSessionsReply(session_revision~) => {
      let sessions : Array[DshSessionRow] = []
      if value is Object(fields) && fields.get("items") is Some(Array(items)) {
        for item in items {
          if DshSessionRow::decode(item) is Some(row) {
            let row = if self.session_statuses
              .iter()
              .find_first(status => {
                status.session_id == row.id &&
                status.revision > session_revision
              })
              is Some(status) {
              let blank = self.sessions
                .iter()
                .find_first(current => current.id == row.id)
                .map(current => current.blank)
                .unwrap_or(if status.running { false } else { row.blank })
              { ..row, running: status.running, blank }
            } else {
              row
            }
            let row = if self.session_titles
              .iter()
              .find_first(title => {
                title.session_id == row.id && title.revision > session_revision
              })
              is Some(title) {
              { ..row, title: title.title }
            } else {
              row
            }
            sessions.push(row)
          }
        }
      }
      let active_id = match self.active_id {
        Some(id) if sessions.iter().any(row => row.id == id) => Some(id)
        _ => sessions.get(0).map(row => row.id)
      }
      let selection_changed = self.active_id != active_id
      let failed_prompt = match active_id {
        Some(session_id) => self.failed_prompts.get(session_id)
        None => None
      }
      let next = {
        ..self,
        sessions,
        active_id,
        selection_generation: if selection_changed {
          self.selection_generation + 1
        } else {
          self.selection_generation
        },
        draft: if selection_changed {
          failed_prompt.map(prompt => prompt.draft.task).unwrap_or("")
        } else {
          self.draft
        },
        mentions: if selection_changed {
          failed_prompt.map(prompt => prompt.draft.mentions).unwrap_or([])
        } else {
          self.mentions
        },
        events: if selection_changed {
          []
        } else {
          self.events
        },
        streaming: if selection_changed {
          ""
        } else {
          self.streaming
        },
        models: if selection_changed && active_id is Some(session_id) {
          DshModelsLoading(session_id~)
        } else {
          self.models
        },
        placement: if selection_changed {
          @composer.LocalCheckout
        } else {
          self.placement
        },
        worktree_project: if selection_changed {
          None
        } else {
          self.worktree_project
        },
        loading: false,
        notice: if selection_changed {
          failed_prompt.map(prompt => prompt.message).unwrap_or("")
        } else {
          self.notice
        },
      }
      match active_id {
        Some(id) if selection_changed =>
          (
            @cmd.batch([
              next.load_history(dispatch, id),
              next.load_models(dispatch, id),
            ]),
            { ..next, loading: true },
          )
        _ => (@cmd.none, next)
      }
    }
    DshCreateReply(selection_generation) => {
      let activate = self.selection_generation == selection_generation
      guard value is Object(fields) &&
        @jsonx.json_text(fields, "sessionId") is Some(session_id) else {
        if !activate {
          return (@cmd.none, { ..self, creation_pending: false })
        }
        return (
          @cmd.none,
          {
            ..self,
            creation_pending: false,
            loading: false,
            notice: "DeepSeek Harness returned a malformed session.create reply",
          },
        )
      }
      let commands = [
        DshWorkspacesReply.request(dispatch, "workspace.list", {}),
        self.list_sessions(dispatch),
      ]
      if activate {
        commands.push(self.load_history(dispatch, session_id))
        commands.push(self.load_models(dispatch, session_id))
      }
      (
        @cmd.batch(commands),
        if activate {
          {
            ..self,
            active_id: Some(session_id),
            selection_generation: self.selection_generation + 1,
            creation_pending: false,
            draft: "",
            events: [],
            event_sequence: -1,
            streaming: "",
            models: DshModelsLoading(session_id~),
            placement: @composer.LocalCheckout,
            worktree_project: None,
            loading: true,
            notice: "",
            mentions: [],
          }
        } else {
          { ..self, creation_pending: false }
        },
      )
    }
    DshHistoryReply(session_id) => {
      guard self.active_id == Some(session_id) else { return (@cmd.none, self) }
      let events : Array[DshEventRecord] = []
      if value is Object(fields) && fields.get("events") is Some(Array(entries)) {
        for entry in entries {
          if entry is Object(entry_fields) &&
            entry_fields.get("event") is Some(event) &&
            DshEventRecord::decode(event) is Some(decoded) {
            events.push(decoded)
          }
        }
      }
      // A live WebSocket event can arrive while this HTTP snapshot is in
      // flight. Merge by dsh's per-session seq before replacing the view so a
      // slower history reply cannot roll that event back out of the page.
      // Older entries absent from the newest-200 window stay absent instead
      // of making this bounded page grow forever across refreshes.
      let snapshot_last = events
        .iter()
        .fold(init=-1, (last, event) => {
          if event.seq > last {
            event.seq
          } else {
            last
          }
        })
      for event in self.events {
        if event.seq > snapshot_last &&
          !events.iter().any(item => item.seq == event.seq) {
          events.push(event)
        }
      }
      events.sort_by((left, right) => left.seq - right.seq)
      // Rebuild from the complete snapshot before dropping transient chunks.
      // If a newer WebSocket event arrived while history was in flight, the
      // incremental projection already includes it and must win over the
      // older HTTP baseline even though its chunk is not retained in events.
      let snapshot_streaming = DshEventLog(events).streaming_text()
      let streaming = if self.event_sequence > snapshot_last {
        self.streaming
      } else {
        snapshot_streaming
      }
      let retained = events.filter(event => event.retained())
      events.clear()
      for event in retained {
        events.push(event)
      }
      while events.length() > DshEventWindowCapacity {
        ignore(events.remove(0))
      }
      (
        @cmd.none,
        {
          ..self,
          streaming,
          events,
          event_sequence: if self.event_sequence > snapshot_last {
            self.event_sequence
          } else {
            snapshot_last
          },
          loading: false,
        },
      )
    }
    DshModelsReply(session_id) => {
      guard self.active_id == Some(session_id) else { return (@cmd.none, self) }
      guard DshModels::decode(session_id, value) is Some(models) else {
        return (
          @cmd.none,
          {
            ..self,
            models: self.models.failed(session_id),
            notice: "DeepSeek Harness returned a malformed session.models reply",
          },
        )
      }
      // The action that started this request already cleared the preceding
      // notice. Preserve any diagnostic produced while this independent model
      // snapshot was in flight; it necessarily belongs to newer work.
      (@cmd.none, { ..self, models, })
    }
    DshSelectModelReply(session_id~) => {
      guard self.active_id == Some(session_id) else { return (@cmd.none, self) }
      guard value is Object(fields) &&
        fields.get("selected") is Some(selected_json) &&
        DshModelSelection::decode(selected_json) is Some(selected) &&
        self.models.selected(session_id, selected) is Some(models) else {
        return (
          @cmd.none,
          {
            ..self,
            models: self.models.failed(session_id),
            notice: "DeepSeek Harness returned a malformed session.selectModel reply",
          },
        )
      }
      // ModelChanged cleared the old notice before dispatch. A notice present
      // now was produced concurrently and must not be erased by this reply.
      (@cmd.none, { ..self, models, })
    }
    DshPromptWorkspaceReply(session_id~, generation~, draft~) => {
      // Every setup stage carries the submission it belongs to, and each one
      // is a durable side effect on dsh — a Workspace, then a conversation.
      // A stage whose submission is already over must not continue building
      // for it, so an abandoned pipeline stops at the stage it reached.
      guard self.owns_submission(session_id, generation) else {
        return (@cmd.none, self)
      }
      guard value is Object(fields) &&
        fields.get("workspace") is Some(Object(workspace)) &&
        @jsonx.json_text(workspace, "workspaceId") is Some(workspace_id) else {
        let message = "DeepSeek Harness returned a malformed workspace.create reply"
        let failed_prompts = self.failed_prompts.put(session_id, draft, message)
        let settled = {
          ..self,
          failed_prompts,
          prompt_pending_session: if self.prompt_pending_session ==
            Some(session_id) {
            None
          } else {
            self.prompt_pending_session
          },
        }
        return if self.active_id == Some(session_id) {
          (@cmd.none, { ..settled, loading: false, notice: message })
        } else {
          (@cmd.none, settled)
        }
      }
      (
        self.create_prompt_session(
          dispatch, session_id, generation, workspace_id, draft,
        ),
        self,
      )
    }
    DshPromptSessionReply(session_id~, generation~, draft~) => {
      guard self.owns_submission(session_id, generation) else {
        return (@cmd.none, self)
      }
      guard value is Object(fields) &&
        @jsonx.json_text(fields, "sessionId") is Some(created) else {
        let message = "DeepSeek Harness returned a malformed session.create reply"
        let failed_prompts = self.failed_prompts.put(session_id, draft, message)
        let settled = {
          ..self,
          failed_prompts,
          prompt_pending_session: if self.prompt_pending_session ==
            Some(session_id) {
            None
          } else {
            self.prompt_pending_session
          },
        }
        return if self.active_id == Some(session_id) {
          (@cmd.none, { ..settled, loading: false, notice: message })
        } else {
          (@cmd.none, settled)
        }
      }
      // The prompt belongs to the session dsh just created in the worktree, so
      // the submission fence moves with it. The originating blank conversation
      // keeps its own directory and its place in the sidebar. Build the state
      // before the commands: `send_prompt` reads the reconciliation baseline
      // off it, and that baseline now belongs to a conversation with no events.
      let follow = self.active_id == Some(session_id)
      let next = if follow {
        {
          ..self,
          active_id: Some(created),
          selection_generation: self.selection_generation + 1,
          prompt_pending_session: Some(created),
          // Selecting the created session resets placement the way every
          // other selection does. Leaving Worktree armed on a conversation
          // that already lives in one would make its next message provision a
          // second checkout as soon as a list reply reports it blank again.
          placement: @composer.LocalCheckout,
          worktree_project: None,
          events: [],
          event_sequence: -1,
          prompt_after_seq: -1,
          streaming: "",
          models: DshModelsLoading(session_id=created),
          loading: true,
        }
      } else {
        { ..self, prompt_pending_session: Some(created), prompt_after_seq: -1 }
      }
      let commands = [
        next.send_prompt(dispatch, created, draft, generation, mode="queue"),
        // The grant table is rebuilt only from workspace.list, so Files and
        // Terminal reach the new checkout only after this refresh; the session
        // list is what shows the created conversation under it.
        DshWorkspacesReply.request(dispatch, "workspace.list", {}),
        next.list_sessions(dispatch),
      ]
      if follow {
        commands.push(next.load_models(dispatch, created))
      }
      (@cmd.batch(commands), next)
    }
    DshPromptReply(session_id~, draft~, generation~) => {
      guard self.prompt_generation == generation else {
        return (@cmd.none, self)
      }
      if self.active_id != Some(session_id) {
        // A successful background submission has no visible page state to
        // reconcile, but it still settles this session's retry snapshot.
        return (
          @cmd.none,
          {
            ..self,
            prompt_pending_session: None,
            prompt_reconciliation: None,
            failed_prompts: self.failed_prompts.remove(session_id),
          },
        )
      }
      let submitted_unchanged = self.draft == draft.task &&
        self.mentions == draft.mentions
      (
        self.load_history(dispatch, session_id),
        {
          ..self,
          draft: if submitted_unchanged {
            ""
          } else {
            self.draft
          },
          mentions: if submitted_unchanged {
            []
          } else {
            self.mentions
          },
          prompt_pending_session: None,
          prompt_reconciliation: None,
          failed_prompts: self.failed_prompts.remove(session_id),
          loading: false,
          notice: "",
        },
      )
    }
    DshCancelReply(session_id) =>
      if self.active_id == Some(session_id) {
        (
          @cmd.none,
          {
            ..self,
            cancel_pending_sessions: self.cancel_pending_sessions.filter(id => {
              id != session_id
            }),
            loading: false,
            notice: "",
          },
        )
      } else {
        (
          @cmd.none,
          {
            ..self,
            cancel_pending_sessions: self.cancel_pending_sessions.filter(id => {
              id != session_id
            }),
          },
        )
      }
    DshArchiveReply(session_id~) => {
      // dsh answers with its complete new archive set. Take it whole, and
      // leave the conversation the user was reading only when it is the one
      // that just went away.
      let archived_session_ids : Array[String] = []
      if value is Object(fields) &&
        fields.get("archivedSessionIds") is Some(Array(ids)) {
        for id in ids {
          if id is String(archived) {
            archived_session_ids.push(archived)
          }
        }
      }
      let left = self.active_id == Some(session_id)
      (
        self.list_sessions(dispatch),
        {
          ..self,
          archived_session_ids,
          active_id: if left {
            None
          } else {
            self.active_id
          },
          events: if left {
            []
          } else {
            self.events
          },
          event_sequence: if left {
            -1
          } else {
            self.event_sequence
          },
          streaming: if left {
            ""
          } else {
            self.streaming
          },
          models: if left {
            DshModelsIdle
          } else {
            self.models
          },
          loading: false,
          notice: "",
        },
      )
    }
    DshWorkspaceDeleteReply =>
      // The registration is gone; its sessions are ungrouped rather than
      // removed. Both baselines have to be re-read to show that.
      (
        @cmd.batch([
          DshWorkspacesReply.request(dispatch, "workspace.list", {}),
          self.list_sessions(dispatch),
        ]),
        { ..self, loading: true, notice: "" },
      )
    DshStatusReply
    | DshPendingReply
    | DshResponseReply(..)
    | DshPromptHistoryReply(_) => (@cmd.none, self)
  }
}

///|
fn State::with_status(
  self : State,
  dispatch : @cmd.Emit[Msg],
  value : Json,
) -> (@cmd.Cmd, State) {
  guard value is Object(fields) &&
    @jsonx.json_int(fields, "revision") is Some(revision) &&
    @jsonx.json_text(fields, "status") is Some(status) else {
    return (
      @cmd.none,
      {
        ..self,
        connection: DshUnavailable("Malformed dsh status"),
        loading: false,
        notice: "",
      },
    )
  }
  if revision < self.connection_status_revision {
    return (@cmd.none, self)
  }
  match status {
    "ready" => {
      let new_ready = !(self.connection is DshReady) ||
        self.connection_status_revision != revision
      let commands = [
        DshWorkspacesReply.request(dispatch, "workspace.list", {}),
        self.list_sessions(dispatch),
        DshPendingReply.pending(dispatch),
      ]
      let models = if new_ready && self.active_id is Some(session_id) {
        commands.push(self.load_models(dispatch, session_id))
        DshModelsLoading(session_id~)
      } else {
        self.models
      }
      (
        @cmd.batch(commands),
        {
          ..self,
          connection: DshReady,
          connection_status_revision: revision,
          // A new Ready revision belongs to a new actor connection. Native
          // grants for the old rows were already revoked before Unavailable;
          // do not project those paths again while workspace.list is pending.
          workspaces: if self.connection is DshReady &&
            self.connection_status_revision == revision {
            self.workspaces
          } else {
            []
          },
          // Models are dsh-owned connection state just like workspaces and
          // sessions. Reload the selected session on every new Ready revision
          // so provider and routing changes made while offline take effect.
          models,
          loading: true,
          notice: "",
        },
      )
    }
    "starting" =>
      (
        @cmd.none,
        {
          ..self,
          connection: DshStarting,
          connection_status_revision: revision,
          pending: [],
          loading: false,
        },
      )
    _ => {
      let message = @jsonx.json_text(fields, "message").unwrap_or(
        "DeepSeek Harness is unavailable",
      )
      (
        @cmd.none,
        {
          ..self,
          connection: DshUnavailable(message),
          connection_status_revision: revision,
          pending: [],
          loading: false,
          notice: "",
        },
      )
    }
  }
}

///|
fn State::with_pending_snapshot(
  self : State,
  dispatch : @cmd.Emit[Msg],
  value : Json,
) -> (@cmd.Cmd, State) {
  guard value is Object(fields) &&
    @jsonx.json_int(fields, "generation") is Some(generation) &&
    fields.get("data") is Some(Array(data)) else {
    return (
      @cmd.none,
      {
        ..self,
        notice: "DeepSeek Harness returned malformed pending interactions",
      },
    )
  }
  if generation < self.pending_generation {
    return (@cmd.none, self)
  }
  let commands : Array[@cmd.Cmd] = []
  let mut next = { ..self, pending: [], pending_generation: generation }
  for event in data {
    let (command, state) = next.with_event(dispatch, event)
    commands.push(command)
    next = state
  }
  // dsh.pending is an authoritative list of interactions, but it is not an
  // editor-state reset. A sibling reply can settle `loading` immediately
  // before this snapshot lands, after the user has already changed another
  // question card. Reattach answers only to the same RPC, session, and
  // question ids; cards absent from the snapshot still disappear below.
  next = {
    ..next,
    pending: next.pending.map(item => {
      item.preserving_question_answers(self.pending)
    }),
  }
  // Once an authoritative snapshot reaches a settlement generation, its
  // absence is durable and the global generation rejects older events.
  next = {
    ..next,
    settled_interactions: next.settled_interactions.filter(item => {
      item.generation > generation
    }),
    response_pending_rpcs: next.response_pending_rpcs.filter(rpc_id => {
      next.pending.iter().any(item => item.rpc_id() == rpc_id)
    }),
  }
  (@cmd.batch(commands), next)
}

///|
fn State::with_event(
  self : State,
  dispatch : @cmd.Emit[Msg],
  value : Json,
) -> (@cmd.Cmd, State) {
  guard value is Object(wrapper) &&
    wrapper.get("message") is Some(Object(message)) &&
    @jsonx.json_text(message, "rpcId") is Some(rpc_id) &&
    message.get("payload") is Some(Object(payload)) &&
    @jsonx.json_text(payload, "type") is Some(type_) else {
    return (@cmd.none, self)
  }
  match type_ {
    "session/subscribed" => {
      // This is dsh's per-session stream baseline. Re-read the selected tail
      // after every WebSocket generation so a reconnect repairs any events
      // that landed between the old stream closing and the process stopping.
      guard @jsonx.json_text(payload, "sessionId") is Some(session_id) &&
        self.active_id == Some(session_id) else {
        return (@cmd.none, self)
      }
      (self.load_history(dispatch, session_id), { ..self, loading: true })
    }
    "session/event" => {
      guard @jsonx.json_text(payload, "sessionId") is Some(session_id) &&
        payload.get("event") is Some(event_json) &&
        DshEventRecord::decode(event_json) is Some(event) else {
        return (@cmd.none, self)
      }
      let sessions = self.sessions.map(row => {
        if row.id == session_id && row.blank {
          { ..row, blank: false }
        } else {
          row
        }
      })
      if self.active_id != Some(session_id) {
        return (@cmd.none, { ..self, sessions, })
      }
      // History and the live socket overlap intentionally. One monotonic high
      // water mark deduplicates every event, including chunks that are absent
      // from the retained transcript array.
      if event.seq <= self.event_sequence {
        return (@cmd.none, { ..self, sessions, })
      }
      let events = self.events.copy()
      let streaming = event.next_streaming_text(self.streaming)
      if event.retained() {
        events.push(event)
        while events.length() > DshEventWindowCapacity {
          ignore(events.remove(0))
        }
      }
      (
        @cmd.none,
        { ..self, sessions, events, event_sequence: event.seq, streaming },
      )
    }
    "host/session-status" => {
      guard @jsonx.json_text(payload, "sessionId") is Some(session_id) &&
        @jsonx.json_bool(payload, "running") is Some(running) &&
        @jsonx.json_int(wrapper, "sessionRevision") is Some(session_revision) else {
        return (@cmd.none, self)
      }
      // The native hub preserves actor order, but the revision also makes this
      // reducer safe if a future transport delivers two notifications out of
      // order. Never replace a newer observation with an older duplicate.
      if self.session_statuses
        .iter()
        .any(status => {
          status.session_id == session_id && status.revision >= session_revision
        }) {
        return (@cmd.none, self)
      }
      let sessions = self.sessions.map(row => {
        if row.id == session_id {
          { ..row, running, blank: if running { false } else { row.blank } }
        } else {
          row
        }
      })
      let session_statuses = self.session_statuses.filter(status => {
        status.session_id != session_id
      })
      session_statuses.push({ session_id, running, revision: session_revision })
      (
        @cmd.none,
        {
          ..self,
          sessions,
          session_statuses,
          loading: if self.active_id == Some(session_id) {
            self.pending
            .iter()
            .any(item => {
              item.session_id() == session_id &&
              self.response_pending_rpcs.contains(item.rpc_id())
            })
          } else {
            self.loading
          },
        },
      )
    }
    "host/session-added" =>
      (
        @cmd.batch([
          DshWorkspacesReply.request(dispatch, "workspace.list", {}),
          self.list_sessions(dispatch),
        ]),
        { ..self, loading: true },
      )
    "host/session-removed" => {
      guard @jsonx.json_text(payload, "sessionId") is Some(session_id) else {
        return (@cmd.none, self)
      }
      let sessions = self.sessions.filter(row => row.id != session_id)
      let removed_active = self.active_id == Some(session_id)
      let active_id = if removed_active {
        sessions.get(0).map(row => row.id)
      } else {
        self.active_id
      }
      let failed_prompt = match active_id {
        Some(id) => self.failed_prompts.get(id)
        None => None
      }
      let pending = self.pending.filter(item => item.session_id() != session_id)
      (
        @cmd.batch([
          DshWorkspacesReply.request(dispatch, "workspace.list", {}),
          // A session list already in flight may still contain the removed
          // row. Queue a fresh snapshot behind it so the session-list lane
          // makes this event's state the final baseline.
          self.list_sessions(dispatch),
          match active_id {
            Some(id) if active_id != self.active_id =>
              // The fallback is a different conversation. Load both pieces
              // consumed by its composer instead of waiting for the queued
              // list to rediscover a selection that is already active.
              @cmd.batch([
                self.load_history(dispatch, id),
                self.load_models(dispatch, id),
              ])
            _ => @cmd.none
          },
        ]),
        {
          ..self
          // The actor revoked dsh-derived host grants before publishing this
          // event. Hide every cached path until the replacement list restores
          // the still-valid memberships for this connection revision.
          ,
          workspaces: [],
          sessions,
          active_id,
          selection_generation: if removed_active {
            self.selection_generation + 1
          } else {
            self.selection_generation
          },
          events: if removed_active {
            []
          } else {
            self.events
          },
          streaming: if removed_active {
            ""
          } else {
            self.streaming
          },
          models: if removed_active && active_id is Some(id) {
            DshModelsLoading(session_id=id)
          } else if removed_active {
            DshModelsIdle
          } else {
            self.models
          },
          placement: if removed_active {
            @composer.LocalCheckout
          } else {
            self.placement
          },
          worktree_project: if removed_active {
            None
          } else {
            self.worktree_project
          },
          pending,
          session_statuses: self.session_statuses.filter(status => {
            status.session_id != session_id
          }),
          session_titles: self.session_titles.filter(projection => {
            projection.session_id != session_id
          }),
          response_pending_rpcs: self.response_pending_rpcs.filter(rpc_id => {
            pending.iter().any(item => item.rpc_id() == rpc_id)
          }),
          draft: if removed_active {
            failed_prompt.map(prompt => prompt.draft.task).unwrap_or("")
          } else {
            self.draft
          },
          mentions: if removed_active {
            failed_prompt.map(prompt => prompt.draft.mentions).unwrap_or([])
          } else {
            self.mentions
          },
          failed_prompts: self.failed_prompts.remove(session_id),
          prompt_pending_session: if self.prompt_pending_session ==
            Some(session_id) {
            None
          } else {
            self.prompt_pending_session
          },
          cancel_pending_sessions: self.cancel_pending_sessions.filter(id => {
            id != session_id
          }),
          loading: if removed_active {
            active_id is Some(_)
          } else {
            self.loading
          },
          notice: if removed_active {
            failed_prompt.map(prompt => prompt.message).unwrap_or("")
          } else {
            self.notice
          },
        },
      )
    }
    "host/agent-error" => {
      guard @jsonx.json_text(payload, "sessionId") is Some(session_id) &&
        self.active_id == Some(session_id) else {
        return (@cmd.none, self)
      }
      let message = @jsonx.json_text(payload, "message").unwrap_or(
        "DeepSeek Harness agent failed",
      )
      (@cmd.none, { ..self, loading: false, notice: message })
    }
    "session/projection" => {
      guard @jsonx.json_text(payload, "sessionId") is Some(session_id) &&
        @jsonx.json_text(payload, "key") == Some("title") &&
        payload.get("value") is Some(String(title)) &&
        !title.trim().is_empty() &&
        @jsonx.json_int(wrapper, "sessionRevision") is Some(session_revision) else {
        return (@cmd.none, self)
      }
      if self.session_titles
        .iter()
        .any(projection => {
          projection.session_id == session_id &&
          projection.revision >= session_revision
        }) {
        return (@cmd.none, self)
      }
      let sessions = self.sessions.map(row => {
        if row.id == session_id {
          { ..row, title, }
        } else {
          row
        }
      })
      let session_titles = self.session_titles.filter(projection => {
        projection.session_id != session_id
      })
      session_titles.push({ session_id, title, revision: session_revision })
      (@cmd.none, { ..self, sessions, session_titles })
    }
    "host/workspace-changed" =>
      (
        DshWorkspacesReply.request(dispatch, "workspace.list", {}),
        // Membership can move a live session to another path. The actor has
        // already revoked the old grants, so hide cached rows until this
        // revision's replacement snapshot succeeds.
        { ..self, workspaces: [], loading: true },
      )
    "host/workspace-removed" =>
      (
        DshWorkspacesReply.request(dispatch, "workspace.list", {}),
        // Keep Files and Terminal inert if the replacement request fails. The
        // native actor has already revoked every grant for this revision.
        { ..self, workspaces: [], loading: true },
      )
    "approval/requested" => {
      let generation = @jsonx.json_int(wrapper, "generation").unwrap_or(
        self.pending_generation,
      )
      if generation < self.pending_generation {
        return (@cmd.none, self)
      }
      if self.settled_interactions
        .iter()
        .any(item => item.rpc_id == rpc_id && generation <= item.generation) {
        return (@cmd.none, self)
      }
      guard @jsonx.json_text(payload, "sessionId") is Some(session_id) &&
        @jsonx.json_text(payload, "approvalId") is Some(approval_id) &&
        @jsonx.json_text(payload, "toolName") is Some(tool_name) else {
        return (@cmd.none, self)
      }
      let pending = self.pending.filter(item => item.rpc_id() != rpc_id)
      pending.push(
        DshApproval(
          rpc_id~,
          session_id~,
          approval_id~,
          tool_name~,
          reason=@jsonx.json_text(payload, "reason").unwrap_or(""),
        ),
      )
      (
        @cmd.none,
        {
          ..self,
          pending,
          pending_generation: generation,
          settled_interactions: self.settled_interactions.filter(item => {
            item.rpc_id != rpc_id
          }),
        },
      )
    }
    "approval/resolved" => {
      let generation = @jsonx.json_int(wrapper, "generation").unwrap_or(
        self.pending_generation,
      )
      if generation < self.pending_generation {
        return (@cmd.none, self)
      }
      guard @jsonx.json_text(payload, "approvalId") is Some(approval_id) else {
        return (@cmd.none, self)
      }
      let resolved = self.pending.filter(item => {
        item.matches_approval(approval_id)
      })
      let resolved_rpcs = resolved.map(item => item.rpc_id())
      (
        @cmd.none,
        {
          ..self,
          pending: self.pending.filter(item => {
            !item.matches_approval(approval_id)
          }),
          response_pending_rpcs: self.response_pending_rpcs.filter(rpc_id => {
            !resolved_rpcs.contains(rpc_id)
          }),
          pending_generation: generation,
          loading: if resolved
            .iter()
            .any(item => self.active_id == Some(item.session_id())) {
            false
          } else {
            self.loading
          },
        },
      )
    }
    "question/requested" => {
      let generation = @jsonx.json_int(wrapper, "generation").unwrap_or(
        self.pending_generation,
      )
      if generation < self.pending_generation {
        return (@cmd.none, self)
      }
      if self.settled_interactions
        .iter()
        .any(item => item.rpc_id == rpc_id && generation <= item.generation) {
        return (@cmd.none, self)
      }
      guard @jsonx.json_text(payload, "sessionId") is Some(session_id) &&
        payload.get("questions") is Some(Array(values)) else {
        return (@cmd.none, self)
      }
      let questions : Array[DshQuestion] = []
      let answers : Map[String, DshQuestionAnswer] = Map([])
      for value in values {
        if DshQuestion::decode(value) is Some(question) {
          answers[question.id] = DshQuestionAnswer::empty()
          questions.push(question)
        }
      }
      let pending = self.pending.filter(item => item.rpc_id() != rpc_id)
      pending.push(
        DshQuestions(rpc_id~, session_id~, questions~, answers~).preserving_question_answers(
          self.pending,
        ),
      )
      (
        @cmd.none,
        {
          ..self,
          pending,
          pending_generation: generation,
          settled_interactions: self.settled_interactions.filter(item => {
            item.rpc_id != rpc_id
          }),
        },
      )
    }
    "question/resolved" => {
      let generation = @jsonx.json_int(wrapper, "generation").unwrap_or(
        self.pending_generation,
      )
      if generation < self.pending_generation {
        return (@cmd.none, self)
      }
      let question_rpc_id = @jsonx.json_text(payload, "questionRpcId").unwrap_or(
        rpc_id,
      )
      let resolved_active = self.pending
        .iter()
        .any(item => {
          item.rpc_id() == question_rpc_id &&
          self.active_id == Some(item.session_id())
        })
      (
        @cmd.none,
        {
          ..self,
          pending: self.pending.filter(item => item.rpc_id() != question_rpc_id),
          response_pending_rpcs: self.response_pending_rpcs.filter(rpc_id => {
            rpc_id != question_rpc_id
          }),
          pending_generation: generation,
          loading: if resolved_active {
            false
          } else {
            self.loading
          },
        },
      )
    }
    "stream/error" =>
      (
        @cmd.none,
        { ..self, notice: "DeepSeek Harness event stream reported an error" },
      )
    _ => (@cmd.none, self)
  }
}

///|
fn DshEventRecord::streaming_delta(self : DshEventRecord) -> String? {
  guard self.type_ == "assistant/chunk" &&
    self.data is Object(data) &&
    data.get("chunk") is Some(Object(chunk)) &&
    @jsonx.json_text(chunk, "type") == Some("text-delta") else {
    return None
  }
  @jsonx.json_text(chunk, "text")
}

///|
fn DshEventRecord::next_streaming_text(
  self : DshEventRecord,
  current : String,
) -> String {
  // A final append replaces the chunks in the transcript, and either kind of
  // turn boundary invalidates text left behind by an interrupted response.
  if self.type_ == "turn/start" ||
    self.type_ == "turn/end" ||
    (
      (self.type_ == "user/message" || self.type_ == "assistant/message") &&
      self.surface_append == Some(true)
    ) {
    ""
  } else if self.streaming_delta() is Some(delta) {
    current + delta
  } else {
    current
  }
}

///|
/// Chunk frames are an incremental rendering transport, not transcript rows.
/// Their text lives in `State.streaming`; retaining them here would let one
/// verbose answer evict the user's question and tool lifecycle records.
fn DshEventRecord::retained(self : DshEventRecord) -> Bool {
  self.type_ != "assistant/chunk"
}

///|
/// Decide a lost prompt only from a structurally valid history page. dsh logs
/// the append-origin user message before acknowledging session.prompt, so an
/// exact message above the pre-send sequence is its durable acceptance proof.
fn DshPromptReconciliation::accepted(
  self : DshPromptReconciliation,
  history : Json,
) -> Bool? {
  guard history is Object(fields) &&
    fields.get("events") is Some(Array(entries)) else {
    return None
  }
  let expected = self.draft.prompt()
  for entry in entries {
    if entry is Object(entry_fields) &&
      entry_fields.get("event") is Some(event_json) &&
      DshEventRecord::decode(event_json) is Some(event) &&
      event.seq > self.after_seq &&
      event.direct_user_text() == Some(expected) {
      return Some(true)
    }
  }
  Some(false)
}

///|
const DshEventWindowCapacity : Int = 200

///|
priv struct DshEventLog(Array[DshEventRecord])

///|
fn DshEventLog::streaming_text(self : DshEventLog) -> String {
  let mut text = ""
  for event in self.0 {
    // A bounded history window may no longer contain the turn/start that
    // preceded its first append event. Apply the same boundary semantics used
    // by the incremental WebSocket path to keep both projections identical.
    text = event.next_streaming_text(text)
  }
  text
}

///|
fn DshPendingInteraction::rpc_id(self : DshPendingInteraction) -> String {
  match self {
    DshApproval(rpc_id~, ..) | DshQuestions(rpc_id~, ..) => rpc_id
  }
}

///|
fn DshPendingInteraction::session_id(self : DshPendingInteraction) -> String {
  match self {
    DshApproval(session_id~, ..) | DshQuestions(session_id~, ..) => session_id
  }
}

///|
fn DshPendingInteraction::matches_approval(
  self : DshPendingInteraction,
  approval_id : String,
) -> Bool {
  self is DshApproval(approval_id=matched, ..) && matched == approval_id
}

///|
fn DshPendingInteraction::questions_answered(
  self : DshPendingInteraction,
) -> Bool {
  guard self is DshQuestions(questions~, answers~, ..) else { return false }
  questions
  .iter()
  .all(question => {
    let answer = answers
      .get(question.id)
      .unwrap_or_else(() => DshQuestionAnswer::empty())
    !answer.selected.is_empty() || !answer.custom.trim().is_empty()
  })
}

///|
/// Keep renderer-owned answer drafts when dsh replays the same pending
/// question request. The server remains authoritative for which questions
/// exist; only exact question ids inside the same RPC and session inherit UI
/// state, so a replacement request starts with empty answers.
fn DshPendingInteraction::preserving_question_answers(
  self : DshPendingInteraction,
  previous : Array[DshPendingInteraction],
) -> DshPendingInteraction {
  guard self is DshQuestions(rpc_id~, session_id~, questions~, answers~) &&
    previous
    .iter()
    .find_first(item => {
      item
      is DshQuestions(
        rpc_id=previous_rpc_id,
        session_id=previous_session_id,
        ..
      ) &&
      previous_rpc_id == rpc_id &&
      previous_session_id == session_id
    })
    is Some(DshQuestions(answers=previous_answers, ..)) else {
    return self
  }
  let merged : Map[String, DshQuestionAnswer] = Map([])
  for question in questions {
    merged[question.id] = match previous_answers.get(question.id) {
      Some(answer) => { ..answer, selected: answer.selected.copy() }
      None =>
        answers
        .get(question.id)
        .unwrap_or_else(() => DshQuestionAnswer::empty())
    }
  }
  DshQuestions(rpc_id~, session_id~, questions~, answers=merged)
}

///|
fn State::pending_for_rpc(
  self : State,
  rpc_id : String,
) -> DshPendingInteraction? {
  self.pending.iter().find_first(item => item.rpc_id() == rpc_id)
}

///|
fn State::with_question_option(
  self : State,
  rpc_id : String,
  question_id : String,
  label : String,
) -> State {
  let pending = self.pending.copy()
  for index, item in pending {
    guard item
      is DshQuestions(rpc_id=matched, session_id~, questions~, answers~) &&
      matched == rpc_id &&
      questions.iter().find_first(question => question.id == question_id)
      is Some(question) else {
      continue
    }
    let next_answers : Map[String, DshQuestionAnswer] = Map([])
    for id, answer in answers {
      next_answers[id] = { ..answer, selected: answer.selected.copy() }
    }
    let answer = next_answers
      .get(question_id)
      .unwrap_or_else(() => DshQuestionAnswer::empty())
    let selected = if question.multi_select {
      if answer.selected.contains(label) {
        answer.selected.filter(value => value != label)
      } else {
        [..answer.selected, label]
      }
    } else {
      [label]
    }
    // dsh's single-select contract makes an option and custom text mutually
    // exclusive. Choosing an option therefore clears a prior custom answer.
    next_answers[question_id] = {
      selected,
      custom: if question.multi_select {
        answer.custom
      } else {
        ""
      },
    }
    pending[index] = DshQuestions(
      rpc_id=matched,
      session_id~,
      questions~,
      answers=next_answers,
    )
    break
  }
  { ..self, pending, }
}

///|
fn State::with_question_custom(
  self : State,
  rpc_id : String,
  question_id : String,
  value : String,
) -> State {
  let pending = self.pending.copy()
  for index, item in pending {
    guard item
      is DshQuestions(rpc_id=matched, session_id~, questions~, answers~) &&
      matched == rpc_id &&
      questions.iter().find_first(question => question.id == question_id)
      is Some(question) else {
      continue
    }
    let next_answers : Map[String, DshQuestionAnswer] = Map([])
    for id, answer in answers {
      next_answers[id] = { ..answer, selected: answer.selected.copy() }
    }
    let answer = next_answers
      .get(question_id)
      .unwrap_or_else(() => DshQuestionAnswer::empty())
    // Entering a custom single-select answer clears the selected option, as
    // required by dsh's QuestionResponsePayload validator.
    next_answers[question_id] = {
      selected: if !question.multi_select && !value.trim().is_empty() {
        []
      } else {
        answer.selected
      },
      custom: value,
    }
    pending[index] = DshQuestions(
      rpc_id=matched,
      session_id~,
      questions~,
      answers=next_answers,
    )
    break
  }
  { ..self, pending, }
}

///|
test "dsh workspace membership supplies the active editor root" {
  // Workspace baselines project paths only inside an already Ready
  // connection; the list reply itself is not a connection transition.
  let state = {
    ..State(),
    connection: DshReady,
    sessions: [
      {
        id: "session-1",
        title: "First",
        cwd: Some("/display-only"),
        running: false,
        blank: false,
      },
      {
        id: "session-2",
        title: "Ungrouped",
        cwd: Some("/must-not-authorize"),
        running: false,
        blank: false,
      },
    ],
    active_id: Some("session-1"),
  }
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let (_, grouped) = state.with_reply(dispatch, DshWorkspacesReply, {
    "type": "server-response",
    "rpcId": "workspace-list-1",
    "result": {
      "ok": true,
      "value": {
        "items": [
          {
            "workspaceId": "workspace-1",
            "title": "Project",
            "path": "/canonical/project",
            "sessionIds": ["session-1"],
          },
        ],
        "archivedSessionIds": [],
      },
    },
  })
  assert_eq(grouped.preferred_workspace_id(), Some("workspace-1"))
  assert_eq(grouped.active_workspace_path(), Some("/canonical/project"))
  let unavailable = {
    ..grouped,
    connection: DshUnavailable("dsh disconnected"),
  }
  assert_eq(unavailable.preferred_workspace_id(), Some("workspace-1"))
  assert_true(unavailable.active_workspace_path() is None)
  let ungrouped = { ..grouped, active_id: Some("session-2") }
  assert_eq(ungrouped.preferred_workspace_id(), Some("workspace-1"))
  assert_true(ungrouped.active_workspace_path() is None)
}

///|
test "dsh reconnect status restores workspace state without transcript errors" {
  let state = {
    ..State(),
    connection: DshUnavailable("dsh was missing"),
    notice: "old notice",
  }
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let (_, retrying) = update(dispatch, Refresh, state)
  assert_true(retrying.loading)
  assert_eq(retrying.unavailable_message(), Some("dsh was missing"))
  assert_eq(retrying.notice, "")
  // Connection state belongs exclusively to the revisioned status stream.
  // The workspace reply may fill its baseline, but must never manufacture a
  // Ready transition after a later disconnect.
  let (_, connected) = retrying.with_status(dispatch, {
    "status": "ready",
    "revision": 1,
  })
  let (_, ready) = update(
    dispatch,
    Reply(kind=DshReconnectReply, value={
      "type": "server-response",
      "rpcId": "workspace-reconnect",
      "result": {
        "ok": true,
        "value": {
          "items": [
            {
              "workspaceId": "workspace-1",
              "title": "Project",
              "path": "/canonical/project",
              "sessionIds": ["session-1"],
            },
          ],
          "archivedSessionIds": [],
        },
      },
    }),
    connected,
  )
  assert_eq(ready.unavailable_message(), None)
  assert_eq(ready.preferred_workspace_id(), Some("workspace-1"))
  assert_eq(ready.notice, "")
  let (_, pending) = ready.with_reply(dispatch, DshPendingReply, {
    "data": [
      {
        "stream": "mux",
        "generation": 2,
        "message": {
          "rpcId": "approval-rpc",
          "payload": {
            "type": "approval/requested",
            "sessionId": "session-1",
            "approvalId": "approval-1",
            "toolName": "write",
          },
        },
      },
    ],
    "generation": 2,
  })
  assert_eq(pending.pending.map(item => item.rpc_id()), ["approval-rpc"])
  assert_eq(pending.pending_generation, 2)
  let (_, stale) = pending.with_reply(dispatch, DshPendingReply, {
    "data": [],
    "generation": 1,
  })
  assert_eq(stale.pending.map(item => item.rpc_id()), ["approval-rpc"])
  assert_eq(stale.pending_generation, 2)
}

///|
test "late dsh list replies cannot restore a disconnected page" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let (_, ready) = State().with_status(dispatch, {
    "status": "ready",
    "revision": 1,
  })
  let (_, disconnected) = ready.with_status(dispatch, {
    "status": "unavailable",
    "message": "socket closed",
    "revision": 2,
  })
  let (_, workspace_reply) = disconnected.with_reply(
    dispatch,
    DshWorkspacesReply,
    {
      "type": "server-response",
      "rpcId": "late-workspaces",
      "result": {
        "ok": true,
        "value": {
          "items": [
            {
              "workspaceId": "workspace-1",
              "title": "Project",
              "path": "/work/project",
              "sessionIds": ["session-1"],
            },
          ],
          "archivedSessionIds": [],
        },
      },
    },
  )
  assert_eq(workspace_reply.unavailable_message(), Some("socket closed"))
  assert_true(workspace_reply.active_workspace_path() is None)
  let (_, session_reply) = workspace_reply.with_reply(
    dispatch,
    DshSessionsReply(session_revision=0),
    {
      "type": "server-response",
      "rpcId": "late-sessions",
      "result": {
        "ok": true,
        "value": {
          "items": [
            {
              "sessionId": "session-1",
              "title": "Session 1",
              "cwd": "/work/project",
              "running": false,
              "blank": false,
            },
          ],
        },
      },
    },
  )
  assert_eq(session_reply.unavailable_message(), Some("socket closed"))
  assert_true(session_reply.active_workspace_path() is None)
}

///|
test "dsh reconnect transport failure waits for the actor status toast" {
  let state = {
    ..State(),
    connection: DshUnavailable("authoritative startup error"),
  }
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let (_, failed) = update(
    dispatch,
    Failed(kind=DshReconnectReply, message="bridge request rejected"),
    state,
  )
  assert_eq(failed.unavailable_message(), Some("authoritative startup error"))
  assert_eq(failed.notice, "")
}

///|
test "dsh session creation requires an explicit workspace id" {
  let state = { ..State(), connection: DshReady }
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let (_, next) = update(dispatch, NewSession(None), state)
  assert_false(next.loading)
  assert_eq(next.notice, "Create or select a DeepSeek Harness workspace first")
  assert_true(next.workspaces == state.workspaces)
  assert_true(next.sessions == state.sessions)
}

///|
test "dsh session creation remains busy through session status events" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = {
    ..State(),
    connection: DshReady,
    sessions: [
      {
        id: "session-1",
        title: "Session 1",
        cwd: None,
        running: true,
        blank: false,
      },
    ],
    active_id: Some("session-1"),
  }
  let (_, creating) = update(dispatch, NewSession(Some("workspace-1")), state)
  assert_true(creating.creation_pending)
  assert_true(creating.loading)
  assert_false(creating.can_create())
  let (_, status) = creating.with_event(dispatch, {
    "stream": "host",
    "message": {
      "rpcId": "status-1",
      "payload": {
        "type": "host/session-status",
        "sessionId": "session-1",
        "running": true,
      },
    },
    "generation": 1,
    "sessionRevision": 1,
  })
  assert_true(status.creation_pending)
  assert_false(status.loading)
  assert_true(status.busy())
  assert_false(status.can_create())
  let (_, duplicate) = update(dispatch, NewSession(Some("workspace-1")), status)
  assert_true(duplicate == status)
  let (_, created) = duplicate.with_reply(dispatch, DshCreateReply(0), {
    "type": "server-response",
    "rpcId": "create-1",
    "result": { "ok": true, "value": { "sessionId": "session-2" } },
  })
  assert_false(created.creation_pending)
  assert_eq(created.active_id, Some("session-2"))
}

///|
test "dsh workspace creation stays busy until its session is created" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = { ..State(), connection: DshReady }
  let (_, creating_workspace) = update(
    dispatch,
    NewWorkspaceSession("/project"),
    state,
  )
  assert_true(creating_workspace.creation_pending)
  let navigated = {
    ..creating_workspace,
    active_id: Some("session-b"),
    selection_generation: 1,
    loading: true,
    notice: "session B notice",
  }
  let (_, creating_session) = navigated.with_reply(
    dispatch,
    DshWorkspaceCreateReply(0),
    {
      "type": "server-response",
      "rpcId": "workspace-create-1",
      "result": {
        "ok": true,
        "value": {
          "workspace": {
            "workspaceId": "workspace-1",
            "title": "Project",
            "path": "/project",
            "sessionIds": [],
          },
        },
      },
    },
  )
  assert_true(creating_session.creation_pending)
  assert_eq(creating_session.active_id, Some("session-b"))
  assert_eq(creating_session.notice, "session B notice")
  let (_, created) = creating_session.with_reply(dispatch, DshCreateReply(0), {
    "type": "server-response",
    "rpcId": "session-create-1",
    "result": { "ok": true, "value": { "sessionId": "session-1" } },
  })
  assert_false(created.creation_pending)
  assert_eq(created.active_id, Some("session-b"))
  assert_eq(created.notice, "session B notice")
}

///|
test "accepted dsh prompt advances transcript submission generation" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = {
    ..State(),
    connection: DshReady,
    sessions: [
      {
        id: "session-1",
        title: "Session",
        cwd: None,
        running: false,
        blank: false,
      },
    ],
    active_id: Some("session-1"),
    draft: "hello",
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
  let (_, next) = update(dispatch, Send, state)
  assert_eq(next.submission_generation(), 1)
  assert_true(next.loading)
  assert_true(next.busy())
  let (_, running) = next.with_event(dispatch, {
    "stream": "host",
    "message": {
      "rpcId": "status-1",
      "payload": {
        "type": "host/session-status",
        "sessionId": "session-1",
        "running": true,
      },
    },
    "generation": 1,
    "sessionRevision": 1,
  })
  assert_false(running.loading)
  assert_true(running.busy())
  let (_, blocked) = update(dispatch, Send, running)
  assert_eq(blocked.prompt_generation, 1)
  let (_, settled) = update(
    dispatch,
    Reply(
      kind=DshPromptReply(
        session_id="session-1",
        draft={ task: "hello", mentions: [] },
        generation=1,
      ),
      value={
        "type": "server-response",
        "rpcId": "prompt-1",
        "result": { "ok": true, "value": {} },
      },
    ),
    running,
  )
  assert_false(settled.busy())
}

///|
test "dsh interaction response remains busy through session status events" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let pending = DshApproval(
    rpc_id="approval-rpc",
    session_id="session-1",
    approval_id="approval-1",
    tool_name="write",
    reason="needs approval",
  )
  let state = {
    ..State(),
    sessions: [
      {
        id: "session-1",
        title: "Session 1",
        cwd: None,
        running: true,
        blank: false,
      },
    ],
    active_id: Some("session-1"),
    pending: [pending],
  }
  let (_, responding) = update(
    dispatch,
    ApprovalDecision(rpc_id="approval-rpc", outcome="allowed-once"),
    state,
  )
  assert_eq(responding.response_pending_rpcs, ["approval-rpc"])
  assert_true(responding.loading)
  assert_true(responding.busy())
  let (_, status) = responding.with_event(dispatch, {
    "stream": "host",
    "message": {
      "rpcId": "status-1",
      "payload": {
        "type": "host/session-status",
        "sessionId": "session-1",
        "running": true,
      },
    },
    "generation": 1,
    "sessionRevision": 1,
  })
  assert_true(status.loading)
  assert_true(status.busy())
  let (_, duplicate) = update(
    dispatch,
    ApprovalDecision(rpc_id="approval-rpc", outcome="allowed-once"),
    status,
  )
  assert_eq(duplicate.response_pending_rpcs, ["approval-rpc"])
  let (_, settled) = duplicate.with_reply(
    dispatch,
    DshResponseReply(rpc_id="approval-rpc", session_id="session-1"),
    { "receipt": { "accepted": true }, "generation": 2 },
  )
  assert_true(settled.response_pending_rpcs.is_empty())
  assert_true(settled.pending.is_empty())
  assert_false(settled.loading)
  assert_false(settled.busy())
  // A snapshot captured before acceptance cannot recreate the answered card.
  let (_, stale_snapshot) = settled.with_reply(dispatch, DshPendingReply, {
    "data": [
      {
        "stream": "mux",
        "generation": 1,
        "message": {
          "rpcId": "approval-rpc",
          "payload": {
            "type": "approval/requested",
            "sessionId": "session-1",
            "approvalId": "approval-1",
            "toolName": "write",
          },
        },
      },
    ],
    "generation": 1,
  })
  assert_true(stale_snapshot.pending.is_empty())
  assert_eq(stale_snapshot.settled_interactions.length(), 1)
  let (_, current_snapshot) = stale_snapshot.with_reply(
    dispatch,
    DshPendingReply,
    { "data": [], "generation": 2 },
  )
  assert_true(current_snapshot.settled_interactions.is_empty())
  assert_eq(current_snapshot.pending_generation, 2)
}

///|
test "empty dsh session baseline clears a deleted active transcript" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = {
    ..State(),
    sessions: [
      {
        id: "session-1",
        title: "Deleted",
        cwd: None,
        running: false,
        blank: false,
      },
    ],
    active_id: Some("session-1"),
    draft: "draft for deleted session",
    events: [
      {
        type_: "assistant/chunk",
        seq: 1,
        time: None,
        data: {},
        surface_append: None,
      },
    ],
    streaming: "stale output",
    loading: true,
  }
  let (_, next) = state.with_reply(
    dispatch,
    DshSessionsReply(session_revision=0),
    {
      "type": "server-response",
      "rpcId": "session-list",
      "result": { "ok": true, "value": { "items": [] } },
    },
  )
  assert_true(next.active_id is None)
  assert_true(next.events.is_empty())
  assert_eq(next.streaming, "")
  assert_eq(next.draft, "")
  assert_false(next.loading)
}

///|
test "dsh status poll cannot roll back a newer notification" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = State()
  let (_, ready) = state.with_status(dispatch, {
    "status": "ready",
    "revision": 2,
  })
  assert_true(ready.connection is DshReady)
  assert_eq(ready.connection_status_revision, 2)
  let (_, stale) = ready.with_reply(dispatch, DshStatusReply, {
    "status": "starting",
    "revision": 1,
  })
  assert_true(stale.connection is DshReady)
  assert_eq(stale.connection_status_revision, 2)
}

///|
test "dsh reconnect ready waits for a new Workspace baseline" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = {
    ..State(),
    connection: DshUnavailable("disconnected"),
    connection_status_revision: 2,
    workspaces: [
      {
        id: "workspace-old",
        title: "Old grant",
        path: "/work/old",
        session_ids: ["session-1"],
      },
    ],
    sessions: [
      {
        id: "session-1",
        title: "Session 1",
        cwd: Some("/work/old"),
        running: false,
        blank: false,
      },
    ],
    active_id: Some("session-1"),
  }
  let (_, ready) = state.with_status(dispatch, {
    "status": "ready",
    "revision": 3,
  })
  assert_true(ready.connection is DshReady)
  assert_true(ready.workspaces.is_empty())
  assert_true(ready.active_workspace_path() is None)
  assert_true(ready.models is DshModelsLoading(session_id="session-1"))
  assert_true(ready.loading)
  let duplicate_source = { ..ready, models: DshModelsIdle }
  let (_, duplicate) = duplicate_source.with_status(dispatch, {
    "status": "ready",
    "revision": 3,
  })
  assert_true(duplicate.models is DshModelsIdle)
}

///|
test "dsh session list orders running state by actor dispatch revision" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = {
    ..State(),
    sessions: [
      {
        id: "session-1",
        title: "Session 1",
        cwd: None,
        running: false,
        blank: true,
      },
    ],
    active_id: Some("session-1"),
  }
  let (_, running) = state.with_event(dispatch, {
    "stream": "host",
    "message": {
      "rpcId": "status-1",
      "payload": {
        "type": "host/session-status",
        "sessionId": "session-1",
        "running": true,
      },
    },
    "generation": 1,
    "sessionRevision": 1,
  })
  let (_, stale_event) = running.with_event(dispatch, {
    "stream": "host",
    "message": {
      "rpcId": "status-0",
      "payload": {
        "type": "host/session-status",
        "sessionId": "session-1",
        "running": false,
      },
    },
    "generation": 1,
    "sessionRevision": 0,
  })
  assert_eq(stale_event.sessions.get(0).map(row => row.running), Some(true))
  let snapshot : Json = {
    "type": "server-response",
    "rpcId": "session-list-1",
    "result": {
      "ok": true,
      "value": {
        "items": [
          {
            "sessionId": "session-1",
            "projections": { "values": { "title": "Session 1" } },
            "running": false,
            "blank": true,
          },
        ],
      },
    },
  }
  let (_, preserved) = running.with_reply(
    dispatch,
    DshSessionsReply(session_revision=0),
    snapshot,
  )
  assert_eq(preserved.sessions.get(0).map(row => row.running), Some(true))
  assert_eq(preserved.sessions.get(0).map(row => row.blank), Some(false))
  let (_, fresh) = running.with_reply(
    dispatch,
    // A list dispatched after revision 1 is newer than that notification even
    // if the frontend command had waited behind an earlier ordered request.
    DshSessionsReply(session_revision=1),
    snapshot,
  )
  assert_eq(fresh.sessions.get(0).map(row => row.running), Some(false))
}

///|
test "dsh session list preserves a newer title projection" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = {
    ..State(),
    sessions: [
      {
        id: "session-1",
        title: "Old title",
        cwd: None,
        running: false,
        blank: false,
      },
    ],
    active_id: Some("session-1"),
  }
  let (_, renamed) = state.with_event(dispatch, {
    "stream": "mux",
    "message": {
      "rpcId": "projection-1",
      "payload": {
        "type": "session/projection",
        "sessionId": "session-1",
        "key": "title",
        "value": "New title",
      },
    },
    "generation": 0,
    "sessionRevision": 1,
  })
  let snapshot : Json = {
    "type": "server-response",
    "rpcId": "session-list-title",
    "result": {
      "ok": true,
      "value": {
        "items": [
          {
            "sessionId": "session-1",
            "projections": { "values": { "title": "Old title" } },
            "running": false,
            "blank": false,
          },
        ],
      },
    },
  }
  let (_, preserved) = renamed.with_reply(
    dispatch,
    DshSessionsReply(session_revision=0),
    snapshot,
  )
  assert_eq(preserved.sessions.get(0).map(row => row.title), Some("New title"))
  let (_, fresh) = renamed.with_reply(
    dispatch,
    DshSessionsReply(session_revision=1),
    snapshot,
  )
  assert_eq(fresh.sessions.get(0).map(row => row.title), Some("Old title"))
}

///|
test "late dsh creation preserves newer session navigation" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = {
    ..State(),
    sessions: [
      { id: "session-a", title: "A", cwd: None, running: false, blank: false },
      { id: "session-b", title: "B", cwd: None, running: false, blank: false },
    ],
    active_id: Some("session-a"),
    draft: "draft for A",
  }
  let (_, navigated) = update(dispatch, OpenSession("session-b"), state)
  assert_eq(navigated.draft, "")
  let current = {
    ..navigated,
    creation_pending: true,
    events: [
      {
        type_: "assistant/message",
        seq: 8,
        time: None,
        data: {},
        surface_append: None,
      },
    ],
    streaming: "session B output",
  }
  let (_, preserved) = current.with_reply(dispatch, DshCreateReply(0), {
    "type": "server-response",
    "rpcId": "create-1",
    "result": { "ok": true, "value": { "sessionId": "session-new" } },
  })
  assert_eq(preserved.active_id, Some("session-b"))
  assert_eq(preserved.streaming, "session B output")
  assert_eq(preserved.events.length(), 1)
  assert_eq(preserved.selection_generation, 1)
  assert_false(preserved.creation_pending)
  let same_selection = { ..state, draft: "keep for A" }
  let (_, reopened) = update(dispatch, OpenSession("session-a"), same_selection)
  assert_eq(reopened.draft, "keep for A")
  assert_eq(reopened.selection_generation, 0)
}

///|
test "late dsh cancellation replies preserve the newly active session" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = {
    ..State(),
    active_id: Some("session-b"),
    cancel_pending_sessions: ["session-a"],
    loading: true,
    notice: "current notice",
  }
  let reply : Json = {
    "type": "server-response",
    "rpcId": "cancel-a",
    "result": { "ok": true, "value": {} },
  }
  let (_, stale_success) = update(
    dispatch,
    Reply(kind=DshCancelReply("session-a"), value=reply),
    state,
  )
  assert_eq(stale_success.cancel_pending_sessions, [])
  assert_true(stale_success.loading)
  assert_eq(stale_success.notice, "current notice")
  let (_, stale_failure) = update(
    dispatch,
    Failed(kind=DshCancelReply("session-a"), message="cancel failed"),
    state,
  )
  assert_eq(stale_failure.cancel_pending_sessions, [])
  assert_true(stale_failure.loading)
  assert_eq(stale_failure.notice, "current notice")
}

///|
test "dsh cancellation remains busy through session status events" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = {
    ..State(),
    connection: DshReady,
    sessions: [
      {
        id: "session-1",
        title: "Session 1",
        cwd: None,
        running: true,
        blank: false,
      },
    ],
    active_id: Some("session-1"),
    draft: "next request",
  }
  let (_, cancelling) = update(dispatch, Stop, state)
  assert_eq(cancelling.cancel_pending_sessions, ["session-1"])
  assert_true(cancelling.loading)
  assert_true(cancelling.busy())
  let (_, stopped) = cancelling.with_event(dispatch, {
    "stream": "host",
    "message": {
      "rpcId": "status-1",
      "payload": {
        "type": "host/session-status",
        "sessionId": "session-1",
        "running": false,
      },
    },
    "generation": 1,
    "sessionRevision": 1,
  })
  assert_false(stopped.loading)
  assert_true(stopped.busy())
  let (_, blocked) = update(dispatch, Send, stopped)
  assert_eq(blocked.prompt_generation, 0)
  let (_, settled) = update(
    dispatch,
    Reply(kind=DshCancelReply("session-1"), value={
      "type": "server-response",
      "rpcId": "cancel-1",
      "result": { "ok": true, "value": {} },
    }),
    stopped,
  )
  assert_eq(settled.cancel_pending_sessions, [])
  assert_false(settled.loading)
  assert_false(settled.busy())
}

///|
test "dsh tracks cancellations independently across session navigation" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let sessions = [
    { id: "session-a", title: "A", cwd: None, running: true, blank: false },
    { id: "session-b", title: "B", cwd: None, running: true, blank: false },
  ]
  let state = {
    ..State(),
    connection: DshReady,
    sessions,
    active_id: Some("session-a"),
  }
  let (_, cancelling_a) = update(dispatch, Stop, state)
  let ready_b = { ..cancelling_a, active_id: Some("session-b"), loading: false }
  let (_, cancelling_b) = update(dispatch, Stop, ready_b)
  assert_eq(cancelling_b.cancel_pending_sessions, ["session-a", "session-b"])
  let reply : Json = {
    "type": "server-response",
    "rpcId": "cancel",
    "result": { "ok": true, "value": {} },
  }
  let (_, settled_a) = update(
    dispatch,
    Reply(kind=DshCancelReply("session-a"), value=reply),
    cancelling_b,
  )
  assert_eq(settled_a.cancel_pending_sessions, ["session-b"])
  assert_true(settled_a.busy())
  let (_, settled_b) = update(
    dispatch,
    Reply(kind=DshCancelReply("session-b"), value=reply),
    settled_a,
  )
  assert_eq(settled_b.cancel_pending_sessions, [])
  assert_false(settled_b.busy())
}

///|
test "dsh business errors preserve newer session navigation" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let state = {
    ..State(),
    active_id: Some("session-b"),
    selection_generation: 2,
    creation_pending: true,
    loading: true,
    notice: "session B notice",
  }
  let business_error : Json = {
    "type": "server-response",
    "rpcId": "request-a",
    "result": {
      "ok": false,
      "error": { "code": "request-failed", "message": "session A failed" },
    },
  }
  let (_, stale_history) = update(
    dispatch,
    Reply(kind=DshHistoryReply("session-a"), value=business_error),
    state,
  )
  assert_true(stale_history == state)
  let (_, stale_models) = update(
    dispatch,
    Reply(kind=DshModelsReply("session-a"), value=business_error),
    state,
  )
  assert_true(stale_models == state)
  let (_, stale_model_selection) = update(
    dispatch,
    Reply(
      kind=DshSelectModelReply(session_id="session-a"),
      value=business_error,
    ),
    state,
  )
  assert_true(stale_model_selection == state)
  let (_, stale_cancel) = update(
    dispatch,
    Reply(kind=DshCancelReply("session-a"), value=business_error),
    state,
  )
  assert_true(stale_cancel == state)
  let (_, stale_create) = update(
    dispatch,
    Reply(kind=DshCreateReply(1), value=business_error),
    state,
  )
  assert_false(stale_create.creation_pending)
  assert_true(stale_create.loading)
  assert_eq(stale_create.notice, "session B notice")
  let (_, stale_workspace_create) = update(
    dispatch,
    Reply(kind=DshWorkspaceCreateReply(1), value=business_error),
    state,
  )
  assert_false(stale_workspace_create.creation_pending)
  assert_true(stale_workspace_create.loading)
  assert_eq(stale_workspace_create.notice, "session B notice")
  let (_, current_cancel) = update(
    dispatch,
    Reply(kind=DshCancelReply("session-b"), value=business_error),
    state,
  )
  assert_false(current_cancel.loading)
  assert_eq(current_cancel.notice, "request-failed: session A failed")
}

///|
test "background dsh interaction receipts preserve the active page" {
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let pending = DshApproval(
    rpc_id="rpc-a",
    session_id="session-a",
    approval_id="approval-a",
    tool_name="write",
    reason="needs approval",
  )
  let state = {
    ..State(),
    active_id: Some("session-b"),
    pending: [pending],
    response_pending_rpcs: ["rpc-a"],
    loading: true,
    notice: "session B notice",
  }
  let (_, accepted) = state.with_reply(
    dispatch,
    DshResponseReply(rpc_id="rpc-a", session_id="session-a"),
    { "receipt": { "accepted": true }, "generation": 3 },
  )
  assert_true(accepted.pending.is_empty())
  assert_true(accepted.response_pending_rpcs.is_empty())
  assert_true(accepted.loading)
  assert_eq(accepted.notice, "session B notice")
  let (_, rejected) = state.with_reply(
    dispatch,
    DshResponseReply(rpc_id="rpc-a", session_id="session-a"),
    {
      "receipt": { "accepted": false, "reason": "stale request" },
      "generation": 2,
    },
  )
  assert_eq(rejected.pending.length(), 1)
  assert_true(rejected.response_pending_rpcs.is_empty())
  assert_true(rejected.loading)
  assert_eq(rejected.notice, "session B notice")
  let (_, failed) = update(
    dispatch,
    Failed(
      kind=DshResponseReply(rpc_id="rpc-a", session_id="session-a"),
      message="transport failed",
    ),
    state,
  )
  assert_eq(failed.pending.length(), 1)
  assert_true(failed.response_pending_rpcs.is_empty())
  assert_true(failed.loading)
  assert_eq(failed.notice, "session B notice")
}

///|
test "dsh event log rebuilds only the unfinished assistant text" {
  let events : Array[DshEventRecord] = [
    {
      type_: "assistant/chunk",
      seq: 1,
      time: None,
      data: { "chunk": { "type": "text-delta", "text": "old" } },
      surface_append: None,
    },
    {
      type_: "assistant/message",
      seq: 2,
      time: None,
      data: {},
      surface_append: Some(true),
    },
    {
      type_: "assistant/chunk",
      seq: 3,
      time: None,
      data: { "chunk": { "type": "text-delta", "text": "new " } },
      surface_append: None,
    },
    {
      type_: "assistant/chunk",
      seq: 4,
      time: None,
      data: { "chunk": { "type": "text-delta", "text": "text" } },
      surface_append: None,
    },
  ]
  assert_eq(DshEventLog(events).streaming_text(), "new text")
}

///|
test "dsh event log drops an interrupted turn at the next boundary" {
  let old_chunk : DshEventRecord = {
    type_: "assistant/chunk",
    seq: 1,
    time: None,
    data: { "chunk": { "type": "text-delta", "text": "abandoned" } },
    surface_append: None,
  }
  let new_chunk : DshEventRecord = {
    type_: "assistant/chunk",
    seq: 4,
    time: None,
    data: { "chunk": { "type": "text-delta", "text": "next" } },
    surface_append: None,
  }
  assert_eq(
    DshEventLog([
      old_chunk,
      {
        type_: "turn/start",
        seq: 3,
        time: None,
        data: {},
        surface_append: None,
      },
      new_chunk,
    ]).streaming_text(),
    "next",
  )
  assert_eq(
    DshEventLog([
      old_chunk,
      {
        type_: "user/message",
        seq: 3,
        time: None,
        data: { "source": { "kind": "user" }, "content": [] },
        surface_append: Some(true),
      },
      new_chunk,
    ]).streaming_text(),
    "next",
  )
  assert_eq(
    DshEventLog([
      old_chunk,
      { type_: "turn/end", seq: 2, time: None, data: {}, surface_append: None },
    ]).streaming_text(),
    "",
  )
}

///|
test "dsh chunks preserve the durable event window and streaming text" {
  let events : Array[DshEventRecord] = []
  for index in 0..<DshEventWindowCapacity {
    events.push({
      type_: "user/message",
      seq: index,
      time: None,
      data: {
        "source": { "kind": "user" },
        "content": [{ "type": "text", "text": "question {index}" }],
      },
      surface_append: Some(true),
    })
  }
  let state = {
    ..State(),
    active_id: Some("session-1"),
    events,
    event_sequence: DshEventWindowCapacity - 1,
    streaming: "complete text before the retained window",
  }
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let (_, next) = state.with_event(dispatch, {
    "message": {
      "rpcId": "event-200",
      "payload": {
        "type": "session/event",
        "sessionId": "session-1",
        "event": {
          "type": "assistant/chunk",
          "seq": 200,
          "data": { "chunk": { "type": "text-delta", "text": " plus tail" } },
        },
      },
    },
  })
  assert_eq(next.events.length(), DshEventWindowCapacity)
  assert_eq(next.events[0].seq, 0)
  assert_eq(next.events[DshEventWindowCapacity - 1].seq, 199)
  assert_eq(next.event_sequence, 200)
  assert_eq(
    next.streaming,
    "complete text before the retained window plus tail",
  )
}

///|
test "dsh history keeps post-snapshot events without retaining an old window" {
  let state = {
    ..State(),
    active_id: Some("session-1"),
    events: [
      {
        type_: "turn/start",
        seq: 1,
        time: None,
        data: {},
        surface_append: None,
      },
    ],
    event_sequence: 11,
    streaming: "live",
  }
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let (_, next) = state.with_reply(dispatch, DshHistoryReply("session-1"), {
    "type": "server-response",
    "rpcId": "history-1",
    "result": {
      "ok": true,
      "value": {
        "events": [
          {
            "event": {
              "type": "assistant/message",
              "seq": 10,
              "time": 10,
              "surfaceOp": "append",
              "data": {
                "message": {
                  "content": [{ "type": "text", "text": "settled" }],
                },
              },
            },
          },
        ],
      },
    },
  })
  assert_eq(next.events.map(event => event.seq), [10])
  assert_eq(next.event_sequence, 11)
  assert_eq(next.streaming, "live")
}

///|
test "dsh history projects chunks without retaining them as transcript events" {
  let state = { ..State(), active_id: Some("session-1"), loading: true }
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let (_, next) = state.with_reply(dispatch, DshHistoryReply("session-1"), {
    "type": "server-response",
    "rpcId": "history-streaming",
    "result": {
      "ok": true,
      "value": {
        "events": [
          {
            "event": {
              "type": "user/message",
              "seq": 1,
              "surfaceOp": "append",
              "data": {
                "source": { "kind": "user" },
                "content": [{ "type": "text", "text": "question" }],
              },
            },
          },
          {
            "event": {
              "type": "assistant/chunk",
              "seq": 2,
              "data": {
                "chunk": { "type": "text-delta", "text": "partial answer" },
              },
            },
          },
        ],
      },
    },
  })
  assert_eq(next.events.map(event => event.seq), [1])
  assert_eq(next.event_sequence, 2)
  assert_eq(next.streaming, "partial answer")
}

///|
test "dsh prompt reconciliation requires a newer direct user record" {
  let reconciliation : DshPromptReconciliation = {
    session_id: "session-1",
    draft: { task: "inspect this", mentions: [] },
    generation: 1,
    after_seq: 10,
    transport_message: "reply lost",
  }
  assert_eq(
    reconciliation.accepted({
      "events": [
        {
          "event": {
            "type": "user/message",
            "seq": 11,
            "surfaceOp": "append",
            "data": {
              "source": { "kind": "user" },
              "content": [{ "type": "text", "text": "inspect this" }],
            },
          },
        },
      ],
    }),
    Some(true),
  )
  assert_eq(
    reconciliation.accepted({
      "events": [
        {
          "event": {
            "type": "user/message",
            "seq": 10,
            "surfaceOp": "append",
            "data": {
              "source": { "kind": "user" },
              "content": [{ "type": "text", "text": "inspect this" }],
            },
          },
        },
        {
          "event": {
            "type": "user/message",
            "seq": 12,
            "surfaceOp": { "op": "replace", "id": "surface" },
            "data": {
              "source": { "kind": "user" },
              "content": [{ "type": "text", "text": "inspect this" }],
            },
          },
        },
      ],
    }),
    Some(false),
  )
  assert_eq(reconciliation.accepted({ "events": null }), None)
}

///|
test "dsh prompt history settles acceptance and preserves unknown read failures" {
  let reconciliation : DshPromptReconciliation = {
    session_id: "session-1",
    draft: { task: "inspect this", mentions: [] },
    generation: 1,
    after_seq: 10,
    transport_message: "reply lost",
  }
  let state = {
    ..State(),
    active_id: Some("session-1"),
    draft: "inspect this",
    prompt_generation: 1,
    prompt_pending_session: Some("session-1"),
    prompt_reconciliation: Some(reconciliation),
    loading: true,
  }
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let accepted_history : Json = {
    "type": "server-response",
    "rpcId": "history-accepted",
    "result": {
      "ok": true,
      "value": {
        "events": [
          {
            "event": {
              "type": "user/message",
              "seq": 11,
              "surfaceOp": "append",
              "data": {
                "source": { "kind": "user" },
                "content": [{ "type": "text", "text": "inspect this" }],
              },
            },
          },
        ],
      },
    },
  }
  let (_, settled) = state.with_reply(
    dispatch,
    DshPromptHistoryReply(reconciliation),
    accepted_history,
  )
  assert_eq(settled.draft, "")
  assert_eq(settled.prompt_pending_session, None)
  assert_true(settled.prompt_reconciliation is None)

  let (_, unverified) = update(
    dispatch,
    Failed(
      kind=DshPromptHistoryReply(reconciliation),
      message="history unavailable",
    ),
    state,
  )
  assert_eq(unverified.draft, "inspect this")
  assert_eq(unverified.prompt_pending_session, Some("session-1"))
  assert_true(unverified.prompt_reconciliation is Some(_))
  assert_true(unverified.notice.contains("Refresh"))

  let no_match : Json = {
    "type": "server-response",
    "rpcId": "history-missing",
    "result": { "ok": true, "value": { "events": [] } },
  }
  let (_, retryable) = state.with_reply(
    dispatch,
    DshPromptHistoryReply(reconciliation),
    no_match,
  )
  assert_eq(retryable.draft, "inspect this")
  assert_eq(retryable.prompt_pending_session, None)
  assert_true(retryable.prompt_reconciliation is None)
  assert_true(retryable.failed_prompts.get("session-1") is Some(_))
}

///|
test "dsh single-select answers keep option and custom text exclusive" {
  let answers : Map[String, DshQuestionAnswer] = Map([])
  answers["q1"] = { selected: [], custom: "typed first" }
  let state = {
    ..State(),
    pending: [
      DshQuestions(
        rpc_id="rpc-1",
        session_id="session-1",
        questions=[
          {
            id: "q1",
            header: "Choice",
            question: "Choose",
            detail: "",
            options: [{ label: "One", description: "" }],
            multi_select: false,
          },
        ],
        answers~,
      ),
    ],
  }
  let selected = state.with_question_option("rpc-1", "q1", "One")
  guard selected.pending[0] is DshQuestions(answers=selected_answers, ..) else {
    fail("expected pending dsh questions")
  }
  assert_eq(selected_answers["q1"].selected, ["One"])
  assert_eq(selected_answers["q1"].custom, "")
  let custom = selected.with_question_custom("rpc-1", "q1", "another")
  guard custom.pending[0] is DshQuestions(answers=custom_answers, ..) else {
    fail("expected pending dsh questions")
  }
  assert_eq(custom_answers["q1"].selected, [])
  assert_eq(custom_answers["q1"].custom, "another")
}

///|
test "dsh pending snapshots preserve answers for matching questions" {
  let previous_answers : Map[String, DshQuestionAnswer] = Map([])
  previous_answers["q1"] = { selected: ["One"], custom: "" }
  previous_answers["q2"] = { selected: [], custom: "typed answer" }
  let state = {
    ..State(),
    pending: [
      DshQuestions(
        rpc_id="rpc-questions",
        session_id="session-1",
        questions=[],
        answers=previous_answers,
      ),
    ],
  }
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let (_, replayed) = state.with_reply(dispatch, DshPendingReply, {
    "generation": 2,
    "data": [
      {
        "stream": "mux",
        "generation": 2,
        "message": {
          "rpcId": "rpc-questions",
          "payload": {
            "type": "question/requested",
            "sessionId": "session-1",
            "questions": [
              {
                "id": "q1",
                "header": "Choice",
                "question": "Choose",
                "options": [{ "label": "One" }],
              },
              {
                "id": "q2",
                "header": "Detail",
                "question": "Explain",
                "options": [],
              },
              {
                "id": "q3",
                "header": "New",
                "question": "New question",
                "options": [],
              },
            ],
          },
        },
      },
    ],
  })
  guard replayed.pending is [DshQuestions(answers~, ..)] else {
    fail("expected the replayed dsh question card")
  }
  assert_eq(answers["q1"].selected, ["One"])
  assert_eq(answers["q2"].custom, "typed answer")
  assert_true(answers["q3"].selected.is_empty())
  assert_eq(answers["q3"].custom, "")
}

///|
test "dsh response and prompt replies preserve unrelated state" {
  assert_true(
    DshResponseReceipt({ "receipt": { "accepted": true }, "generation": 4 }).accepted(),
  )
  let rejected = DshResponseReceipt({
    "receipt": { "accepted": false, "reason": "bad-response" },
    "generation": 4,
  })
  assert_false(rejected.accepted())
  assert_eq(
    rejected.error(),
    "DeepSeek Harness rejected the response: bad-response",
  )
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let reply : Json = {
    "type": "server-response",
    "rpcId": "prompt-1",
    "result": { "ok": true, "value": {} },
  }
  let session_b = {
    ..State(),
    active_id: Some("session-b"),
    draft: "draft for B",
    prompt_generation: 2,
    loading: true,
  }
  let (_, stale_session) = session_b.with_reply(
    dispatch,
    DshPromptReply(
      session_id="session-a",
      draft={ task: "submitted for A", mentions: [] },
      generation=1,
    ),
    reply,
  )
  assert_eq(stale_session.draft, "draft for B")
  assert_true(stale_session.loading)
  let edited = {
    ..session_b,
    active_id: Some("session-b"),
    draft: "edited after send",
  }
  let (_, preserved) = edited.with_reply(
    dispatch,
    DshPromptReply(
      session_id="session-b",
      draft={ task: "submitted for B", mentions: [] },
      generation=2,
    ),
    reply,
  )
  assert_eq(preserved.draft, "edited after send")
  assert_false(preserved.loading)
  let submitted = { ..edited, draft: "submitted for B" }
  let (_, cleared) = submitted.with_reply(
    dispatch,
    DshPromptReply(
      session_id="session-b",
      draft={ task: "submitted for B", mentions: [] },
      generation=2,
    ),
    reply,
  )
  assert_eq(cleared.draft, "")
  let history_state = {
    ..State(),
    active_id: Some("session-b"),
    loading: true,
    notice: "current notice",
  }
  let (_, stale_history_failure) = update(
    dispatch,
    Failed(
      kind=DshHistoryReply("session-a"),
      message="old session history failed",
    ),
    history_state,
  )
  assert_true(stale_history_failure.loading)
  assert_eq(stale_history_failure.notice, "current notice")
}

///|
test "removing a background dsh session preserves the active transcript" {
  let state = {
    ..State(),
    connection: DshReady,
    workspaces: [
      {
        id: "workspace-1",
        title: "Project",
        path: "/work/project",
        session_ids: ["active", "background"],
      },
    ],
    sessions: [
      { id: "active", title: "Active", cwd: None, running: true, blank: false },
      {
        id: "background",
        title: "Background",
        cwd: None,
        running: false,
        blank: false,
      },
    ],
    active_id: Some("active"),
    events: [
      {
        type_: "turn/start",
        seq: 1,
        time: None,
        data: {},
        surface_append: None,
      },
    ],
    pending: [
      DshApproval(
        rpc_id="rpc-active",
        session_id="active",
        approval_id="approval-active",
        tool_name="read",
        reason="",
      ),
      DshApproval(
        rpc_id="rpc-background",
        session_id="background",
        approval_id="approval-background",
        tool_name="write",
        reason="",
      ),
    ],
    loading: true,
  }
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let (_, next) = update(
    dispatch,
    Event({
      "stream": "host",
      "message": {
        "rpcId": "host-1",
        "payload": { "type": "host/session-removed", "sessionId": "background" },
      },
    }),
    state,
  )
  assert_eq(next.active_id, Some("active"))
  assert_eq(next.sessions.map(row => row.id), ["active"])
  assert_eq(next.events.length(), 1)
  assert_eq(next.pending.length(), 1)
  assert_eq(next.pending[0].session_id(), "active")
  assert_true(next.workspaces.is_empty())
  assert_true(next.active_workspace_path() is None)
  assert_true(next.loading)
}

///|
test "changed or removed dsh Workspace hides cached host roots before refresh" {
  let state = {
    ..State(),
    connection: DshReady,
    sessions: [
      {
        id: "session-1",
        title: "First",
        cwd: None,
        running: false,
        blank: false,
      },
    ],
    active_id: Some("session-1"),
    workspaces: [
      {
        id: "workspace-1",
        title: "Project",
        path: "/work/project",
        session_ids: ["session-1"],
      },
    ],
  }
  assert_eq(state.active_workspace_path(), Some("/work/project"))
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let (_, next) = update(
    dispatch,
    Event({
      "stream": "host",
      "message": {
        "rpcId": "host-workspace-1",
        "payload": {
          "type": "host/workspace-removed",
          "workspaceId": "workspace-1",
        },
      },
    }),
    state,
  )
  assert_true(next.workspaces.is_empty())
  assert_true(next.active_workspace_path() is None)
  assert_true(next.loading)
  let (_, changed) = update(
    dispatch,
    Event({
      "stream": "host",
      "message": {
        "rpcId": "host-workspace-2",
        "payload": {
          "type": "host/workspace-changed",
          "workspaceId": "workspace-1",
        },
      },
    }),
    state,
  )
  assert_true(changed.workspaces.is_empty())
  assert_true(changed.active_workspace_path() is None)
  assert_true(changed.loading)
}

///|
test "removing the active dsh session initializes its fallback composer" {
  let selected : DshModelSelection = {
    provider: "deepseek",
    model: "chat",
    reasoning_effort: None,
  }
  let state = {
    ..State(),
    sessions: [
      {
        id: "removed",
        title: "Removed",
        cwd: None,
        running: false,
        blank: true,
      },
      {
        id: "fallback",
        title: "Fallback",
        cwd: None,
        running: false,
        blank: true,
      },
    ],
    active_id: Some("removed"),
    events: [
      {
        type_: "turn/start",
        seq: 1,
        time: None,
        data: {},
        surface_append: None,
      },
    ],
    models: DshModelsReady(
      session_id="removed",
      options=[{ selection: selected, label: "DeepSeek / Chat" }],
      selected~,
      routable=true,
    ),
    placement: @composer.FreshWorktree,
    worktree_project: Some("/projects/removed"),
    draft: "removed draft",
  }
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let (_, next) = update(
    dispatch,
    Event({
      "stream": "host",
      "message": {
        "rpcId": "host-1",
        "payload": { "type": "host/session-removed", "sessionId": "removed" },
      },
    }),
    state,
  )
  assert_eq(next.active_id, Some("fallback"))
  assert_eq(next.events.length(), 0)
  assert_eq(next.draft, "")
  assert_true(next.models is DshModelsLoading(session_id="fallback"))
  assert_true(next.placement is @composer.LocalCheckout)
  assert_eq(next.worktree_project, None)
  assert_true(next.loading)
}

///|
test "dsh model selection settles the shared composer catalog" {
  let current : DshModelSelection = {
    provider: "deepseek",
    model: "chat",
    reasoning_effort: None,
  }
  let requested : DshModelSelection = {
    provider: "deepseek",
    model: "reasoner",
    reasoning_effort: Some("high"),
  }
  let state = {
    ..State(),
    connection: DshReady,
    active_id: Some("session-1"),
    notice: "old model error",
    models: DshModelsReady(
      session_id="session-1",
      options=[
        { selection: current, label: "DeepSeek / Chat" },
        { selection: requested, label: "DeepSeek / Reasoner · High" },
      ],
      selected=current,
      routable=true,
    ),
  }
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let (_, selecting) = update(dispatch, ModelChanged(requested.key()), state)
  // Starting a new selection dismisses the prior diagnostic explicitly.
  assert_eq(selecting.notice, "")
  guard selecting.models is DshModelsSelecting(requested=selection, ..) else {
    fail("expected selecting dsh model state")
  }
  assert_eq(selection, requested)
  // An unrelated failure may arrive after the request starts. The successful
  // selection reply must not erase that newer diagnostic.
  let selecting = { ..selecting, notice: "newer prompt failure" }
  let (_, ready) = selecting.with_reply(
    dispatch,
    DshSelectModelReply(session_id="session-1"),
    {
      "type": "server-response",
      "rpcId": "model-1",
      "result": {
        "ok": true,
        "value": {
          "selected": {
            "provider": "deepseek",
            "model": "reasoner",
            "reasoningEffort": "high",
          },
        },
      },
    },
  )
  guard ready.models is DshModelsReady(selected~, routable~, ..) else {
    fail("expected selected dsh model state")
  }
  assert_eq(selected, requested)
  assert_true(routable)
  assert_eq(ready.notice, "newer prompt failure")
  let refreshing = {
    ..ready,
    models: DshModelsLoading(session_id="session-1"),
    notice: "newer interaction failure",
  }
  let (_, refreshed) = refreshing.with_reply(
    dispatch,
    DshModelsReply("session-1"),
    {
      "type": "server-response",
      "rpcId": "models-1",
      "result": {
        "ok": true,
        "value": {
          "current": {
            "provider": "deepseek",
            "model": "reasoner",
            "reasoningEffort": "high",
          },
          "routable": true,
          "groups": [],
        },
      },
    },
  )
  assert_eq(refreshed.notice, "newer interaction failure")
  let navigated = { ..ready, active_id: Some("session-2") }
  let (_, stale) = update(
    dispatch,
    Failed(
      kind=DshSelectModelReply(session_id="session-1"),
      message="late selection failure",
    ),
    navigated,
  )
  assert_true(stale == navigated)
}

///|
/// The Worktree first-send pipeline. dsh cannot move a conversation between
/// directories, so choosing Worktree provisions a checkout, registers it as a
/// dsh Workspace, and starts a NEW conversation inside it. The blank one the
/// user typed in keeps its own directory; only the submission — its fence,
/// its draft, and its diagnostics — follows the created session.
test "a Worktree first send starts the conversation inside the new checkout" {
  let selected : DshModelSelection = {
    provider: "deepseek",
    model: "chat",
    reasoning_effort: None,
  }
  let state = {
    ..State(),
    connection: DshReady,
    workspaces: [
      {
        id: "workspace-main",
        title: "Project",
        path: "/work/project",
        session_ids: ["session-1"],
      },
    ],
    sessions: [
      {
        id: "session-1",
        title: "New conversation",
        cwd: Some("/work/project"),
        running: false,
        blank: true,
      },
    ],
    active_id: Some("session-1"),
    models: DshModelsReady(
      session_id="session-1",
      options=[{ selection: selected, label: "DeepSeek / Chat" }],
      selected~,
      routable=true,
    ),
    draft: "inspect this project",
    event_sequence: 17,
  }
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let draft : @composer.Draft = { task: "inspect this project", mentions: [] }
  let (_, worktree) = update(dispatch, ToggleWorktreeMode, state)
  assert_true(worktree.placement is @composer.FreshWorktree)
  assert_eq(worktree.worktree_project, Some("/work/project"))
  let (_, sending) = update(dispatch, Send, worktree)
  assert_eq(sending.prompt_generation, 1)
  assert_eq(sending.prompt_pending_session, Some("session-1"))
  assert_eq(sending.prompt_after_seq, 17)
  // A completion from an older submission cannot restart the pipeline.
  let (_, stale) = update(
    dispatch,
    WorktreeReady(
      session_id="session-1",
      generation=0,
      project="/work/project",
      path="/work/project/.worktrees/wt-1",
      draft~,
    ),
    sending,
  )
  assert_true(stale == sending)
  let (_, registered) = update(
    dispatch,
    WorktreeReady(
      session_id="session-1",
      generation=1,
      project="/work/project",
      path="/work/project/.worktrees/wt-1",
      draft~,
    ),
    sending,
  )
  let workspace_created : Json = {
    "type": "server-response",
    "rpcId": "workspace-1",
    "result": {
      "ok": true,
      "value": {
        "workspace": {
          "workspaceId": "workspace-worktree",
          "title": "wt-1",
          "path": "/work/project/.worktrees/wt-1",
          "sessionIds": [],
        },
      },
    },
  }
  let workspace_reply = DshPromptWorkspaceReply(
    session_id="session-1",
    generation=1,
    draft~,
  )
  let session_reply = DshPromptSessionReply(
    session_id="session-1",
    generation=1,
    draft~,
  )
  let (_, adopting) = registered.with_reply(
    dispatch, workspace_reply, workspace_created,
  )
  // Registering the directory changes nothing the page renders; the fence
  // still belongs to the conversation the user submitted from.
  assert_eq(adopting.prompt_pending_session, Some("session-1"))
  let session_created : Json = {
    "type": "server-response",
    "rpcId": "session-1",
    "result": { "ok": true, "value": { "sessionId": "session-wt" } },
  }
  let (_, started) = adopting.with_reply(
    dispatch, session_reply, session_created,
  )
  // The prompt now belongs to the created session, and so does the page.
  assert_eq(started.active_id, Some("session-wt"))
  assert_eq(started.prompt_pending_session, Some("session-wt"))
  assert_eq(started.selection_generation, state.selection_generation + 1)
  // Placement resets like any other selection change. Leaving it armed would
  // make this conversation's next message provision a second checkout as soon
  // as a session list reported it blank again.
  assert_true(started.placement is @composer.LocalCheckout)
  assert_eq(started.worktree_project, None)
  // The reconciliation baseline belongs to the created conversation, which
  // has no events, not to the one the draft was typed in.
  assert_eq(started.prompt_after_seq, -1)
  assert_true(started.models is DshModelsLoading(session_id="session-wt"))
  assert_true(started.events.is_empty())
  assert_eq(started.streaming, "")
  assert_true(started.busy())
  let (_, settled) = started.with_reply(
    dispatch,
    DshPromptReply(session_id="session-wt", draft~, generation=1),
    {
      "type": "server-response",
      "rpcId": "prompt-1",
      "result": { "ok": true, "value": {} },
    },
  )
  assert_eq(settled.active_id, Some("session-wt"))
  assert_eq(settled.prompt_pending_session, None)
  assert_eq(settled.draft, "")
  // The submission fence is released; the page stays busy only until the
  // created session's own model catalog arrives.
  assert_true(settled.models is DshModelsLoading(session_id="session-wt"))
  // Navigating away before the session exists leaves the visible page alone,
  // but the prompt still reaches the conversation dsh created for it.
  let navigated = {
    ..adopting,
    active_id: Some("session-2"),
    placement: @composer.LocalCheckout,
    worktree_project: None,
    draft: "draft for session 2",
    loading: false,
    notice: "session 2 notice",
  }
  let (_, background_started) = navigated.with_reply(
    dispatch, session_reply, session_created,
  )
  assert_eq(background_started.active_id, Some("session-2"))
  assert_eq(background_started.draft, "draft for session 2")
  assert_eq(background_started.notice, "session 2 notice")
  assert_eq(background_started.prompt_pending_session, Some("session-wt"))
  // Every stage that can fail settles the fence and keeps the draft, because
  // no stage leaves cleanup work behind: the checkout it may already have
  // created is an ordinary worktree the user can remove.
  for
    failure in [
      Failed(kind=workspace_reply, message="workspace.create failed"),
      Failed(kind=session_reply, message="session.create failed"),
    ] {
    let (_, failed) = update(dispatch, failure, adopting)
    assert_eq(failed.prompt_pending_session, None)
    assert_false(failed.busy())
    assert_false(failed.loading)
    let (_, reopened) = update(dispatch, OpenSession("session-1"), {
      ..failed,
      active_id: Some("session-2"),
      draft: "elsewhere",
    })
    assert_eq(reopened.draft, "inspect this project")
  }
  // A malformed success is a failure of the same shape.
  let (_, malformed) = adopting.with_reply(dispatch, session_reply, {
    "type": "server-response",
    "rpcId": "session-2",
    "result": { "ok": true, "value": {} },
  })
  assert_eq(malformed.prompt_pending_session, None)
  assert_true(malformed.notice.contains("malformed session.create reply"))
  // Each stage commits durable state in dsh, so a stage whose submission has
  // already ended — a newer Send, or a fence released by failure or by dsh
  // dropping the originating session — must build nothing further. Without
  // this the session stage would seize the visible conversation and re-send a
  // draft under a generation whose own reply is then discarded.
  for
    ended in [
      ({ ..adopting, prompt_pending_session: None } : State),
      { ..adopting, prompt_pending_session: Some("session-9") },
      { ..adopting, prompt_generation: adopting.prompt_generation + 1 },
    ] {
    let (_, after_session) = ended.with_reply(
      dispatch, session_reply, session_created,
    )
    assert_true(after_session == ended)
    let (_, after_workspace) = ended.with_reply(
      dispatch, workspace_reply, workspace_created,
    )
    assert_true(after_workspace == ended)
  }
}

///|
/// Archiving is this page's only cleanup verb — dsh has no delete — and it is
/// what makes a first-send leftover, or a checkout someone still occupies,
/// disposable at all.
test "archiving a dsh conversation hides it and releases the page" {
  let state = {
    ..State(),
    connection: DshReady,
    workspaces: [
      {
        id: "workspace-main",
        title: "project",
        path: "/work/project",
        session_ids: ["session-1", "session-2"],
      },
    ],
    sessions: [
      {
        id: "session-1",
        title: "keep",
        cwd: Some("/work/project"),
        running: false,
        blank: false,
      },
      {
        id: "session-2",
        title: "leftover",
        cwd: Some("/work/project"),
        running: false,
        blank: true,
      },
    ],
    active_id: Some("session-2"),
    events: [
      {
        type_: "user/message",
        seq: 4,
        time: None,
        data: {},
        surface_append: None,
      },
    ],
    event_sequence: 4,
    streaming: "partial",
  }
  let dispatch : @cmd.Emit[Msg] = @cmd.Emit(_ => @cmd.none)
  let (_, archiving) = update(dispatch, ArchiveSession("session-2"), state)
  assert_true(archiving.loading)
  let (_, archived) = archiving.with_reply(
    dispatch,
    DshArchiveReply(session_id="session-2"),
    {
      "type": "server-response",
      "rpcId": "archive-1",
      "result": { "ok": true, "value": { "archivedSessionIds": ["session-2"] } },
    },
  )
  assert_eq(archived.archived_session_ids, ["session-2"])
  // The conversation the user was reading is the one that went away, so the
  // page lets go of it rather than rendering a hidden transcript.
  assert_eq(archived.active_id, None)
  assert_true(archived.events.is_empty())
  assert_eq(archived.streaming, "")
  assert_false(archived.loading)
  // dsh keeps the session in its Workspace account; the sidebar is what
  // stops showing it.
  guard archived.sidebar_section(true).entries[0] is @section.Project(project) else {
    fail("expected the project row")
  }
  guard project.conversations is [kept] else {
    fail("expected only the unarchived conversation")
  }
  assert_eq(kept.label, "keep")
  // Archiving a conversation the user is not reading leaves the page alone.
  let (_, other) = { ..archived, active_id: Some("session-1") }.with_reply(
    dispatch,
    DshArchiveReply(session_id="session-2"),
    {
      "type": "server-response",
      "rpcId": "archive-2",
      "result": { "ok": true, "value": { "archivedSessionIds": ["session-2"] } },
    },
  )
  assert_eq(other.active_id, Some("session-1"))
  // Removing a Workspace registration re-reads both baselines: its sessions
  // become ungrouped rather than disappearing.
  let (_, removing) = update(dispatch, RemoveWorkspace("workspace-main"), state)
  assert_true(removing.loading)
  let (_, removed) = removing.with_reply(dispatch, DshWorkspaceDeleteReply, {
    "type": "server-response",
    "rpcId": "delete-1",
    "result": { "ok": true, "value": { "deleted": true } },
  })
  assert_true(removed.loading)
}
