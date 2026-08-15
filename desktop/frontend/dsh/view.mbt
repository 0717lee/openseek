// dsh's view adapters. The root supplies the shared transcript DOM; this page
// supplies only dsh-specific navigation, controls, and interaction cards.

///|
/// Supply one dsh session to the shared sidebar conversation component. The
/// root dispatcher translates the stable id back into a dsh navigation
/// message; this adapter contains no commands or component-local state.
fn DshSessionRow::sidebar_input(
  self : DshSessionRow,
  state : State,
  nested : Bool,
  selected : Bool,
) -> @conversation.Input {
  let active = selected && state.active_id == Some(self.id)
  {
    id: @conversation.Id(
      source="dsh.live",
      channel=@interop.ChannelId::Local.uri_authority(),
      conversation=self.id,
    ),
    title: self.cwd.unwrap_or(self.id),
    label: self.title,
    nested,
    subrun: false,
    active,
    running: self.running,
    openable: true,
    worktree: None,
    run_mark: if self.running {
      @conversation.RunningMark
    } else {
      @conversation.NoRunMark
    },
    trailing: [],
    children: [],
  }
}

///|
/// dsh contributes one plain Section input to the shared sidebar component.
/// Workspace ids remain the action identity while their canonical paths are
/// display-only here; the host authorizes Files and Terminal from the latest
/// dsh `workspace.list` reply, never from these rows.
pub fn State::sidebar_section(self : State, selected : Bool) -> @section.Input {
  let entries : Array[@section.Entry] = []
  let accounted : Array[String] = []
  for workspace in self.workspaces {
    let conversations : Array[@conversation.Input] = []
    for session_id in workspace.session_ids {
      accounted.push(session_id)
      if self.sessions.iter().find_first(row => row.id == session_id)
        is Some(session) {
        conversations.push(session.sidebar_input(self, true, selected))
      }
    }
    let active = selected &&
      self
      .active_workspace_row()
      .map(item => item.id == workspace.id)
      .unwrap_or(false)
    entries.push(
      @section.Project({
        id: @project.Id(
          source="dsh.workspaces",
          channel=@interop.ChannelId::Local.uri_authority(),
          root=workspace.id,
        ),
        title: workspace.path,
        label: workspace.title,
        activation: if active {
          self.active_id
        } else {
          None
        },
        can_start: self.can_create(),
        managed: false,
        conversations,
        empty_label: Some("No conversations yet"),
      }),
    )
  }
  let ungrouped = self.sessions.filter(session => {
    !accounted.contains(session.id)
  })
  if !ungrouped.is_empty() {
    let conversations = ungrouped.map(session => {
      session.sidebar_input(self, true, selected)
    })
    entries.push(
      @section.Project({
        id: @project.Id(
          source="dsh.ungrouped",
          channel=@interop.ChannelId::Local.uri_authority(),
          root="ungrouped",
        ),
        title: "Sessions not attached to a dsh Workspace",
        label: "Ungrouped",
        activation: if selected &&
          self.active_id
          .map(id => ungrouped.iter().any(row => row.id == id))
          .unwrap_or(false) {
          self.active_id
        } else {
          None
        },
        can_start: false,
        managed: false,
        conversations,
        empty_label: None,
      }),
    )
  }
  // Retained Workspace rows are only a cached snapshot while dsh is down.
  // Keep the openable row visible so selecting it can ask the actor to retry.
  if entries.is_empty() || self.connection is DshUnavailable(_) {
    entries.push(
      @section.Placeholder({
        id: "dsh.open",
        label: match self.connection {
          DshStarting => "Starting DeepSeek Harness…"
          DshUnavailable(_) => "DeepSeek Harness is unavailable"
          DshReady => "No dsh conversations yet"
        },
        class_name: "dsh-placeholder",
        nested: false,
        openable: true,
      }),
    )
  }
  {
    id: @section.Id(
      source="dsh",
      channel=@interop.ChannelId::Local.uri_authority(),
    ),
    label: "DeepSeek Harness",
    initially_collapsed: false,
    activation: if selected {
      self.active_id
    } else {
      None
    },
    action: Some({
      title: "New DeepSeek Harness conversation",
      disabled: !self.can_create(),
    }),
    entries,
  }
}

///|
test "unavailable dsh keeps a retry row beside retained workspaces" {
  let state = {
    ..State(),
    connection: DshUnavailable("dsh stopped"),
    workspaces: [
      {
        id: "workspace-1",
        title: "OpenSeek",
        path: "/work/openseek",
        session_ids: [],
      },
    ],
  }
  let section = state.sidebar_section(false)
  assert_eq(section.entries.length(), 2)
  guard section.entries[1] is @section.Placeholder(retry) else {
    fail("expected an unavailable retry row after the retained workspace")
  }
  assert_eq(retry.id, "dsh.open")
  assert_eq(retry.label, "DeepSeek Harness is unavailable")
  assert_true(retry.openable)
}

///|
pub(all) struct PageActions {
  toggle_sidebar : @cmd.Cmd
  toggle_terminal : @cmd.Cmd
  toggle_files : @cmd.Cmd
  transcript : @html.Html
}

///|
pub fn State::page(
  self : State,
  dispatch : @cmd.Emit[Msg],
  sidebar_open : Bool,
  terminal_open : Bool,
  file_panel_open : Bool,
  actions : PageActions,
) -> Array[@html.Html] {
  let topbar : Array[@html.Html] = []
  if !sidebar_open {
    topbar.push(
      @html.button(
        class="topbar-toggle",
        title="Show sidebar",
        on_click=actions.toggle_sidebar,
        "☰",
      ),
    )
  }
  topbar.push(
    @html.span(
      class="topbar-title",
      title=self.active_row().bind(row => row.cwd).unwrap_or("dsh web"),
      self.active_title(),
    ),
  )
  let workspace = self.active_workspace_row()
  if workspace is Some(workspace) {
    topbar.push(
      @html.span(class="topbar-workspace", title=workspace.path, [
        @icons.icon(@icons.icon_folder),
        @html.text(workspace.title),
      ]),
    )
  }
  topbar.push(
    @html.div(
      class=if self.is_running() { "run-status accent" } else { "run-status" },
      [
        @html.span(
          class=if self.is_running() {
            "run-dot accent pulse"
          } else {
            "run-dot"
          },
          "",
        ),
        @html.span(class="run-text", self.connection_label()),
      ],
    ),
  )
  topbar.push(
    @html.button(
      class=if terminal_open { "panel-toggle active" } else { "panel-toggle" },
      disabled=workspace is None,
      title=if terminal_open {
        "Hide terminal"
      } else if workspace is Some(_) {
        "Show terminal"
      } else {
        "Terminal requires a dsh Workspace"
      },
      on_click=actions.toggle_terminal,
      @icons.icon(@icons.icon_terminal),
    ),
  )
  if !file_panel_open {
    topbar.push(
      @html.button(
        class="panel-toggle",
        disabled=workspace is None,
        title=if workspace is Some(_) {
          "Show files"
        } else {
          "Files require a dsh Workspace"
        },
        on_click=actions.toggle_files,
        @icons.icon(@icons.icon_layout_sidebar_right),
      ),
    )
  }
  [
    @html.div(class="topbar dsh-topbar", topbar),
    actions.transcript,
    self.composer(dispatch),
  ]
}

///|
fn State::composer(self : State, dispatch : @cmd.Emit[Msg]) -> @html.Html {
  let interactions : Array[@html.Html] = []
  let busy = self.busy()
  for pending in self.pending {
    // dsh can run several sessions concurrently. Keep background requests in
    // state for later, but render only cards owned by the selected session.
    if self.active_id == Some(pending.session_id()) {
      interactions.push(pending.view(dispatch, busy))
    }
  }
  let running = self.is_running()
  let disabled = !(self.connection is DshReady) || !self.has_active()
  let action = if running {
    @composer.ActionButton::{
      id: "dsh-stop",
      class_name: "stop",
      title: "Stop DeepSeek Harness",
      disabled: busy,
      command: dispatch(Stop),
      content: @html.text("■"),
    }
  } else {
    @composer.ActionButton::{
      id: "dsh-send",
      class_name: "send",
      title: "Send to DeepSeek Harness",
      disabled: disabled || busy || self.draft.trim().is_empty(),
      command: dispatch(Send),
      content: @html.text("↑"),
    }
  }
  @composer.View::{
    before_inner: interactions,
    mentions: [],
    value: self.draft,
    placeholder: if self.has_active() {
      "Ask DeepSeek Harness…"
    } else {
      "Create or select a dsh conversation"
    },
    disabled,
    input: dispatch.map(value => DraftChanged(value)),
    keyboard: @composer.KeyboardActions::{
      menu_open: false,
      navigate: _ => @cmd.none,
      accept: @cmd.none,
      dismiss: @cmd.none,
      submit: dispatch(Send),
      cancel: if running {
        Some(dispatch(Stop))
      } else {
        None
      },
    },
    status: [],
    action,
    overlay: None,
  }.render()
}

///|
fn DshPendingInteraction::view(
  self : DshPendingInteraction,
  dispatch : @cmd.Emit[Msg],
  loading : Bool,
) -> @html.Html {
  match self {
    DshApproval(rpc_id~, tool_name~, reason~, ..) => {
      let body : Array[@html.Html] = [
        @html.div(class="codex-request-title", "Allow \{tool_name}?"),
      ]
      if !reason.is_empty() {
        body.push(@html.div(class="codex-request-reason", reason))
      }
      body.push(
        @html.div(class="codex-request-actions", [
          @html.button(
            disabled=loading,
            on_click=dispatch(ApprovalDecision(rpc_id~, outcome="rejected")),
            "Reject",
          ),
          @html.button(
            class="primary",
            disabled=loading,
            on_click=dispatch(ApprovalDecision(rpc_id~, outcome="allowed-once")),
            "Allow once",
          ),
        ]),
      )
      @html.div(class="codex-request dsh-interaction", body)
    }
    DshQuestions(rpc_id~, questions~, answers~, ..) => {
      let body : Array[@html.Html] = [
        @html.div(
          class="codex-request-title",
          "DeepSeek Harness has a question",
        ),
      ]
      for question in questions {
        let answer = answers
          .get(question.id)
          .unwrap_or_else(() => DshQuestionAnswer::empty())
        let controls : Array[@html.Html] = [
          @html.div(class="codex-question-header", question.header),
          @html.div(class="codex-question-text", question.question),
        ]
        if !question.detail.is_empty() {
          controls.push(@html.div(class="codex-question-text", question.detail))
        }
        if !question.options.is_empty() {
          let options : Array[@html.Html] = []
          for option in question.options {
            options.push(
              @html.button(
                class=if answer.selected.contains(option.label) {
                  "codex-option selected"
                } else {
                  "codex-option"
                },
                disabled=loading,
                on_click=dispatch(
                  QuestionOption(
                    rpc_id~,
                    question_id=question.id,
                    label=option.label,
                  ),
                ),
                [
                  @html.span(class="codex-option-label", option.label),
                  @html.span(class="codex-option-desc", option.description),
                ],
              ),
            )
          }
          controls.push(@html.div(class="codex-options", options))
        }
        controls.push(
          @html.input(
            value=answer.custom,
            placeholder="Type another answer",
            attrs=@html.Attrs::build().disabled(loading),
            on_input=dispatch.map(value => {
              QuestionCustom(rpc_id~, question_id=question.id, value~)
            }),
          ),
        )
        body.push(@html.div(class="codex-question", controls))
      }
      body.push(
        @html.div(class="codex-request-actions", [
          @html.button(
            class="primary",
            disabled=loading || !self.questions_answered(),
            on_click=dispatch(SubmitQuestions(rpc_id)),
            "Submit answer",
          ),
        ]),
      )
      @html.div(class="codex-request dsh-interaction", body)
    }
  }
}

///|
priv struct DshContent(Json)

///|
fn DshContent::text(self : DshContent, kind : String) -> String {
  let parts : Array[String] = []
  match self.0 {
    Array(values) =>
      for value in values {
        let text = DshContent(value).text(kind)
        if !text.is_empty() {
          parts.push(text)
        }
      }
    Object(fields) => {
      if @jsonx.json_text(fields, "type") == Some(kind) &&
        @jsonx.json_text(fields, "text") is Some(text) &&
        !text.is_empty() {
        parts.push(text)
      }
      if fields.get("content") is Some(content) {
        let text = DshContent(content).text(kind)
        if !text.is_empty() {
          parts.push(text)
        }
      }
    }
    _ => ()
  }
  parts.join("\n")
}

///|
fn DshEventRecord::message(self : DshEventRecord) -> Json? {
  guard self.data is Object(fields) else { return None }
  if self.type_ == "user/message" {
    Some(self.data)
  } else {
    fields.get("message")
  }
}

///|
fn DshEventRecord::direct_user(self : DshEventRecord) -> Bool {
  guard self.type_ == "user/message" &&
    self.surface_append == Some(true) &&
    self.data is Object(fields) &&
    fields.get("source") is Some(Object(source)) else {
    return false
  }
  @jsonx.json_text(source, "kind") == Some("user")
}

///|
fn DshEventRecord::turn_error(self : DshEventRecord) -> String? {
  guard self.type_ == "turn/end" &&
    self.data is Object(fields) &&
    fields.get("reason") is Some(Object(reason)) &&
    @jsonx.json_text(reason, "kind") is Some(kind) &&
    kind != "completed" else {
    return None
  }
  if reason.get("error") is Some(Object(error)) &&
    @jsonx.json_text(error, "message") is Some(message) {
    Some(message)
  } else {
    Some("DeepSeek Harness turn ended: \{kind}")
  }
}

///|
pub fn State::transcript_items(
  self : State,
) -> Array[@transcript.TranscriptItem] {
  let items : Array[@transcript.TranscriptItem] = []
  if !self.notice.is_empty() {
    items.push({
      kind: @transcript.Assistant(is_danger=true),
      content: self.notice,
      ts: None,
      sequence: None,
    })
  }
  for event in self.events {
    if event.direct_user() && event.message() is Some(message) {
      let text = DshContent(message).text("text")
      if !text.is_empty() {
        items.push({
          kind: @transcript.User,
          content: text,
          ts: event.time,
          sequence: Some(event.seq),
        })
      }
    } else if event.type_ == "assistant/message" &&
      event.surface_append == Some(true) &&
      event.message() is Some(message) {
      let reasoning = DshContent(message).text("reasoning")
      if !reasoning.is_empty() {
        items.push({
          kind: @transcript.Reasoning,
          content: reasoning,
          ts: event.time,
          sequence: Some(event.seq),
        })
      }
      let text = DshContent(message).text("text")
      if !text.is_empty() {
        items.push({
          kind: @transcript.Assistant(is_danger=false),
          content: text,
          ts: event.time,
          sequence: Some(event.seq),
        })
      }
    } else if event.type_ == "tool/call" &&
      event.data is Object(fields) &&
      @jsonx.json_text(fields, "callId") is Some(call_id) {
      let name = @jsonx.json_text(fields, "name").unwrap_or("tool")
      items.push({
        kind: @transcript.Tool(
          call_id~,
          name~,
          arguments=Some(@jsonx.json_text(fields, "arguments").unwrap_or("{}")),
          has_result=false,
          is_error=false,
          brief=None,
        ),
        content: "",
        ts: event.time,
        sequence: Some(event.seq),
      })
    } else if event.type_ == "tool/result" &&
      event.surface_append == Some(true) &&
      event.message() is Some(Object(message)) &&
      message.get("content") is Some(Array(blocks)) &&
      blocks.get(0) is Some(Object(result)) &&
      @jsonx.json_text(result, "toolCallId") is Some(call_id) {
      let content = DshContent(Json::object(result)).text("text")
      let is_error = @jsonx.json_bool(result, "isError").unwrap_or(false)
      let mut matched : Int? = None
      let mut matches = 0
      for index, item in items {
        if item.kind
          is @transcript.Tool(
            call_id=existing,
            arguments=Some(_),
            has_result=false,
            ..
          ) &&
          existing == call_id {
          matched = Some(index)
          matches += 1
        }
      }
      if matches == 1 &&
        matched is Some(index) &&
        items[index].kind is @transcript.Tool(name~, arguments~, ..) {
        items[index] = {
          kind: @transcript.Tool(
            call_id~,
            name~,
            arguments~,
            has_result=true,
            is_error~,
            brief=None,
          ),
          content,
          ts: items[index].ts,
          sequence: items[index].sequence,
        }
      } else {
        items.push({
          kind: @transcript.Tool(
            call_id~,
            name="tool",
            arguments=None,
            has_result=true,
            is_error~,
            brief=None,
          ),
          content,
          ts: event.time,
          sequence: Some(event.seq),
        })
      }
    } else if event.turn_error() is Some(message) {
      items.push({
        kind: @transcript.Assistant(is_danger=true),
        content: message,
        ts: event.time,
        sequence: Some(event.seq),
      })
    }
  }
  items
}

///|
pub fn State::streaming_text(self : State) -> String {
  self.streaming
}

///|
test "dsh history maps user, assistant, and tool events to shared transcript rows" {
  let state = {
    ..State(),
    events: [
      {
        type_: "user/message",
        seq: 1,
        time: Some(10.0),
        data: {
          "content": [{ "type": "text", "text": "hello" }],
          "source": { "kind": "user" },
        },
        surface_append: Some(true),
      },
      {
        type_: "assistant/message",
        seq: 2,
        time: Some(20.0),
        data: { "message": { "content": [{ "type": "text", "text": "hi" }] } },
        surface_append: Some(true),
      },
      {
        type_: "tool/call",
        seq: 3,
        time: Some(30.0),
        data: { "callId": "c1", "name": "read", "arguments": "{}" },
        surface_append: None,
      },
      {
        type_: "tool/result",
        seq: 4,
        time: Some(40.0),
        data: {
          "message": {
            "content": [
              {
                "type": "tool-result",
                "toolCallId": "c1",
                "content": [{ "type": "text", "text": "done" }],
              },
            ],
          },
        },
        surface_append: Some(true),
      },
      {
        type_: "assistant/message",
        seq: 5,
        time: Some(50.0),
        data: {
          "message": { "content": [{ "type": "text", "text": "model copy" }] },
        },
        surface_append: Some(false),
      },
    ],
  }
  let items = state.transcript_items()
  assert_eq(items.length(), 3)
  assert_true(items[0].kind is @transcript.User)
  assert_true(items[1].kind is @transcript.Assistant(is_danger=false))
  assert_true(
    items[2].kind is @transcript.Tool(call_id="c1", has_result=true, ..),
  )
  assert_eq(items[2].content, "done")
}
