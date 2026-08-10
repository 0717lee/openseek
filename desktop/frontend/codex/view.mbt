// Dedicated Codex app-server page. It renders Codex's semantic items and
// reverse requests directly; no raw JSON-RPC method editor is exposed.

///|
fn State::connection_label(self : State) -> String {
  match self.connection {
    CodexStarting => "Starting Codex…"
    CodexReady => if self.is_running() { "Running" } else { "Connected" }
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
  start_thread : (String) -> @cmd.Cmd
  open_thread : (String) -> @cmd.Cmd
  archive_thread : (String) -> @cmd.Cmd
  project_label : (String) -> String
  workspace_row : (String, String, Bool, @cmd.Cmd?) -> @html.Html
  conversation_row : (String, String, Bool, Bool, @cmd.Cmd, @cmd.Cmd?) -> @html.Html
}

///|
/// The native Codex boundary resolves every linked worktree to its main local
/// checkout. That project root, never the exact thread cwd, is the grouping
/// identity used by the sidebar.
priv struct CodexProject(String) derive(Debug, Eq)

///|
/// Keep the short basename when it is unique. When several project roots share
/// it, add the parent directory so the sidebar does not show multiple
/// indistinguishable "openseek" folders; the full path remains the tooltip.
fn CodexProject::display_label(
  self : CodexProject,
  projects : Array[CodexProject],
  label : (String) -> String,
) -> String {
  let short = label(self.0)
  let duplicate = projects
    .iter()
    .any(project => project != self && label(project.0) == short)
  if !duplicate {
    return short
  }
  let mut end = self.0.length()
  while end > 0 && self.is_separator(end - 1) {
    end = end - 1
  }
  let mut start = end
  while start > 0 && !self.is_separator(start - 1) {
    start = start - 1
  }
  let mut parent_end = start
  while parent_end > 0 && self.is_separator(parent_end - 1) {
    parent_end = parent_end - 1
  }
  if parent_end == 0 {
    return self.0
  }
  let parent = self.0.view(end_offset=parent_end).to_owned()
  label(parent) + " / " + short
}

///|
fn CodexProject::is_separator(self : CodexProject, index : Int) -> Bool {
  let unit = self.0.code_unit_at(index)
  unit == 47 || unit == 92 // '/' or '\\'
}

///|
/// Codex contributes only its project and conversation rows to OpenSeek's
/// global sidebar. The root shell owns the shared collapsible section heading,
/// just as it does for Workspaces, Chats, and Archived chats. Git worktrees are
/// execution locations, not navigation groups: all conversations belonging to
/// the same main project appear directly below that one project row.
pub fn State::sidebar_rows(
  self : State,
  actions : SidebarActions,
) -> Array[@html.Html] {
  let rows : Array[@html.Html] = []
  let projects : Array[CodexProject] = []
  for thread in self.threads {
    if thread.project_key() is Some(project) && !projects.contains(project) {
      // Preserve app-server list order: the project containing the newest
      // visible thread appears first, and threads stay newest-first inside it.
      projects.push(project)
    }
  }
  for project in projects {
    let active = actions.selected &&
      self.active
      .map(thread => {
        thread.project_root
        .map(root => CodexProject(root.trim().to_owned()) == project)
        .unwrap_or(false)
      })
      .unwrap_or(false)
    rows.push(
      (actions.workspace_row)(
        project.0,
        project.display_label(projects, actions.project_label),
        active,
        if self.can_start_thread() {
          Some((actions.start_thread)(project.0))
        } else {
          None
        },
      ),
    )
    for thread in self.threads {
      if thread.project_key() == Some(project) {
        rows.push(thread.sidebar_row(self, actions))
      }
    }
  }
  let loose = self.threads.filter(thread => thread.project_key() is None)
  if !loose.is_empty() {
    rows.push((actions.workspace_row)("No project", "No project", false, None))
    for thread in loose {
      rows.push(thread.sidebar_row(self, actions))
    }
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
      @html.div(
        class="conversation-row placeholder codex-placeholder",
        on_click=actions.open,
        [@html.span(class="sidebar-label", empty)],
      ),
    )
  }
  rows
}

///|
/// A missing project root means the thread cwd was absent or its deleted
/// worktree could no longer be resolved. Keep those records together instead
/// of promoting an opaque worktree directory into a project row.
fn CodexThreadRow::project_key(self : CodexThreadRow) -> CodexProject? {
  match self.project_root {
    Some(root) => {
      let project = root.trim().to_owned()
      if project.is_empty() {
        None
      } else {
        Some(CodexProject(project))
      }
    }
    None => None
  }
}

///|
/// Supply one Codex task's state and commands to the shell-owned conversation
/// renderer. Codex does not construct sidebar DOM, so its disclosure slot,
/// nesting, trailing controls, and active state cannot diverge from OpenSeek.
fn CodexThreadRow::sidebar_row(
  self : CodexThreadRow,
  state : State,
  actions : SidebarActions,
) -> @html.Html {
  let selected = actions.selected &&
    state.active.map(item => item.id == self.id).unwrap_or(false)
  let running = selected && state.is_running()
  (actions.conversation_row)(
    self.cwd.unwrap_or(self.title),
    self.title,
    selected,
    running,
    (actions.open_thread)(self.id),
    if running {
      None
    } else {
      Some((actions.archive_thread)(self.id))
    },
  )
}

///|
fn CodexMention::chip(
  self : CodexMention,
  dispatch : @cmd.Emit[Msg],
  index : Int,
  open_file : (String, @common.Range?, String?) -> @cmd.Cmd,
) -> @html.Html {
  let (glyph, label, title, jump) = match self {
    CodexFileMention(name~, path~) =>
      ("@", name, "Open \{path}", Some(open_file(path, None, None)))
    CodexSkillMention(name~, ..) =>
      ("$", name, "Use Codex skill $\{name}", None)
    CodexSymbolMention(name~, path~, range~) =>
      (
        "#",
        name,
        "Open \{path}:\{range.start_line_number}",
        Some(open_file(path, Some(range), None)),
      )
    CodexEditorAnnotation(file~, range~, comment~, ..) =>
      (
        "✎",
        "\{file}:\{range.start_line_number}-\{range.end_line_number}",
        comment,
        Some(open_file(file, Some(range), Some(comment))),
      )
  }
  @composer.MentionChip::{
    glyph,
    label,
    title,
    jump,
    remove: Some((dispatch(RemoveMention(index)), icon(icon_close))),
  }.render()
}

///|
fn CodexCompletion::view(
  self : CodexCompletion,
  dispatch : @cmd.Emit[Msg],
) -> @html.Html {
  let rows : Array[@composer.CompletionRow] = []
  for _, item in self.menu {
    rows.push({ label: item.label, detail: item.detail })
  }
  @composer.CompletionView::{
    rows,
    selected: self.menu.selected(),
    hint: match self.kind {
      CodexCommands => "Commands"
      CodexSkills => "Skills"
      CodexSymbols => "Symbols"
      CodexFiles => "Files"
    },
    empty: if self.menu.loading() {
      "Searching…"
    } else {
      match self.kind {
        CodexCommands => "No commands"
        CodexSkills => "No skills"
        CodexSymbols => "No symbols"
        CodexFiles => "No files"
      }
    },
  }.render(index => dispatch(CompletionPick(index)))
}

///|
/// Match OpenSeek's CI tint: failed first, then still running, then passed.
/// A branch without a pull request remains neutral.
fn CodexGitStatus::tone(self : CodexGitStatus) -> String {
  guard self.pull_request is Some(pull_request) &&
    pull_request.checks is Some(checks) else {
    return "none"
  }
  if checks.failed > 0 {
    "failed"
  } else if checks.pending > 0 {
    "pending"
  } else {
    "passed"
  }
}

///|
fn CodexGitStatus::label(self : CodexGitStatus) -> String? {
  if self.pull_request is Some(pull_request) {
    let suffix = match pull_request.state {
      "open" => if pull_request.draft { " Draft" } else { "" }
      "merged" => " Merged"
      "closed" => " Closed"
      _ => ""
    }
    return Some("#\{pull_request.number}\{suffix}")
  }
  self.branch
}

///|
fn CodexGitStatus::summary(self : CodexGitStatus) -> String {
  if self.pull_request is Some(pull_request) {
    let parts : Array[String] = []
    if pull_request.checks is Some(checks) {
      if checks.failed > 0 {
        parts.push("\{checks.failed} failed")
      }
      if checks.pending > 0 {
        parts.push("\{checks.pending} running")
      }
      if checks.passed > 0 {
        parts.push("\{checks.passed} passed")
      }
    }
    if parts.is_empty() {
      pull_request.title
    } else {
      pull_request.title + " — CI " + parts.join(" · ")
    }
  } else {
    self.branch.map(branch => "On branch " + branch).unwrap_or("")
  }
}

///|
/// Codex and OpenSeek supply different Git state, but the composer draws the
/// same PR/branch pill and opens the same details surface on every click.
fn CodexGitStatus::chip(
  self : CodexGitStatus,
  dispatch : @cmd.Emit[Msg],
  open : Bool,
) -> @html.Html? {
  guard self.label() is Some(label) && !label.is_empty() else { return None }
  let opened = if open { " open" } else { "" }
  let children : Array[@html.Html] = [
    @composer.GitChip::{
      tone: self.tone() + opened,
      title: self.summary(),
      label,
      command: dispatch(ToggleGitDetails),
      content: icon(icon_pull_request),
    }.render(),
  ]
  if open {
    children.push(self.details())
  }
  Some(@html.div(class="composer-git", children))
}

///|
/// The Codex Git popover uses the same rows and external-link capture as the
/// OpenSeek composer. Even a branch without a PR explains that result instead
/// of accepting a click and doing nothing.
fn CodexGitStatus::details(self : CodexGitStatus) -> @html.Html {
  let branch = self.branch.unwrap_or("Unknown")
  let rows : Array[@html.Html] = [
    @html.div(class="composer-git-row", [
      @html.span(class="composer-git-key", "Branch"),
      @html.span(class="composer-git-value", branch),
    ]),
  ]
  if self.pull_request is Some(pull_request) {
    let label = self.label().unwrap_or("Pull request")
    rows.push(@html.div(class="composer-git-rule", @html.nothing))
    rows.push(
      @html.a(
        class="composer-git-link",
        href=pull_request.url,
        target=Blank,
        rel="noopener noreferrer",
        [
          @html.span(
            class="composer-git-glyph \{self.tone()}",
            icon(icon_pull_request),
          ),
          @html.span(class="composer-git-value", label),
          @html.span(class="composer-git-note", pull_request.title),
          @html.span(class="composer-git-out", icon(icon_link_external)),
        ],
      ),
    )
  } else if self.compare_url is Some(url) {
    rows.push(@html.div(class="composer-git-rule", @html.nothing))
    rows.push(
      @html.a(
        class="composer-git-link",
        href=url,
        target=Blank,
        rel="noopener noreferrer",
        [
          @html.span(class="composer-git-glyph none", icon(icon_pull_request)),
          @html.span(class="composer-git-value", "Create pull request"),
          @html.span(class="composer-git-out", icon(icon_link_external)),
        ],
      ),
    )
  } else {
    rows.push(
      @html.div(class="composer-git-row", [
        @html.span(class="composer-git-key", "PR"),
        @html.span(class="composer-git-value", "No matching pull request"),
      ]),
    )
  }
  @html.div(class="composer-git-menu", rows)
}

///|
fn State::composer_view(
  self : State,
  dispatch : @cmd.Emit[Msg],
  open_file : (String, @common.Range?, String?) -> @cmd.Cmd,
) -> @html.Html {
  let pending : Array[@html.Html] = []
  for request in self.pending_requests {
    pending.push(request.view(dispatch))
  }
  let model_options : Array[@composer.ModelOption] = []
  for model in self.models {
    model_options.push({ value: model.id, label: model.label })
  }
  let status : Array[@html.Html] = [
    @composer.ModelSelect::{
      options: model_options,
      selected: self.selected_model,
      disabled: self.models.is_empty(),
      change: dispatch.map(value => ModelChanged(value)),
      title: "Codex model",
    }.render(),
  ]
  if self.git_status is Some(git) &&
    git.chip(dispatch, self.git_details_open) is Some(chip) {
    status.push(chip)
  }
  let local_turn = self.active_turn_id()
  let running_elsewhere = self.is_running_elsewhere()
  let action = if local_turn is Some(_) {
    @composer.Action::{
      id: "stop",
      class_name: "icon-button stop-button",
      title: "Stop Codex",
      disabled: false,
      command: dispatch(Stop),
      content: icon(icon_debug_stop),
    }
  } else {
    @composer.Action::{
      id: "send",
      class_name: "icon-button send-button",
      title: "Send to Codex",
      disabled: self.loading ||
      self.active is None ||
      self.input_empty() ||
      running_elsewhere,
      command: dispatch(Send),
      content: icon(icon_arrow_up),
    }
  }
  let mention_chips : Array[@html.Html] = []
  for index, mention in self.mentions {
    mention_chips.push(mention.chip(dispatch, index, open_file))
  }
  @composer.View::{
    before_inner: [@html.div(class="codex-pending", pending)],
    mentions: mention_chips,
    value: self.draft,
    placeholder: if local_turn is Some(_) {
      "Steer the running task — your message joins it at the next step."
    } else if running_elsewhere {
      "This task is running in another Codex client."
    } else {
      "Ask Codex to inspect, edit, or explain this workspace."
    },
    disabled: self.active is None ||
    !(self.connection is CodexReady) ||
    running_elsewhere,
    input: dispatch.map(value => DraftChanged(value)),
    keyboard: @composer.KeyboardActions::{
      menu_open: self.completion is Some(_),
      navigate: delta => dispatch(CompletionMove(delta)),
      accept: dispatch(CompletionAccept),
      dismiss: dispatch(CompletionDismiss),
      submit: dispatch(Send),
      cancel: None,
    },
    status,
    action,
    overlay: self.completion.map(completion => completion.view(dispatch)),
  }.render()
}

///|
/// Shell-owned controls embedded in the Codex topbar. Passing commands keeps
/// terminal, file-editor, sidebar, and external-link policy in the root shell.
pub(all) struct PageActions {
  toggle_sidebar : @cmd.Cmd
  toggle_terminal : @cmd.Cmd
  toggle_files : @cmd.Cmd
  open_file : (String, @common.Range?, String?) -> @cmd.Cmd
  open_external : (String) -> @cmd.Cmd
  workspace_label : (@common.Uri) -> String
  // The root shell supplies the one transcript view shared with OpenSeek.
  // Codex owns the normalized items, but no parallel message/activity DOM.
  transcript : @html.Html
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
    // Source selection already lives in the global sidebar. The conversation
    // title occupies the same topbar slot as an OpenSeek title instead of
    // growing a second product header inside the shared shell.
    @html.span(class="topbar-title", title=tooltip, title),
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
    @html.div(
      class=if self.is_running() { "run-status accent" } else { "run-status" },
      [
        if self.is_running() {
          @html.span(class="run-dot accent pulse", "")
        } else {
          @html.span(class="run-dot", "")
        },
        @html.span(class="run-text", [
          @html.span(class="codex-connection", self.connection_label()),
          @html.span(class="codex-account-label", " · " + self.account_label()),
          if self.write_access is CodexActiveElsewhere ||
            self.is_running_elsewhere() {
            @html.span(
              class="codex-writer-status",
              title="Another Codex client currently owns this task's writer",
              " · Read-only: active elsewhere",
            )
          } else {
            @html.nothing
          },
        ]),
      ],
    ),
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
    actions.transcript,
    self.composer_view(dispatch, actions.open_file),
  ]
}
