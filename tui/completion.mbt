///|
priv struct CompletionMenu {
  key : String
  items : Array[@completion.CompletionItem]
  action : CompletionAction
}

///|
/// The items backing an open argument picker and the command they belong to.
/// Supplied by the command handler through `Ui::open_picker`, so candidates are
/// fetched fresh each time (e.g. the current session list for `/resume`) rather
/// than baked into the command spec at startup.
priv struct PickerSource {
  command : String
  items : Array[@completion.CompletionItem]
}

///|
/// Mutable state backing the input-completion menu: `key` identifies the
/// current menu context (so the selection resets when it changes), `selected`
/// is the highlighted item index, and `dismissed` records an Esc dismissal.
priv struct CompletionState {
  mut key : String
  mut selected : Int
  mut dismissed : Bool
}

///|
fn CompletionState::new() -> CompletionState {
  { key: "", selected: 0, dismissed: false }
}

///|
/// Forget the current menu context, clearing the selection and any dismissal.
fn CompletionState::reset(self : CompletionState) -> Unit {
  self.key = ""
  self.selected = 0
  self.dismissed = false
}

///|
fn completion_menu_for_composer(
  commands : @slash.SlashCommands,
  composer : @composer.Model,
  picker? : PickerSource,
) -> CompletionMenu? {
  if !composer.mode().is_input() {
    return None
  }
  let text = composer.text()
  if text.contains("\n") {
    return None
  }
  guard text.strip_prefix("/") is Some(rest) else { return None }
  let rest = rest.to_owned()
  // No separator yet: complete the command name from the configured set.
  if !@slash.has_arguments(rest) {
    if commands.is_empty() {
      return None
    }
    return Some({
      key: "command:\{rest.to_lower()}",
      items: @completion.completion_item_matches(
        commands.completion_items(),
        rest,
      ),
      action: SlashCommandName,
    })
  }
  // Past the command name: an argument menu only exists while a handler-opened
  // picker is active for this command. Without one, the typed text is a
  // free-form argument the handler will dispatch — there is nothing to complete.
  guard @slash.SlashCommandInvocation::parse(text) is Some(invocation) else {
    return None
  }
  guard picker is Some(picker) &&
    picker.command.equal_ignore_ascii_case(invocation.name()) else {
    return None
  }
  let arguments = invocation.arguments()
  Some({
    key: "argument:\{picker.command.to_lower()}:\{arguments.to_lower()}",
    items: @completion.completion_item_matches(picker.items, arguments),
    action: SlashCommandArgument(name=invocation.name()),
  })
}

///|
/// The slash command syntactically present in the composer, if any.
///
/// Returns None when no slash commands are configured, so a consumer that has
/// not opted into the feature keeps submitting `/`-prefixed lines as ordinary
/// input. When the feature is enabled, parsing is independent of whether the
/// specific name is registered — an unknown command still dispatches so the
/// handler reports it rather than the agent receiving it as a prompt or it
/// being swallowed as a no-completion notice.
fn slash_command_invocation_for_composer(
  commands : @slash.SlashCommands,
  composer : @composer.Model,
) -> @slash.SlashCommandInvocation? {
  if commands.is_empty() {
    return None
  }
  if !composer.mode().is_input() {
    return None
  }
  let text = composer.text()
  if text.contains("\n") {
    return None
  }
  @slash.SlashCommandInvocation::parse(text)
}

///|
fn Ui::completion_menu(self : Self) -> CompletionMenu? {
  completion_menu_for_composer(
    self.config.slash_commands,
    self.composer,
    picker?=self.picker,
  )
}

///|
fn Ui::sync_completion_menu(self : Self) -> Unit {
  match self.completion_menu() {
    Some(menu) => {
      if menu.key != self.completion.key {
        self.completion.key = menu.key
        self.completion.selected = 0
      }
      if menu.items.length() == 0 {
        self.completion.selected = 0
      } else if self.completion.selected >= menu.items.length() {
        self.completion.selected = menu.items.length() - 1
      }
    }
    None => self.completion.reset()
  }
}

///|
/// Whether the terminal is tall enough to draw the completion menu. A menu that
/// cannot be rendered must not capture keys, so this gates `completion_menu_open`
/// (and the Enter decision) on the same row budget the renderer uses.
fn Ui::completion_menu_visible(self : Self) -> Bool {
  guard self.viewport is Some(viewport) else { return true }
  @render.completion_menu_fits(max_rows=viewport.rows())
}

///|
fn Ui::completion_menu_open(self : Self) -> Bool {
  !self.completion.dismissed &&
  self.completion_menu_visible() &&
  self.completion_menu() is Some(_)
}

///|
async fn Ui::redraw_after_completion_selection(self : Self) -> Unit {
  self.notice = None
  self.redraw()
}

///|
async fn Ui::move_completion_selection(self : Self, delta : Int) -> Unit {
  let len = match self.completion_menu() {
    Some(menu) => menu.items.length()
    None => 0
  }
  if len > 0 {
    if delta < 0 {
      self.completion.selected = if self.completion.selected <= 0 {
        len - 1
      } else {
        self.completion.selected - 1
      }
    } else {
      self.completion.selected = if self.completion.selected + 1 >= len {
        0
      } else {
        self.completion.selected + 1
      }
    }
  }
  self.redraw_after_completion_selection()
}

///|
/// The canonical `/name arguments` text for a dispatched slash command, used
/// for history so recall repeats what actually ran rather than the half-typed
/// prefix in the composer.
fn slash_command_text(name~ : String, arguments~ : String) -> String {
  if arguments.is_empty() {
    "/\{name}"
  } else {
    "/\{name} \{arguments}"
  }
}

///|
async fn Ui::submit_slash_command(
  self : Self,
  name~ : String,
  arguments~ : String,
) -> Event? {
  // Record what ran, not `composer.text()`: accepting a completion can dispatch
  // arguments that differ from the typed prefix, and recalling the prefix would
  // re-select the first match and run a different command.
  let text = slash_command_text(name~, arguments~)
  self.history.push(@history.Entry::new(text, self.composer.mode()))
  self.composer.reset()
  self.history.reset_navigation()
  self.notice = None
  self.completion.reset()
  self.picker = None
  self.redraw()
  Some(SlashCommand(name~, arguments~))
}

///|
/// The composer text that accepting the highlighted menu item produces: a
/// completed command name (`/mod` → `/model`) or, from an open picker, the
/// highlighted argument (`/resume ` → `/resume session-3`). None when the menu is
/// empty (e.g. an unknown command), so there is nothing to accept.
fn completion_acceptance_text(menu : CompletionMenu, selected : Int) -> String? {
  guard menu.items.get(selected) is Some(item) else { return None }
  let text = match menu.action {
    SlashCommandName => "/\{item.insert_text()}"
    SlashCommandArgument(name~) => "/\{name} \{item.insert_text()}"
  }
  // A completion item can carry untrusted external text — a `/resume` id is a
  // session directory name read verbatim, and ids are not control-character
  // validated. The accepted text reaches the composer via `replace`, which skips
  // the input-sanitization path, so sanitize here: collapse to one line and drop
  // control bytes, so a crafted id cannot write terminal escapes on redraw or
  // turn the slash command into multiline prompt text.
  Some(@text.sanitize_oneline(text).text())
}

///|
/// Accept the highlighted completion into the composer without submitting; Tab
/// completes the text where Enter would submit it.
async fn Ui::accept_completion(self : Self) -> Event? {
  guard self.completion_menu() is Some(menu) else { return None }
  guard completion_acceptance_text(menu, self.completion.selected) is Some(text) else {
    return None
  }
  self.composer.replace(text, mode=self.composer.mode())
  self.redraw_after_text_change()
  None
}

///|
/// Whether the composer holds a slash-command entry: the feature is enabled and
/// the single-line input begins with `/`. Such a line is completed or dispatched
/// on Enter, never queued as a prompt — not even a lone `/`, which is not yet a
/// valid invocation but must not be queued as literal text.
fn composer_is_slash_entry(
  commands : @slash.SlashCommands,
  composer : @composer.Model,
) -> Bool {
  if commands.is_empty() {
    return false
  }
  if !composer.mode().is_input() {
    return false
  }
  let text = composer.text()
  if text.contains("\n") {
    return false
  }
  text.has_prefix("/")
}

///|
/// Open an argument picker for slash command `name`, drawing from `items`.
///
/// The command handler calls this (e.g. `/model` lists the models, `/resume`
/// lists the current sessions) rather than the completion layer inferring a
/// picker from static spec data. It points the menu at `items` and rewrites the
/// composer to `/name ` so the argument-completion menu renders them; typing
/// filters the list and Enter accepts the highlighted item. Runs on the command
/// queue so the buffer edit and redraw serialize with other UI updates.
///
/// A picker is only opened by submitting a bare slash command (Enter on
/// `/model` or `/resume`); typing the `/name ` separator no longer requests one.
/// The picker opens after that submission — and, for `/resume`, after async work
/// to list the store. In the meantime the tty reader is still live, so only
/// apply it over the expected entry state: an empty composer (the bare command
/// just cleared it on submit), which is filled with `/name `; or a composer the
/// user has since typed as this command's entry (`/name ...`), which is left
/// as-is so a typed filter is preserved. Any other text means the user moved on
/// — do not clobber it.
pub async fn Ui::open_picker(
  self : Self,
  name~ : String,
  items~ : Array[@completion.CompletionItem],
) -> Unit {
  self.commands.wait(() => {
    let text = self.composer.text()
    let entering_this_command = @slash.SlashCommandInvocation::parse(text)
      is Some(inv) &&
      inv.name().equal_ignore_ascii_case(name)
    if text.is_empty() || entering_this_command {
      // Fill an empty composer; an already-typed `/name ...` keeps its text (and
      // any in-progress argument the menu filters on).
      if text.is_empty() {
        self.composer.replace("/\{name} ", mode=self.composer.mode())
      }
      self.picker = Some({ command: name, items: items.copy() })
      // A picker opened over a recalled entry must not keep History in recall
      // mode, and the menu must reflect the current buffer.
      self.history.reset_navigation()
      self.completion.dismissed = false
      self.sync_completion_menu()
      self.notice = None
      self.redraw()
    }
  })
}

///|
/// What pressing Enter in the composer should do, decided purely from the
/// command set, the composer text, and the menu state.
priv enum EnterDecision {
  /// Dispatch a slash command with these arguments.
  RunSlashCommand(name~ : String, arguments~ : String)
  /// Submit the composer text as ordinary input (prompt or shell command).
  SubmitInput
  /// The menu is open but nothing matches; show a notice and do nothing.
  NoCompletionMatch
}

///|
/// Decide what Enter does. Accepting a highlighted command name dispatches it
/// with no arguments — the handler decides whether to run it or open an argument
/// picker (see `Ui::open_picker`). With a picker open, the highlighted argument
/// is accepted; an argument with no matching item runs as typed so free-form
/// values still dispatch. An unknown command still dispatches so the handler can
/// reject it, and anything else is submitted as ordinary input.
///
/// `menu_visible` is false when the terminal is too short to draw the menu, in
/// which case it must not influence the decision even though it is logically
/// open.
fn ui_enter_decision(
  commands : @slash.SlashCommands,
  composer : @composer.Model,
  completion : CompletionState,
  menu_visible~ : Bool,
  picker? : PickerSource,
) -> EnterDecision {
  let menu = if completion.dismissed || !menu_visible {
    None
  } else {
    completion_menu_for_composer(commands, composer, picker?)
  }
  let invocation = slash_command_invocation_for_composer(commands, composer)
  guard menu is Some(menu) else {
    return match invocation {
      Some(inv) => RunSlashCommand(name=inv.name(), arguments=inv.arguments())
      // No menu and nothing to dispatch. A slash entry that does not parse into
      // a command (a lone `/`, `/ `, after the menu was dismissed or is too
      // short to draw) must not be submitted as a prompt — that would leak
      // malformed slash input into the agent conversation. Leave it as a
      // no-match instead; only genuine non-slash input is submitted.
      None =>
        if composer_is_slash_entry(commands, composer) {
          NoCompletionMatch
        } else {
          SubmitInput
        }
    }
  }
  match menu.action {
    // Command-name menu: accept the highlighted command and dispatch it with no
    // arguments. The handler runs it or opens an argument picker; either way the
    // completion layer does not decide.
    SlashCommandName =>
      match menu.items.get(completion.selected) {
        Some(item) => RunSlashCommand(name=item.insert_text(), arguments="")
        // Nothing matches the typed name: dispatch it (an unknown command) so
        // the handler can reject it instead of swallowing it as a notice.
        None =>
          match invocation {
            Some(inv) =>
              RunSlashCommand(name=inv.name(), arguments=inv.arguments())
            None => NoCompletionMatch
          }
      }
    // Argument menu: accept the highlighted argument; with no match, run the
    // command as typed so free-form arguments still dispatch.
    SlashCommandArgument(name~) =>
      match menu.items.get(completion.selected) {
        // Sanitize the picked argument exactly as the Tab path does
        // (`completion_acceptance_text`): a picker item can carry untrusted
        // external text (a `/resume` id is an unvalidated session directory
        // name), and the dispatched value is stored verbatim in history, so a
        // crafted id with newlines or escapes must not survive into a later
        // recall.
        Some(item) =>
          RunSlashCommand(
            name~,
            arguments=@text.sanitize_oneline(item.insert_text()).text(),
          )
        None =>
          match invocation {
            Some(inv) =>
              RunSlashCommand(name=inv.name(), arguments=inv.arguments())
            None => NoCompletionMatch
          }
      }
  }
}
