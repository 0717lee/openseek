///|
test "submitted input marks prompt and shell command" {
  let input = @composer.Model::new("")
  let shell = @composer.Model::new("")
  shell.insert_user_text("!")
  assert_true(submitted_input("hello", input.mode()) == Prompt("hello"))
  assert_true(submitted_input("pwd ", shell.mode()) == Command("pwd"))
  assert_true(submitted_input("", shell.mode()) == Command(""))
}

///|
test "completion menu only opens for single-line slash input contexts" {
  let slash = @composer.Model::new("")
  slash.insert_user_text("/mo")
  guard completion_menu_for_composer(model_command_specs(), slash)
    is Some(command_menu) else {
    fail("expected command completion menu")
  }
  assert_eq(command_menu.key, "command:mo")
  assert_eq(command_menu.items.length(), 1)
  assert_eq(command_menu.items[0].label(), "/model")
  assert_true(command_menu.action is SlashCommandName)

  let plain = @composer.Model::new("")
  plain.insert_user_text("co")
  assert_true(
    completion_menu_for_composer(model_command_specs(), plain) is None,
  )

  // Past the command name, an argument menu exists only while a picker is open.
  let spaced = @composer.Model::new("")
  spaced.insert_user_text("/model deepseek-v4-f")
  assert_true(
    completion_menu_for_composer(model_command_specs(), spaced) is None,
  )
  guard completion_menu_for_composer(
      model_command_specs(),
      spaced,
      picker=model_picker(),
    )
    is Some(argument_menu) else {
    fail("expected model argument completion menu")
  }
  assert_eq(argument_menu.key, "argument:model:deepseek-v4-f")
  assert_eq(argument_menu.items.length(), 1)
  assert_eq(argument_menu.items[0].insert_text(), "deepseek-v4-flash")
  guard argument_menu.action is SlashCommandArgument(name=command_name) else {
    fail("expected model argument completion action")
  }
  assert_eq(command_name, "model")

  let multiline = @composer.Model::new("")
  multiline.insert_user_text("/model\n")
  assert_true(
    completion_menu_for_composer(
      model_command_specs(),
      multiline,
      picker=model_picker(),
    )
    is None,
  )
}

///|
fn model_command_specs() -> Array[@slash.SlashCommandSpec] {
  [@slash.SlashCommandSpec::new(name="model", description="show or change")]
}

///|
fn resume_command_specs() -> Array[@slash.SlashCommandSpec] {
  [@slash.SlashCommandSpec::new(name="resume", description="resume a session")]
}

///|
/// A handler-opened picker for /model, standing in for the items a command
/// handler supplies at open time (now the only source of argument candidates).
fn model_picker() -> PickerSource {
  {
    command: "model",
    items: [
      @completion.CompletionItem::new(label="deepseek-v4-flash"),
      @completion.CompletionItem::new(label="deepseek-v4-pro"),
    ],
  }
}

///|
fn composer_with(text : String) -> @composer.Model {
  let composer = @composer.Model::new("")
  composer.insert_user_text(text)
  composer
}

///|
test "enter dispatches the accepted command name with no arguments" {
  // Typing `/model` (exact) or `/mod` (partial) and pressing Enter dispatches
  // `model` with empty args; the handler decides to open a picker. The
  // completion layer no longer drafts anything itself.
  for typed in ["/model", "/mod"] {
    guard ui_enter_decision(
        model_command_specs(),
        composer_with(typed),
        CompletionState::new(),
        menu_visible=true,
      )
      is RunSlashCommand(name~, arguments~) else {
      fail("expected \{typed} to dispatch the model command")
    }
    assert_eq(name, "model")
    assert_eq(arguments, "")
  }
}

///|
test "enter accepts the highlighted argument from an open picker" {
  guard ui_enter_decision(
      model_command_specs(),
      composer_with("/model deepseek-v4-f"),
      CompletionState::new(),
      menu_visible=true,
      picker=model_picker(),
    )
    is RunSlashCommand(name~, arguments~) else {
    fail("expected the highlighted model completion to run")
  }
  assert_eq(name, "model")
  assert_eq(arguments, "deepseek-v4-flash")
}

///|
test "enter sanitizes a picked argument before dispatching it" {
  // A picker item can carry untrusted text — a `/resume` id is an unvalidated
  // session directory name. Pressing Enter on it must apply the same one-line,
  // control-stripping sanitization Tab does, so a crafted id with a newline or
  // escape cannot be stored in history and later recalled as multiline/control
  // text.
  let picker : PickerSource = {
    command: "resume",
    items: [@completion.CompletionItem::new(label="bad\nid\u{1b}[0m")],
  }
  guard ui_enter_decision(
      resume_command_specs(),
      composer_with("/resume "),
      CompletionState::new(),
      menu_visible=true,
      picker~,
    )
    is RunSlashCommand(name~, arguments~) else {
    fail("expected the highlighted session id to run")
  }
  assert_eq(name, "resume")
  assert_false(arguments.contains("\n"))
  assert_false(arguments.contains("\u{1b}"))
}

///|
test "enter runs a free-form argument with no completion match" {
  // `/resume <id>` must dispatch even when the id is absent from the static
  // completion list, so the explicit-resume handler still sees the id.
  guard ui_enter_decision(
      resume_command_specs(),
      composer_with("/resume unknown-session"),
      CompletionState::new(),
      menu_visible=true,
    )
    is RunSlashCommand(name~, arguments~) else {
    fail("expected /resume to run with the typed id")
  }
  assert_eq(name, "resume")
  assert_eq(arguments, "unknown-session")
}

///|
test "accepted slash completion is recorded so recall re-runs it" {
  // Accepting `deepseek-v4-pro` from `/model deepseek` dispatches the pro model,
  // so history must store the canonical command — not the typed prefix, which
  // would re-select the first match (flash) on recall.
  let recorded = slash_command_text(name="model", arguments="deepseek-v4-pro")
  assert_eq(recorded, "/model deepseek-v4-pro")
  assert_eq(slash_command_text(name="model", arguments=""), "/model")
  guard ui_enter_decision(
      model_command_specs(),
      composer_with(recorded),
      CompletionState::new(),
      menu_visible=true,
      picker=model_picker(),
    )
    is RunSlashCommand(name~, arguments~) else {
    fail("expected the recalled command to run")
  }
  assert_eq(name, "model")
  assert_eq(arguments, "deepseek-v4-pro")
  // Recalling the typed prefix instead would re-select the first match (flash).
  guard ui_enter_decision(
      model_command_specs(),
      composer_with("/model deepseek"),
      CompletionState::new(),
      menu_visible=true,
      picker=model_picker(),
    )
    is RunSlashCommand(arguments=first_match, ..) else {
    fail("expected the prefix to run the first match")
  }
  assert_eq(first_match, "deepseek-v4-flash")
}

///|
test "enter ignores the completion menu when it cannot be rendered" {
  // On a terminal too short to draw the menu (menu_visible=false), keys must not
  // be captured by an invisible picker: `/model ` runs as typed rather than
  // silently accepting the first model.
  guard ui_enter_decision(
      model_command_specs(),
      composer_with("/model "),
      CompletionState::new(),
      menu_visible=false,
      picker=model_picker(),
    )
    is RunSlashCommand(name~, arguments~) else {
    fail("expected /model to dispatch when the menu is hidden")
  }
  assert_eq(name, "model")
  assert_eq(arguments, "")
  // Visible, the same input would accept the highlighted model instead.
  guard ui_enter_decision(
      model_command_specs(),
      composer_with("/model "),
      CompletionState::new(),
      menu_visible=true,
      picker=model_picker(),
    )
    is RunSlashCommand(arguments=picked, ..) else {
    fail("expected the visible picker to accept a model")
  }
  assert_eq(picked, "deepseek-v4-flash")
}

///|
test "a malformed slash entry is not submitted as a prompt" {
  let specs = model_command_specs()
  // Menu dismissed (Esc): a lone `/` or `/ ` parses to no command, but must not
  // be submitted — that would leak the raw slash text into the agent.
  let dismissed = CompletionState::new()
  dismissed.dismissed = true
  for typed in ["/", "/ "] {
    assert_true(
      ui_enter_decision(
        specs,
        composer_with(typed),
        dismissed,
        menu_visible=true,
      )
      is NoCompletionMatch,
    )
  }
  // Same protection when the terminal is too short to draw the menu.
  assert_true(
    ui_enter_decision(
      specs,
      composer_with("/"),
      CompletionState::new(),
      menu_visible=false,
    )
    is NoCompletionMatch,
  )
  // Ordinary (non-slash) input is still submitted normally.
  assert_true(
    ui_enter_decision(
      specs,
      composer_with("hello"),
      dismissed,
      menu_visible=true,
    )
    is SubmitInput,
  )
}

///|
test "enter submits ordinary input outside a slash context" {
  assert_true(
    ui_enter_decision(
      model_command_specs(),
      composer_with("hello world"),
      CompletionState::new(),
      menu_visible=true,
    )
    is SubmitInput,
  )
}

///|
test "tab completes a command name and a picker argument" {
  // `/mod` completes to the highlighted command name.
  guard completion_menu_for_composer(
      model_command_specs(),
      composer_with("/mod"),
    )
    is Some(name_menu) else {
    fail("expected command menu")
  }
  assert_true(completion_acceptance_text(name_menu, 0) is Some("/model"))

  // A bare `/` completes to the first command, never queuing the slash.
  guard completion_menu_for_composer(model_command_specs(), composer_with("/"))
    is Some(all_menu) else {
    fail("expected command menu for bare slash")
  }
  assert_true(completion_acceptance_text(all_menu, 0) is Some("/model"))

  // With a picker open, Tab completes the highlighted argument.
  guard completion_menu_for_composer(
      model_command_specs(),
      composer_with("/model deepseek-v4-p"),
      picker=model_picker(),
    )
    is Some(arg_menu) else {
    fail("expected argument menu")
  }
  assert_true(
    completion_acceptance_text(arg_menu, 0) is Some("/model deepseek-v4-pro"),
  )

  // An unknown command has no item to accept.
  guard completion_menu_for_composer(
      model_command_specs(),
      composer_with("/nope"),
    )
    is Some(empty_menu) else {
    fail("expected an (empty) command menu")
  }
  assert_true(completion_acceptance_text(empty_menu, 0) is None)
}

///|
test "accepting a completion sanitizes untrusted item text" {
  // A /resume id is a session directory name taken verbatim; a crafted one with
  // a newline or ESC must not reach the composer as multiline text or terminal
  // control bytes (composer.replace bypasses input sanitization).
  let menu : CompletionMenu = {
    key: "argument:resume:",
    items: [
      @completion.CompletionItem::new(
        label="evil",
        insert_text="ev\nil\u{1b}[2J",
      ),
    ],
    action: SlashCommandArgument(name="resume"),
  }
  guard completion_acceptance_text(menu, 0) is Some(text) else {
    fail("expected acceptance text")
  }
  assert_false(text.contains("\n"))
  assert_false(text.contains("\u{1b}"))
  // A clean id passes through unchanged (sanitization is a no-op for safe text).
  let clean : CompletionMenu = {
    key: "argument:resume:",
    items: [@completion.CompletionItem::new(label="session-1")],
    action: SlashCommandArgument(name="resume"),
  }
  assert_true(completion_acceptance_text(clean, 0) is Some("/resume session-1"))
}

///|
test "a slash-command line is never queued as a prompt" {
  let specs = model_command_specs()
  // Both a partial command and a lone `/` are slash entries (not queued).
  assert_true(composer_is_slash_entry(specs, composer_with("/mod")))
  assert_true(composer_is_slash_entry(specs, composer_with("/")))
  // Ordinary text is not.
  assert_false(composer_is_slash_entry(specs, composer_with("hello")))
  // Multi-line input is never a slash entry.
  assert_false(composer_is_slash_entry(specs, composer_with("/model\nx")))
  // With the feature disabled, a slash line is ordinary input (queueable).
  let no_commands : @slash.SlashCommands = []
  assert_false(composer_is_slash_entry(no_commands, composer_with("/path")))
}

///|
test "slash command invocation parses any single-line slash entry" {
  let specs = model_command_specs()
  let with_args = @composer.Model::new("")
  with_args.insert_user_text("/model deepseek-v4-flash")
  guard slash_command_invocation_for_composer(specs, with_args)
    is Some(invocation) else {
    fail("expected model slash invocation")
  }
  assert_eq(invocation.name(), "model")
  assert_eq(invocation.arguments(), "deepseek-v4-flash")

  let trailing_space = @composer.Model::new("")
  trailing_space.insert_user_text("/model   ")
  guard slash_command_invocation_for_composer(specs, trailing_space)
    is Some(invocation) else {
    fail("expected model slash invocation")
  }
  assert_eq(invocation.arguments(), "")

  // Unknown commands still parse — dispatch is independent of registration.
  let unknown = @composer.Model::new("")
  unknown.insert_user_text("/unknown focus")
  guard slash_command_invocation_for_composer(specs, unknown)
    is Some(unknown_inv) else {
    fail("expected unknown command to parse syntactically")
  }
  assert_eq(unknown_inv.name(), "unknown")
  assert_eq(unknown_inv.arguments(), "focus")

  // With no commands configured the feature is off: a slash line is not an
  // invocation, so it stays ordinary input.
  let no_commands : @slash.SlashCommands = []
  let disabled = @composer.Model::new("")
  disabled.insert_user_text("/path/to/file")
  assert_true(
    slash_command_invocation_for_composer(no_commands, disabled) is None,
  )
}

///|
test "enter submits slash-prefixed input when no commands are configured" {
  let no_commands : @slash.SlashCommands = []
  assert_true(
    ui_enter_decision(
      no_commands,
      composer_with("/path"),
      CompletionState::new(),
      menu_visible=true,
    )
    is SubmitInput,
  )
}

///|
test "enter dispatches unknown slash commands to the handler" {
  // An unknown command must reach the handler (which reports the error) rather
  // than being sent to the agent as a prompt or swallowed as a notice.
  guard ui_enter_decision(
      model_command_specs(),
      composer_with("/doesnotexist test"),
      CompletionState::new(),
      menu_visible=true,
    )
    is RunSlashCommand(name~, arguments~) else {
    fail("expected unknown command with arguments to dispatch")
  }
  assert_eq(name, "doesnotexist")
  assert_eq(arguments, "test")
  guard ui_enter_decision(
      model_command_specs(),
      composer_with("/doesnotexist"),
      CompletionState::new(),
      menu_visible=true,
    )
    is RunSlashCommand(name=bare_name, arguments=bare_args) else {
    fail("expected bare unknown command to dispatch")
  }
  assert_eq(bare_name, "doesnotexist")
  assert_eq(bare_args, "")
}
