///|
/// The primary action at the right edge of a conversation composer. The caller
/// decides whether the action sends, steers, or stops; this package
/// owns the button DOM so those states retain identical geometry.
pub(all) struct ActionButton {
  id : String
  class_name : String
  title : String
  disabled : Bool
  command : @cmd.Cmd
  content : @html.Html
}

///|
pub fn ActionButton::render(self : ActionButton) -> @html.Html {
  @html.button(
    id=self.id,
    class=self.class_name,
    type_="button",
    title=self.title,
    disabled=self.disabled,
    on_click=self.command,
    self.content,
  )
}

///|
/// One option in the composer's model selector.
/// The owning source keeps the wire value; the composer owns its presentation.
pub(all) struct ModelOption {
  value : String
  label : String
}

///|
/// One provider's options in the composer's model selector. A single-group
/// menu renders flat; several groups retain their provider headings inside
/// the shared custom popup.
pub(all) struct ModelGroup {
  label : String
  options : Array[ModelOption]
}

///|
/// A compact custom selector for one caller-owned setting. The caller owns
/// open/close state; this value owns the shared popup, keyboard behavior, and
/// accessible relationship between its button and option list.
priv struct CompactSelect {
  id : String
  groups : Array[ModelGroup]
  selected : String
  disabled : Bool
  open : Bool
  toggle : @cmd.Cmd
  dismiss : @cmd.Cmd
  change : @cmd.Emit[String]
  title : String
  glyph : String
  aria_label : String
  kind_class : String
}

///|
fn CompactSelect::menu_id(self : CompactSelect) -> String {
  self.id + "-menu"
}

///|
fn CompactSelect::option_id(self : CompactSelect, index : Int) -> String {
  "\{self.id}-option-\{index}"
}

///|
/// Focus writes stay inside an event command. `after_render=true` is used
/// when opening or closing changes which option nodes exist.
fn CompactSelect::focus(
  self : CompactSelect,
  option : Int?,
  after_render : Bool,
) -> @cmd.Cmd {
  let id = match option {
    Some(index) => self.option_id(index)
    None => self.id
  }
  let focus = _ => {
    if @dom.document().get_element_by_id(id).to_option() is Some(element) {
      let _ : @js.Value = @js.Value::cast_from(element).apply_with_string(
        "focus",
        ([] : Array[@js.Value]),
      )
    }
  }
  if after_render {
    @cmd.custom_cmd(focus, kind=@cmd.after_render)
  } else {
    @cmd.custom_cmd(focus)
  }
}

///|
fn CompactSelect::trigger_attrs(
  self : CompactSelect,
  selected_index : Int,
  option_count : Int,
) -> @html.Attrs {
  @html.Attrs::build()
  .id(self.id)
  .aria_label(self.aria_label)
  .aria_controls(self.menu_id())
  .aria_expanded(self.open.to_string())
  .data_set("focus-owner", "")
  .on_keydown(event => {
    match event.key() {
      "Escape" if self.open => {
        event.prevent_default()
        self.dismiss
      }
      "ArrowDown" | "ArrowUp" if option_count > 0 => {
        event.prevent_default()
        let index = if event.key() == "ArrowUp" {
          if self.open {
            option_count - 1
          } else {
            selected_index
          }
        } else {
          selected_index
        }
        if self.open {
          self.focus(Some(index), false)
        } else {
          @cmd.batch([self.toggle, self.focus(Some(index), true)])
        }
      }
      _ => @cmd.none
    }
  })
}

///|
fn CompactSelect::option_attrs(
  self : CompactSelect,
  index : Int,
  option_count : Int,
  selected : Bool,
) -> @html.Attrs {
  @html.Attrs::build()
  .id(self.option_id(index))
  .role("option")
  .aria_selected(selected.to_string())
  .on_keydown(event => {
    let next = match event.key() {
      "ArrowDown" => Some(if index + 1 < option_count { index + 1 } else { 0 })
      "ArrowUp" => Some(if index > 0 { index - 1 } else { option_count - 1 })
      "Home" => Some(0)
      "End" => Some(option_count - 1)
      _ => None
    }
    if next is Some(next) {
      event.prevent_default()
      self.focus(Some(next), false)
    } else if event.key() == "Escape" {
      event.prevent_default()
      @cmd.batch([self.dismiss, self.focus(None, true)])
    } else {
      @cmd.none
    }
  })
}

///|
fn CompactSelect::render(self : CompactSelect) -> @html.Html {
  let mut selected_label = self.selected
  let mut selected_index = 0
  let mut option_count = 0
  for group in self.groups {
    for option in group.options {
      if option.value == self.selected {
        selected_label = option.label
        selected_index = option_count
      }
      option_count += 1
    }
  }
  let children : Array[@html.Html] = [
    @html.button(
      class=if self.disabled {
        "composer-model composer-picker-button disabled"
      } else if self.open {
        "composer-model composer-picker-button open"
      } else {
        "composer-model composer-picker-button"
      },
      type_="button",
      title=self.title,
      disabled=self.disabled,
      on_click=self.toggle,
      attrs=self.trigger_attrs(selected_index, option_count),
      [
        @html.span(class="composer-model-glyph", self.glyph),
        @html.span(class="composer-model-label", selected_label),
        @html.span(class="composer-model-chevron", ""),
      ],
    ),
  ]
  if self.open && !self.disabled {
    let menu : Array[@html.Html] = []
    let flat = self.groups.length() <= 1
    let mut index = 0
    for group in self.groups {
      let rows : Array[@html.Html] = []
      for option in group.options {
        let selected = option.value == self.selected
        rows.push(
          @html.button(
            class=if selected {
              "composer-picker-option selected"
            } else {
              "composer-picker-option"
            },
            type_="button",
            title=option.label,
            on_click=@cmd.batch([
              (self.change)(option.value),
              self.focus(None, true),
            ]),
            attrs=self.option_attrs(index, option_count, selected),
            [
              @html.span(class="composer-picker-option-label", option.label),
              @html.span(
                class="composer-picker-option-check",
                if selected {
                  "✓"
                } else {
                  ""
                },
              ),
            ],
          ),
        )
        index += 1
      }
      if flat {
        for row in rows {
          menu.push(row)
        }
      } else {
        menu.push(
          @html.div(
            class="composer-picker-group",
            attrs=@html.Attrs::build().role("group").aria_label(group.label),
            [
              @html.div(class="composer-picker-group-label", group.label),
              ..rows,
            ],
          ),
        )
      }
    }
    children.push(
      @html.div(
        class="composer-picker-menu",
        attrs=@html.Attrs::build()
          .id(self.menu_id())
          .role("listbox")
          .aria_label(self.aria_label),
        menu,
      ),
    )
  }
  @html.div(
    class="composer-picker composer-picker-\{self.kind_class}",
    children,
  )
}

///|
/// A compact model pill backed by the composer's custom popup.
pub(all) struct ModelSelect {
  id : String
  groups : Array[ModelGroup]
  selected : String
  disabled : Bool
  open : Bool
  toggle : @cmd.Cmd
  dismiss : @cmd.Cmd
  change : @cmd.Emit[String]
  title : String
}

///|
pub fn ModelSelect::render(self : ModelSelect) -> @html.Html {
  CompactSelect::{
    id: self.id,
    groups: self.groups,
    selected: self.selected,
    disabled: self.disabled,
    open: self.open,
    toggle: self.toggle,
    dismiss: self.dismiss,
    change: self.change,
    title: self.title,
    glyph: "✦",
    aria_label: "Model",
    kind_class: "model",
  }.render()
}

///|
/// The shared reasoning selector used by both OpenSeek and Codex composers.
/// Each caller owns its supported values; this type owns their identical
/// placement, accessibility label, and custom-menu presentation.
pub(all) struct ReasoningSelect {
  id : String
  options : Array[ModelOption]
  selected : String
  disabled : Bool
  open : Bool
  toggle : @cmd.Cmd
  dismiss : @cmd.Cmd
  change : @cmd.Emit[String]
  title : String
}

///|
pub fn ReasoningSelect::render(self : ReasoningSelect) -> @html.Html {
  CompactSelect::{
    id: self.id,
    groups: [{ label: "Reasoning effort", options: self.options }],
    selected: self.selected,
    disabled: self.disabled,
    open: self.open,
    toggle: self.toggle,
    dismiss: self.dismiss,
    change: self.change,
    title: self.title,
    glyph: "◐",
    aria_label: "Reasoning effort",
    kind_class: "reasoning",
  }.render()
}

///|
/// Placement of a conversation before and after its first workspace-bound
/// operation. The application keeps this value in its own model; the composer
/// owns the labels, tooltips, and control shape.
pub(all) enum WorktreeChoice {
  LocalCheckout
  FreshWorktree
  BoundWorktree(String)
} derive(Debug, Eq)

///|
pub fn WorktreeChoice::toggled(self : WorktreeChoice) -> WorktreeChoice {
  match self {
    LocalCheckout => FreshWorktree
    FreshWorktree => LocalCheckout
    BoundWorktree(_) => self
  }
}

///|
pub fn WorktreeChoice::wants_fresh(self : WorktreeChoice) -> Bool {
  self is FreshWorktree
}

///|
pub(all) struct WorktreeControl {
  choice : WorktreeChoice
  enabled : Bool
  command : @cmd.Cmd
  content : @html.Html
}

///|
/// Render a Local/Worktree chip. `enabled=false`
/// keeps the selected mode visible while its first operation is in flight,
/// but turns it into a statement so a click cannot disagree with that work.
pub fn WorktreeControl::render(self : WorktreeControl) -> @html.Html {
  let (class_name, label, title) = match self.choice {
    LocalCheckout =>
      (
        "composer-worktree", "Local", "Runs in the workspace itself — click to run in a fresh git worktree",
      )
    FreshWorktree =>
      (
        "composer-worktree on", "Worktree", "First prompt creates a git worktree and runs there — click for local",
      )
    BoundWorktree(name) =>
      ("composer-worktree on", name, "This chat runs in worktree \{name}")
  }
  let body = [self.content, @html.span(label)]
  if self.enabled && !(self.choice is BoundWorktree(_)) {
    @html.button(
      class=class_name,
      type_="button",
      title~,
      on_click=self.command,
      body,
    )
  } else {
    @html.span(class=class_name, title~, body)
  }
}

///|
/// A recovery banner for a conversation whose registered worktree
/// checkout is absent. Each backend supplies its own rebuild and archive
/// commands; the composer keeps the wording and control geometry identical.
pub(all) struct MissingWorktreeNotice {
  name : String
  conversation_noun : String
  rebuild : @cmd.Cmd
  archive : @cmd.Cmd
}

///|
pub fn MissingWorktreeNotice::render(
  self : MissingWorktreeNotice,
) -> @html.Html {
  @html.div(class="composer-notice", [
    @html.span(
      class="composer-notice-text",
      "Worktree \{self.name} has no checkout. Rebuild it to continue; commits on its branch are safe.",
    ),
    @html.button(
      class="composer-notice-btn",
      type_="button",
      title="Check the branch out again at .worktrees/\{self.name}",
      on_click=self.rebuild,
      "Rebuild it",
    ),
    @html.button(
      class="composer-notice-btn",
      type_="button",
      title="Archive this \{self.conversation_noun} without rebuilding its worktree",
      on_click=self.archive,
      "Archive \{self.conversation_noun}",
    ),
  ])
}

///|
/// A destructive confirmation for archiving a conversation with a
/// dirty worktree. The owner supplies commands, while this value owns the
/// complete path preview and the explicit data-loss warning.
pub(all) struct WorktreeArchiveDialog {
  refusal : @protocol.ArchiveNeedsForceReply
  conversation_noun : String
  cancel : @cmd.Cmd
  confirm : @cmd.Cmd
}

///|
pub fn WorktreeArchiveDialog::message(self : WorktreeArchiveDialog) -> String {
  let refusal = self.refusal
  let preview = if refusal.dirty_paths.is_empty() {
    ""
  } else {
    let remaining = refusal.dirty_path_count - refusal.dirty_paths.length()
    let suffix = if remaining > 0 { ", and \{remaining} more" } else { "" }
    " Changed paths: \{refusal.dirty_paths.join(", ")}\{suffix}."
  }
  "Worktree \{refusal.worktree} has uncommitted changes.\{preview} Archiving deletes this checkout and permanently discards its uncommitted, untracked, and ignored files. Committed work and the branch remain."
}

///|
pub fn WorktreeArchiveDialog::render(
  self : WorktreeArchiveDialog,
) -> @html.Html {
  @html.div(class="modal-backdrop", on_click=self.cancel, [
    @html.div(class="modal", [
      @html.div(class="modal-title", "Archive this \{self.conversation_noun}?"),
      @html.div(class="modal-body", self.message()),
      @html.div(class="modal-actions", [
        @html.button(on_click=self.cancel, "Keep working"),
        @html.button(
          class="primary",
          on_click=self.confirm,
          "Discard local changes and archive",
        ),
      ]),
    ]),
  ])
}

///|
/// One removable context chip. The caller supplies meaning and commands; this
/// package owns the exact DOM shape.
pub(all) struct MentionChip {
  glyph : String
  label : String
  title : String
  jump : @cmd.Cmd?
  remove : (@cmd.Cmd, @html.Html)?
}

///|
pub fn MentionChip::render(self : MentionChip) -> @html.Html {
  let glyph = @html.span(class="mention-glyph", self.glyph)
  let label = @html.span(class="mention-label", self.label)
  let body = match self.jump {
    Some(command) =>
      @html.button(
        class="mention-jump",
        type_="button",
        title=self.title,
        on_click=command,
        [glyph, label],
      )
    None => @html.span(class="mention-body", title=self.title, [glyph, label])
  }
  let children : Array[@html.Html] = [body]
  if self.remove is Some((command, content)) {
    children.push(
      @html.button(
        class="mention-remove",
        type_="button",
        title="Remove",
        on_click=command,
        content,
      ),
    )
  }
  @html.div(class="mention-chip", children)
}

///|
/// A reusable input composer. The caller owns its draft, completion results,
/// model control, and commands; this view-only
/// value owns the textarea, mention tray, toolbar, primary action, stable DOM
/// order, and all surrounding chrome.
pub(all) struct View {
  before_inner : Array[@html.Html]
  mentions : Array[@html.Html]
  value : String
  placeholder : String
  disabled : Bool
  input : @cmd.Emit[String]
  keyboard : KeyboardActions
  status : Array[@html.Html]
  action : ActionButton
  overlay : @html.Html?
}

///|
pub fn View::render(self : View) -> @html.Html {
  let inner : Array[@html.Html] = [
    // Keep the input wrapper and its two children permanently mounted. Rabbita
    // diffs array children by position, so chips appearing must not replace
    // the focus-holding textarea subtree.
    @html.div(class="composer-input", [
      @html.div(class="mention-tray", self.mentions),
      @html.textarea(
        id="task",
        value=self.value,
        placeholder=self.placeholder,
        disabled=self.disabled,
        on_input=self.input,
        // The surrounding card owns the visible focus frame; this marker lets
        // the global focus styling find the textarea without drawing a second
        // border around the control itself.
        attrs=self.keyboard.attrs().data_set("focus-target", ""),
        "",
      ),
    ]),
    @html.div(class="composer-toolbar", [
      @html.div(class="composer-controls", [
        @html.div(class="composer-status", self.status),
        self.action.render(),
      ]),
    ]),
  ]
  // Keep the stable input wrapper and toolbar first; transient overlays are
  // always appended.
  if self.overlay is Some(overlay) {
    inner.push(overlay)
  }
  // The context is one permanent sibling even when caller-specific panels
  // appear or disappear. This prevents their count from changing the inner
  // card's index and destroying textarea focus.
  @html.section(class="composer", [
    @html.div(class="composer-context", self.before_inner),
    @html.div(
      class="composer-inner",
      attrs=@html.Attrs::build().data_set("focus-owner", ""),
      inner,
    ),
  ])
}

///|
/// The open turn's heartbeat, docked directly above the textarea: what it is
/// doing, how long it has been at it, and what it has spent.
///
/// A model call is silent for as long as it thinks — no delta, no tool
/// result, no commit — so without this the window is indistinguishable from a
/// hung one. Deliberately lighter than a `composer-notice`: this is the only
/// row here that repaints every second, and a bordered card doing that reads
/// as an alarm rather than a heartbeat.
///
/// Always a slot, empty when idle and collapsed by `.composer-running:empty`,
/// the same shape as the plan panel's and for the same reason: the context
/// column is diffed by position, so a row that came and went would shift the
/// goal row below it on every run start and end.
fn running_row(run : RunHeartbeat?, clock_ms~ : Double) -> @html.Html {
  guard run is Some(run) else {
    return @html.div(class="composer-running", ([] : Array[@html.Html]))
  }
  @html.div(class="composer-running", [
    @html.span(class="composer-running-mark", ""),
    @html.span(class="composer-running-text", run.label(clock_ms~)),
  ])
}

///|
/// The heartbeat as one line. Each half of the detail is reported only when
/// genuinely known — an adopted run has no start this page witnessed, and a
/// turn before its first usage report has no count — so both absent leaves
/// the bare stage, which is still the one thing worth saying.
fn RunHeartbeat::label(self : RunHeartbeat, clock_ms~ : Double) -> String {
  let stage = match self.stage {
    Starting => "Starting…"
    Thinking => "Thinking…"
    AtStep(step) => "Working · step \{step}"
    Working => "Working…"
    Stopping => "Stopping…"
  }
  let detail : Array[String] = []
  if self.started_ms is Some(started) && clock_ms > started {
    detail.push(elapsed_label(clock_ms - started))
  }
  if self.tokens > 0 {
    detail.push("\{@labels.compact_count(self.tokens)} tokens")
  }
  if detail.is_empty() {
    stage
  } else {
    "\{stage} (\{detail.join(" · ")})"
  }
}

///|
/// A running span, coarsened the way a person reads a wait: seconds under a
/// minute, minutes and seconds under an hour, hours and minutes beyond. The
/// units never go finer than the span's own scale — nobody waiting twenty
/// minutes is reading the seconds column.
fn elapsed_label(span_ms : Double) -> String {
  let total_seconds = (span_ms / 1000.0).to_int()
  if total_seconds < 60 {
    return "\{total_seconds}s"
  }
  let minutes = total_seconds / 60
  if minutes < 60 {
    return "\{minutes}m \{total_seconds % 60}s"
  }
  "\{minutes / 60}h \{minutes % 60}m"
}

///|
/// One caller-owned completion row rendered inside the composer popup. The
/// caller keeps the row's action and payload; this view-only value contains
/// only its two visible strings.
pub(all) struct CompletionRow {
  label : String
  detail : String
}

///|
/// A reusable completion popup. `empty` describes a caller-specific
/// empty/loading state such as "Searching..." or "No files".
pub(all) struct CompletionView {
  rows : Array[CompletionRow]
  selected : Int
  hint : String
  empty : String
}

///|
/// Render one completion popup. A row uses `mousedown` so choosing it keeps
/// focus in the textarea while the owning source updates its draft.
pub fn CompletionView::render(
  self : CompletionView,
  pick : (Int) -> @cmd.Cmd,
) -> @html.Html {
  let rows : Array[@html.Html] = []
  for index, item in self.rows {
    rows.push(
      @html.div(
        class=if index == self.selected {
          "completion-item selected"
        } else {
          "completion-item"
        },
        attrs=@html.Attrs::build().on_mousedown(event => {
          event.prevent_default()
          pick(index)
        }),
        [
          @html.span(class="completion-label", item.label),
          @html.span(class="completion-detail", item.detail),
        ],
      ),
    )
  }
  if rows.is_empty() {
    rows.push(@html.div(class="completion-empty", self.empty))
  }
  @html.div(class="completion-menu", [
    @html.div(class="completion-hint", self.hint),
    @html.div(class="completion-list", rows),
  ])
}

///|
/// Caller-owned commands for a composer's keyboard behavior.
/// When the menu is open it captures navigation and acceptance; otherwise
/// Enter follows the ordinary submit rule below.
pub(all) struct KeyboardActions {
  menu_open : Bool
  navigate : (Int) -> @cmd.Cmd
  accept : @cmd.Cmd
  dismiss : @cmd.Cmd
  submit : @cmd.Cmd
  cancel : @cmd.Cmd?
}

///|
fn KeyboardActions::attrs(self : KeyboardActions) -> @html.Attrs {
  @html.Attrs::build().on_keydown(event => {
    if self.menu_open {
      match event.key() {
        "ArrowDown" => {
          event.prevent_default()
          (self.navigate)(1)
        }
        "ArrowUp" => {
          event.prevent_default()
          (self.navigate)(-1)
        }
        "Tab" => {
          event.prevent_default()
          self.accept
        }
        "Enter" =>
          if !event.shift_key() && !event.is_composing() {
            event.prevent_default()
            self.accept
          } else {
            @cmd.none
          }
        "Escape" => {
          event.prevent_default()
          self.dismiss
        }
        _ => @cmd.none
      }
    } else if event.key() == "Escape" && self.cancel is Some(cancel) {
      event.prevent_default()
      cancel
    } else if is_submit_shortcut(event) {
      event.prevent_default()
      self.submit
    } else {
      @cmd.none
    }
  })
}

///|
/// Enter submits a composer unless Shift requests a newline or an IME is
/// still composing text. Keeping this rule with the composer makes every
/// caller use the same keyboard contract.
fn is_submit_shortcut(event : @dom.KeyboardEvent) -> Bool {
  event.key() == "Enter" && !event.shift_key() && !event.is_composing()
}

///|
pub extend WorktreeChoice with Debug::{to_repr}

///|
pub extend WorktreeChoice with Eq::{equal, not_equal}
