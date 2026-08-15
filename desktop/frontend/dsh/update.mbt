// All dsh-local transitions. Full ApiProxy envelopes and WebSocket frames are
// decoded here, never in the root OpenSeek model.

///|
pub fn update(
  dispatch : @cmd.Emit[Msg],
  msg : Msg,
  state : State,
) -> (@cmd.Cmd, State) {
  match msg {
    Refresh => (state.refresh(dispatch), { ..state, loading: true, notice: "" })
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
      (
        state.load_history(dispatch, session_id),
        {
          ..state,
          active_id: Some(session_id),
          selection_generation: if selection_changed {
            state.selection_generation + 1
          } else {
            state.selection_generation
          },
          draft: if selection_changed {
            ""
          } else {
            state.draft
          },
          events: [],
          streaming: "",
          loading: true,
          notice: "",
        },
      )
    }
    DraftChanged(value) => (@cmd.none, { ..state, draft: value })
    Send =>
      if state.busy() || state.draft.trim().is_empty() || !state.has_active() {
        (@cmd.none, state)
      } else {
        let generation = state.prompt_generation + 1
        (
          state.send(dispatch, generation),
          {
            ..state,
            prompt_generation: generation,
            prompt_pending_session: state.active_id,
            loading: true,
            notice: "",
          },
        )
      }
    Stop =>
      if state.busy() || !state.is_running() {
        (@cmd.none, state)
      } else {
        (
          state.cancel(dispatch),
          {
            ..state,
            cancel_pending_session: state.active_id,
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
    Reply(kind~, value~) => {
      if kind is DshPromptReply(session_id~, generation~, ..) {
        if state.prompt_generation != generation {
          return (@cmd.none, state)
        }
        if state.active_id != Some(session_id) {
          return (@cmd.none, { ..state, prompt_pending_session: None })
        }
      }
      // dsh reports application failures inside successful HTTP responses.
      // Apply the same origin checks used by `Failed` before `with_reply`
      // reaches its generic business-error envelope branch.
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
            cancel_pending_session: if state.cancel_pending_session ==
              Some(session_id) {
              None
            } else {
              state.cancel_pending_session
            },
          },
        )
      }
      state.with_reply(dispatch, kind, value)
    }
    Failed(kind~, message~) => {
      // A reply belongs to the page state that submitted it. Session changes
      // and later sends must not clear another conversation's draft/loading.
      if kind is DshPromptReply(session_id~, generation~, ..) {
        if state.prompt_generation != generation {
          return (@cmd.none, state)
        }
        if state.active_id != Some(session_id) {
          return (@cmd.none, { ..state, prompt_pending_session: None })
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
            cancel_pending_session: if state.cancel_pending_session ==
              Some(session_id) {
              None
            } else {
              state.cancel_pending_session
            },
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
      (
        @cmd.none,
        {
          ..state,
          connection: if kind is DshStatusReply {
            DshUnavailable(message)
          } else {
            state.connection
          },
          loading: if kind is DshPendingReply {
            state.loading
          } else {
            false
          },
          prompt_pending_session: if kind is DshPromptReply(..) {
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
          cancel_pending_session: if kind is DshCancelReply(_) {
            None
          } else {
            state.cancel_pending_session
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
    let pending = self.pending.filter(item => item.rpc_id() != rpc_id)
    return (
      @cmd.none,
      if self.active_id == Some(session_id) {
        { ..self, pending, response_pending_rpcs, loading: false }
      } else {
        { ..self, pending, response_pending_rpcs }
      },
    )
  }
  let envelope = DshEnvelope(reply)
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
    return (
      @cmd.none,
      {
        ..self,
        prompt_pending_session: if kind is DshPromptReply(..) {
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
        cancel_pending_session: if kind is DshCancelReply(_) {
          None
        } else {
          self.cancel_pending_session
        },
        loading: false,
        notice: envelope.error(),
      },
    )
  }
  match kind {
    DshReconnectReply | DshWorkspacesReply => {
      let workspaces : Array[DshWorkspaceRow] = []
      if value is Object(fields) && fields.get("items") is Some(Array(items)) {
        for item in items {
          if DshWorkspaceRow::decode(item) is Some(workspace) {
            workspaces.push(workspace)
          }
        }
      }
      (
        if kind is DshReconnectReply {
          @cmd.batch([
            DshSessionsReply.request(dispatch, "session.list", {}),
            DshPendingReply.pending(dispatch),
          ])
        } else {
          @cmd.none
        },
        { ..self, connection: DshReady, workspaces, loading: false, notice: "" },
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
    DshSessionsReply => {
      let sessions : Array[DshSessionRow] = []
      if value is Object(fields) && fields.get("items") is Some(Array(items)) {
        for item in items {
          if DshSessionRow::decode(item) is Some(row) {
            sessions.push(row)
          }
        }
      }
      let active_id = match self.active_id {
        Some(id) if sessions.iter().any(row => row.id == id) => Some(id)
        _ => sessions.get(0).map(row => row.id)
      }
      let selection_changed = self.active_id != active_id
      let next = {
        ..self,
        connection: DshReady,
        sessions,
        active_id,
        selection_generation: if selection_changed {
          self.selection_generation + 1
        } else {
          self.selection_generation
        },
        draft: if selection_changed {
          ""
        } else {
          self.draft
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
        loading: false,
        notice: "",
      }
      match active_id {
        Some(id) if selection_changed =>
          (next.load_history(dispatch, id), { ..next, loading: true })
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
        DshSessionsReply.request(dispatch, "session.list", {}),
      ]
      if activate {
        commands.push(self.load_history(dispatch, session_id))
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
            streaming: "",
            loading: true,
            notice: "",
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
      (
        @cmd.none,
        {
          ..self,
          streaming: DshEventLog(events).streaming_text(),
          events,
          loading: false,
          notice: "",
        },
      )
    }
    DshPromptReply(session_id~, draft~, generation~) => {
      guard self.active_id == Some(session_id) &&
        self.prompt_generation == generation else {
        return (@cmd.none, self)
      }
      (
        self.load_history(dispatch, session_id),
        {
          ..self,
          draft: if self.draft == draft {
            ""
          } else {
            self.draft
          },
          prompt_pending_session: None,
          loading: false,
          notice: "",
        },
      )
    }
    DshCancelReply(session_id) =>
      if self.active_id == Some(session_id) {
        (
          @cmd.none,
          { ..self, cancel_pending_session: None, loading: false, notice: "" },
        )
      } else {
        (
          @cmd.none,
          {
            ..self,
            cancel_pending_session: if self.cancel_pending_session ==
              Some(session_id) {
              None
            } else {
              self.cancel_pending_session
            },
          },
        )
      }
    DshStatusReply | DshPendingReply | DshResponseReply(..) => (@cmd.none, self)
  }
}

///|
fn State::with_status(
  self : State,
  dispatch : @cmd.Emit[Msg],
  value : Json,
) -> (@cmd.Cmd, State) {
  guard value is Object(fields) &&
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
  match status {
    "ready" =>
      (
        @cmd.batch([
          DshWorkspacesReply.request(dispatch, "workspace.list", {}),
          DshSessionsReply.request(dispatch, "session.list", {}),
          DshPendingReply.pending(dispatch),
        ]),
        { ..self, connection: DshReady, loading: true, notice: "" },
      )
    "starting" =>
      (
        @cmd.none,
        { ..self, connection: DshStarting, pending: [], loading: false },
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
  next = {
    ..next,
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
      let events = self.events.copy()
      if !events.iter().any(item => item.seq == event.seq) {
        events.push(event)
      }
      events.sort_by((left, right) => left.seq - right.seq)
      let streaming = DshEventLog(events).streaming_text()
      (@cmd.none, { ..self, sessions, events, streaming })
    }
    "host/session-status" => {
      guard @jsonx.json_text(payload, "sessionId") is Some(session_id) &&
        @jsonx.json_bool(payload, "running") is Some(running) else {
        return (@cmd.none, self)
      }
      let sessions = self.sessions.map(row => {
        if row.id == session_id {
          { ..row, running, blank: if running { false } else { row.blank } }
        } else {
          row
        }
      })
      (
        @cmd.none,
        {
          ..self,
          sessions,
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
          DshSessionsReply.request(dispatch, "session.list", {}),
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
      let pending = self.pending.filter(item => item.session_id() != session_id)
      (
        @cmd.batch([
          DshWorkspacesReply.request(dispatch, "workspace.list", {}),
          // A session list already in flight may still contain the removed
          // row. Queue a fresh snapshot behind it so the session-list lane
          // makes this event's state the final baseline.
          DshSessionsReply.request(dispatch, "session.list", {}),
          match active_id {
            Some(id) if active_id != self.active_id =>
              self.load_history(dispatch, id)
            _ => @cmd.none
          },
        ]),
        {
          ..self,
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
          pending,
          response_pending_rpcs: self.response_pending_rpcs.filter(rpc_id => {
            pending.iter().any(item => item.rpc_id() == rpc_id)
          }),
          draft: if removed_active {
            ""
          } else {
            self.draft
          },
          prompt_pending_session: if self.prompt_pending_session ==
            Some(session_id) {
            None
          } else {
            self.prompt_pending_session
          },
          cancel_pending_session: if self.cancel_pending_session ==
            Some(session_id) {
            None
          } else {
            self.cancel_pending_session
          },
          loading: if removed_active {
            active_id is Some(_)
          } else {
            self.loading
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
        payload.get("value") is Some(String(title)) else {
        return (@cmd.none, self)
      }
      let sessions = self.sessions.map(row => {
        if row.id == session_id && !title.trim().is_empty() {
          { ..row, title, }
        } else {
          row
        }
      })
      (@cmd.none, { ..self, sessions, })
    }
    "host/workspace-changed" | "host/workspace-removed" =>
      (
        DshWorkspacesReply.request(dispatch, "workspace.list", {}),
        { ..self, loading: true },
      )
    "approval/requested" => {
      let generation = @jsonx.json_int(wrapper, "generation").unwrap_or(
        self.pending_generation,
      )
      if generation < self.pending_generation {
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
      (@cmd.none, { ..self, pending, pending_generation: generation })
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
      pending.push(DshQuestions(rpc_id~, session_id~, questions~, answers~))
      (@cmd.none, { ..self, pending, pending_generation: generation })
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
priv struct DshEventLog(Array[DshEventRecord])

///|
fn DshEventLog::streaming_text(self : DshEventLog) -> String {
  let mut text = ""
  for event in self.0 {
    if event.type_ == "assistant/message" && event.surface_append == Some(true) {
      text = ""
    } else if event.streaming_delta() is Some(delta) {
      text += delta
    }
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
  let state = {
    ..State(),
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
  let ungrouped = { ..grouped, active_id: Some("session-2") }
  assert_eq(ungrouped.preferred_workspace_id(), Some("workspace-1"))
  assert_true(ungrouped.active_workspace_path() is None)
}

///|
test "dsh reconnect reply restores workspace state without transcript errors" {
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
    retrying,
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
  })
  assert_false(running.loading)
  assert_true(running.busy())
  let (_, blocked) = update(dispatch, Send, running)
  assert_eq(blocked.prompt_generation, 1)
  let (_, settled) = update(
    dispatch,
    Reply(
      kind=DshPromptReply(session_id="session-1", draft="hello", generation=1),
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
    { "accepted": true },
  )
  assert_true(settled.response_pending_rpcs.is_empty())
  assert_true(settled.pending.is_empty())
  assert_false(settled.loading)
  assert_false(settled.busy())
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
  let (_, next) = state.with_reply(dispatch, DshSessionsReply, {
    "type": "server-response",
    "rpcId": "session-list",
    "result": { "ok": true, "value": { "items": [] } },
  })
  assert_true(next.active_id is None)
  assert_true(next.events.is_empty())
  assert_eq(next.streaming, "")
  assert_eq(next.draft, "")
  assert_false(next.loading)
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
    cancel_pending_session: Some("session-a"),
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
  assert_true(stale_success.cancel_pending_session is None)
  assert_true(stale_success.loading)
  assert_eq(stale_success.notice, "current notice")
  let (_, stale_failure) = update(
    dispatch,
    Failed(kind=DshCancelReply("session-a"), message="cancel failed"),
    state,
  )
  assert_true(stale_failure.cancel_pending_session is None)
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
  assert_eq(cancelling.cancel_pending_session, Some("session-1"))
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
  assert_true(settled.cancel_pending_session is None)
  assert_false(settled.loading)
  assert_false(settled.busy())
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
    { "accepted": true },
  )
  assert_true(accepted.pending.is_empty())
  assert_true(accepted.response_pending_rpcs.is_empty())
  assert_true(accepted.loading)
  assert_eq(accepted.notice, "session B notice")
  let (_, rejected) = state.with_reply(
    dispatch,
    DshResponseReply(rpc_id="rpc-a", session_id="session-a"),
    { "accepted": false, "reason": "stale request" },
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
      {
        type_: "assistant/chunk",
        seq: 11,
        time: None,
        data: { "chunk": { "type": "text-delta", "text": "live" } },
        surface_append: None,
      },
    ],
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
  assert_eq(next.events.map(event => event.seq), [10, 11])
  assert_eq(next.streaming, "live")
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
test "dsh response and prompt replies preserve unrelated state" {
  assert_true(DshResponseReceipt({ "accepted": true }).accepted())
  let rejected = DshResponseReceipt({
    "accepted": false,
    "reason": "bad-response",
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
      draft="submitted for A",
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
      draft="submitted for B",
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
      draft="submitted for B",
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
  assert_true(next.loading)
}
