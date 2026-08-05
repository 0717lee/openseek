// Dedicated Codex app-server page. It renders Codex's semantic items and
// reverse requests directly; no raw JSON-RPC method editor is exposed.

///|
fn State::connection_label(self : State) -> String {
  match self.connection {
    CodexStarting => "Starting Codex…"
    CodexReady => "Connected"
    CodexUnavailable(message) => message
  }
}

///|
fn State::account_label(self : State) -> String {
  match self.account {
    CodexAccountUnknown => "Checking account…"
    CodexSignedOut(requires_auth) =>
      if requires_auth {
        "Sign in required"
      } else {
        "No account required"
      }
    CodexSignedIn(kind~, plan~) =>
      match plan {
        Some(plan) => "\{kind} · \{plan}"
        None => kind
      }
  }
}

///|
fn CodexItem::view(self : CodexItem) -> @html.Html {
  let text = self.text()
  match self.kind {
    "userMessage" =>
      @html.div(class="msg", [
        @html.div(class="avatar user", "›"),
        @html.div(class="msg-body", [
          @html.div(class="msg-role", "you"),
          @html.div(class="msg-content", text),
        ]),
      ])
    "agentMessage" | "plan" =>
      @html.div(class="msg", [
        @html.div(class="avatar agent", [icon(icon_sparkle)]),
        @html.div(class="msg-body", [
          @html.div(
            class="msg-role",
            if self.kind == "plan" {
              "Codex plan"
            } else {
              "Codex"
            },
          ),
          @html.div(
            class="msg-content markdown",
            @markdown.markdown_nodes(text),
          ),
        ]),
      ])
    _ =>
      @html.div(class="activity-row", [
        @html.details(class="activity codex-activity", [
          @html.summary(class="activity-summary", [
            @html.span(class="activity-title", self.kind),
          ]),
          @html.pre(class="codex-raw", text),
        ]),
      ])
  }
}

///|
fn CodexPendingRequest::view(
  self : CodexPendingRequest,
  dispatch : @cmd.Emit[Msg],
) -> @html.Html {
  let key = self.request_id.stringify()
  let body : Array[@html.Html] = [
    @html.div(
      class="codex-request-title",
      match self.method_ {
        "item/commandExecution/requestApproval" => "Command approval"
        "item/fileChange/requestApproval" => "File change approval"
        "item/permissions/requestApproval" => "Permission request"
        "item/tool/requestUserInput" => "Codex needs your input"
        "mcpServer/elicitation/request" => "Tool request"
        other => other
      },
    ),
  ]
  if self.params is Object(fields) &&
    @jsonx.json_text(fields, "reason") is Some(reason) &&
    !reason.is_empty() {
    body.push(@html.p(class="codex-request-reason", reason))
  }
  match self.method_ {
    "item/commandExecution/requestApproval"
    | "item/fileChange/requestApproval" => {
      body.push(@html.pre(class="codex-raw", self.params.stringify()))
      body.push(
        @html.div(class="codex-request-actions", [
          @html.button(
            class="primary",
            on_click=dispatch(Respond(request_key=key, decision="accept")),
            "Approve once",
          ),
          @html.button(
            on_click=dispatch(
              Respond(request_key=key, decision="acceptForSession"),
            ),
            "Approve for session",
          ),
          @html.button(
            class="danger-button",
            on_click=dispatch(Respond(request_key=key, decision="decline")),
            "Decline",
          ),
        ]),
      )
    }
    "item/permissions/requestApproval" => {
      body.push(@html.pre(class="codex-raw", self.params.stringify()))
      body.push(
        @html.div(class="codex-request-actions", [
          @html.button(
            class="primary",
            on_click=dispatch(Respond(request_key=key, decision="accept")),
            "Grant for turn",
          ),
          @html.button(
            on_click=dispatch(
              Respond(request_key=key, decision="acceptForSession"),
            ),
            "Grant for session",
          ),
          @html.button(
            class="danger-button",
            on_click=dispatch(Respond(request_key=key, decision="decline")),
            "Deny",
          ),
        ]),
      )
    }
    "item/tool/requestUserInput" => {
      for question in self.questions() {
        let answer = self.answers.get(question.id).unwrap_or("")
        let controls : Array[@html.Html] = [
          @html.div(class="codex-question-header", question.header),
          @html.div(class="codex-question-text", question.question),
        ]
        if !question.options.is_empty() {
          let options : Array[@html.Html] = []
          for option in question.options {
            options.push(
              @html.button(
                class=if answer == option.0 {
                  "codex-option selected"
                } else {
                  "codex-option"
                },
                on_click=dispatch(
                  RequestAnswer(
                    request_key=key,
                    question_id=question.id,
                    answer=option.0,
                  ),
                ),
                [
                  @html.span(class="codex-option-label", option.0),
                  @html.span(class="codex-option-desc", option.1),
                ],
              ),
            )
          }
          controls.push(@html.div(class="codex-options", options))
        }
        controls.push(
          @html.input(
            value=answer,
            placeholder="Type an answer",
            on_input=dispatch.map(value => {
              RequestAnswer(
                request_key=key,
                question_id=question.id,
                answer=value,
              )
            }),
          ),
        )
        body.push(@html.div(class="codex-question", controls))
      }
      body.push(
        @html.div(class="codex-request-actions", [
          @html.button(
            class="primary",
            on_click=dispatch(Respond(request_key=key, decision="accept")),
            "Submit answers",
          ),
        ]),
      )
    }
    "mcpServer/elicitation/request" => {
      body.push(@html.pre(class="codex-raw", self.params.stringify()))
      body.push(
        @html.textarea(
          value=self.answers.get("__content").unwrap_or("{}"),
          placeholder="JSON content required by the tool",
          on_input=dispatch.map(value => {
            RequestAnswer(
              request_key=key,
              question_id="__content",
              answer=value,
            )
          }),
          "",
        ),
      )
      body.push(
        @html.div(class="codex-request-actions", [
          @html.button(
            class="primary",
            on_click=dispatch(Respond(request_key=key, decision="accept")),
            "Submit JSON",
          ),
          @html.button(
            class="danger-button",
            on_click=dispatch(Respond(request_key=key, decision="decline")),
            "Decline",
          ),
        ]),
      )
    }
    _ =>
      body.push(
        @html.pre(
          class="codex-raw danger",
          "Unsupported app-server request:\n" + self.params.stringify(),
        ),
      )
  }
  @html.section(class="codex-request", body)
}

///|
/// Shell-owned navigation commands passed into the Codex sidebar. They are
/// view inputs, never model state, and keep this package independent from the
/// root frontend's Screen and Msg types.
pub(all) struct SidebarActions {
  selected : Bool
  open : @cmd.Cmd
  new_thread : @cmd.Cmd
  open_thread : (String) -> @cmd.Cmd
  archive_thread : (String) -> @cmd.Cmd
}

///|
/// Codex conversations live in OpenSeek's one global sidebar. The section
/// heading opens the Codex main pane, its plus starts a conversation in the
/// focused workspace, and each row selects or archives one Codex thread.
pub fn State::sidebar_rows(
  self : State,
  label : String,
  actions : SidebarActions,
) -> Array[@html.Html] {
  let rows : Array[@html.Html] = []
  rows.push(
    @html.div(
      class=if actions.selected {
        "sidebar-heading section-heading codex-sidebar-heading active"
      } else {
        "sidebar-heading section-heading codex-sidebar-heading"
      },
      on_click=actions.open,
      [
        @html.span(class="sidebar-label", label),
        @html.button(
          class="row-archive",
          type_="button",
          title="New Codex conversation",
          disabled=!(self.connection is CodexReady) || self.loading,
          attrs=@html.Attrs::build().on_click(event => {
            event.stop_propagation()
            actions.new_thread
          }),
          icon(icon_add),
        ),
      ],
    ),
  )
  for thread in self.threads {
    let selected = actions.selected &&
      self.active.map(item => item.id == thread.id).unwrap_or(false)
    let running = selected && self.is_running()
    let trailing : Array[@html.Html] = []
    if running {
      trailing.push(@html.span(class="run-dot accent pulse", ""))
    } else {
      trailing.push(
        @html.button(
          class="row-archive",
          type_="button",
          title="Archive Codex conversation",
          attrs=@html.Attrs::build().on_click(event => {
            event.stop_propagation()
            (actions.archive_thread)(thread.id)
          }),
          icon(icon_archive),
        ),
      )
    }
    rows.push(
      @html.div(
        class=if selected {
          "conversation-row codex-conversation-row active"
        } else {
          "conversation-row codex-conversation-row"
        },
        title=thread.cwd.unwrap_or(thread.title),
        on_click=(actions.open_thread)(thread.id),
        [
          @html.span(class="sidebar-label", thread.title),
          @html.span(class="row-trailing", trailing),
        ],
      ),
    )
  }
  if self.threads.is_empty() {
    let empty = match self.connection {
      CodexStarting => "Loading Codex conversations…"
      CodexUnavailable(_) => "Codex is unavailable"
      CodexReady =>
        if self.account is CodexSignedOut(_) {
          "Sign in to list Codex conversations"
        } else {
          "No Codex conversations yet"
        }
    }
    rows.push(
      @html.div(class="conversation-row placeholder codex-placeholder", [
        @html.span(class="sidebar-label", empty),
      ]),
    )
  }
  rows
}

///|
fn State::transcript_view(self : State) -> @html.Html {
  let items : Array[@html.Html] = []
  if !self.notice.is_empty() {
    items.push(@html.div(class="codex-notice", self.notice))
  }
  match self.active {
    None =>
      items.push(
        @html.div(class="empty", [
          @html.div(class="empty-badge", [icon(icon_sparkle)]),
          @html.div(class="empty-title", "Start a Codex thread"),
          @html.div(
            class="empty-sub",
            "Codex uses its own account, conversation history, sandbox, and approvals.",
          ),
        ]),
      )
    Some(thread) =>
      for turn in thread.turns {
        for item in turn.items {
          items.push(item.view())
        }
        if turn.error is Some(message) {
          items.push(
            @html.div(class="msg", [
              @html.div(class="avatar agent", "!"),
              @html.div(class="msg-body", [
                @html.div(class="msg-role", "Codex error"),
                @html.div(class="msg-content danger", message),
              ]),
            ]),
          )
        }
      }
  }
  @html.div(class="codex-transcript transcript", [
    @html.div(class="stream", items),
  ])
}

///|
fn State::composer_view(self : State, dispatch : @cmd.Emit[Msg]) -> @html.Html {
  let pending : Array[@html.Html] = []
  for request in self.pending_requests {
    pending.push(request.view(dispatch))
  }
  let model_options : Array[@html.Html] = []
  for model in self.models {
    model_options.push(
      @html.option(
        value=model.id,
        selected=model.id == self.selected_model,
        model.label,
      ),
    )
  }
  let controls : Array[@html.Html] = [
    @html.div(class="composer-status", [
      @html.select(
        class="composer-model codex-model-select",
        disabled=self.models.is_empty(),
        on_change=dispatch.map(value => ModelChanged(value)),
        model_options,
      ),
    ]),
  ]
  if self.is_running() {
    controls.push(
      @html.button(
        id="stop",
        class="icon-button stop-button",
        title="Stop Codex",
        on_click=dispatch(Stop),
        icon(icon_debug_stop),
      ),
    )
  } else {
    controls.push(
      @html.button(
        id="send",
        class="icon-button send-button",
        title="Send to Codex",
        disabled=self.loading ||
          self.active is None ||
          self.draft.trim().is_empty(),
        on_click=dispatch(Send),
        icon(icon_arrow_up),
      ),
    )
  }
  let empty_mentions : Array[@html.Html] = []
  @composer.View::{
    class_name: "composer codex-composer",
    // The request dock is permanent even when empty, so the shared inner card
    // never changes position when an approval or question arrives.
    before_inner: [@html.div(class="codex-pending", pending)],
    // Codex has no mention chips yet, but keeps the same stable first child.
    leading: @html.div(class="mention-tray", empty_mentions),
    textarea: @html.textarea(
      id="task",
      value=self.draft,
      placeholder=if self.is_running() {
        "Steer the running task — your message joins it at the next step."
      } else {
        "Ask Codex to inspect, edit, or explain this workspace."
      },
      disabled=self.active is None || !(self.connection is CodexReady),
      on_input=dispatch.map(value => DraftChanged(value)),
      attrs=@html.Attrs::build().on_keydown(fn(event) {
        if @composer.is_submit_shortcut(event) {
          event.prevent_default()
          dispatch(Send)
        } else {
          @cmd.none
        }
      }),
      "",
    ),
    controls,
    overlay: None,
  }.render()
}

///|
/// Shell-owned controls embedded in the Codex topbar. Passing commands keeps
/// terminal, file-editor, sidebar, and external-link policy in the root shell.
pub(all) struct PageActions {
  toggle_sidebar : @cmd.Cmd
  toggle_terminal : @cmd.Cmd
  toggle_files : @cmd.Cmd
  open_external : (String) -> @cmd.Cmd
  workspace_label : (@common.Uri) -> String
}

///|
/// The Codex conversation uses the same three-row main-column shape as an
/// OpenSeek conversation: one compact topbar, one transcript, one composer.
/// Conversation switching belongs to the global sidebar, not inside here.
pub fn State::page(
  self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  sidebar_open : Bool,
  terminal_open : Bool,
  file_panel_open : Bool,
  actions : PageActions,
) -> Array[@html.Html] {
  let account_actions : Array[@html.Html] = []
  match self.account {
    CodexSignedOut(true) =>
      account_actions.push(
        @html.button(
          class="primary",
          disabled=self.loading,
          on_click=dispatch(Login),
          "Sign in with ChatGPT",
        ),
      )
    CodexSignedIn(..) =>
      account_actions.push(
        @html.button(
          disabled=self.loading,
          on_click=dispatch(Logout),
          "Sign out",
        ),
      )
    _ => ()
  }
  if self.auth_url is Some(url) {
    account_actions.push(
      @html.button(on_click=(actions.open_external)(url), "Open sign-in page"),
    )
    account_actions.push(
      @html.button(
        disabled=self.loading,
        on_click=dispatch(CancelLogin),
        "Cancel sign-in",
      ),
    )
  }
  let topbar : Array[@html.Html] = []
  if !sidebar_open {
    topbar.push(
      @html.button(
        class="topbar-toggle",
        title="Show sidebar",
        on_click=actions.toggle_sidebar,
        icon(icon_layout_sidebar_left),
      ),
    )
  }
  let title = self.active.map(thread => thread.title).unwrap_or("Codex")
  let workspace = match self.active {
    Some(thread) => thread.workspace(channel)
    None => None
  }
  let tooltip = self.active
    .map(thread => thread.cwd.unwrap_or(thread.id))
    .unwrap_or("Codex app-server")
  topbar.push(
    @html.span(class="topbar-title codex-topbar-title", title=tooltip, [
      @html.span(class="codex-topbar-source", [
        icon(icon_sparkle),
        @html.text("Codex"),
      ]),
      if title == "Codex" {
        @html.nothing
      } else {
        @html.span(class="codex-topbar-thread", " · " + title)
      },
    ]),
  )
  if workspace is Some(workspace) {
    topbar.push(
      @html.span(class="topbar-workspace", title=workspace.path, [
        icon(icon_folder),
        @html.text((actions.workspace_label)(workspace)),
      ]),
    )
  }
  topbar.push(
    @html.div(class="codex-status-line", [
      if self.is_running() {
        @html.span(class="run-dot accent pulse", "")
      } else {
        @html.span(class="run-dot", "")
      },
      @html.span(class="codex-connection", self.connection_label()),
      @html.span(class="codex-account-label", " · " + self.account_label()),
    ]),
  )
  for action in account_actions {
    topbar.push(action)
  }
  // These are OpenSeek's existing host panels, re-rooted by `file_ctx` and
  // `terminal_ctx` to the selected app-server thread. They stay in this one
  // topbar instead of creating a nested Codex application frame.
  topbar.push(
    @html.button(
      class=if terminal_open { "panel-toggle active" } else { "panel-toggle" },
      disabled=self.active is None,
      title=if terminal_open { "Hide terminal" } else { "Show terminal" },
      on_click=actions.toggle_terminal,
      icon(icon_terminal),
    ),
  )
  // An open file panel carries its close toggle in the breadcrumb, matching
  // the OpenSeek conversation topbar. Without a cwd there is no safe root to
  // list, so the disabled button explains why no guessed directory is opened.
  if !file_panel_open {
    topbar.push(
      @html.button(
        class="panel-toggle",
        disabled=workspace is None,
        title=if workspace is Some(_) {
          "Show files"
        } else {
          "Files require a Codex working directory"
        },
        on_click=actions.toggle_files,
        icon(icon_layout_sidebar_right),
      ),
    )
  }
  [
    @html.div(class="topbar codex-topbar", topbar),
    self.transcript_view(),
    self.composer_view(dispatch),
  ]
}
