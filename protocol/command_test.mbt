///|
fn cmd(line : String) -> Result[@openseek_protocol.Command, String] {
  @openseek_protocol.Command::parse(
    @json.parse(line) catch {
      _ => return Err("not json")
    },
  )
}

///|
/// One sample per variant. `parse` is `to_json`'s inverse for all of them —
/// the property that stops the engine's reader and its two controllers from
/// spelling the same command differently, which is what they did.
fn all_commands() -> Array[@openseek_protocol.Command] {
  [
    Prompt(text="do it"),
    Steer(kind=Prompt, text="also fix docs"),
    Steer(kind=Command, text="<user_shell_command>"),
    Compact,
    Cancel,
    GoalSet(text="ship it", auto=false),
    GoalSet(text="grind it out", auto=true),
    GoalClear,
  ]
}

///|
test "every command round-trips through to_json and parse" {
  for command in all_commands() {
    assert_eq(@openseek_protocol.Command::parse(command.to_json()), Ok(command))
  }
}

///|
/// The desktop has always sent `steer` with no `kind`, and works because this
/// falls back to `Prompt`. The rule lived in the engine's decoder and nowhere
/// the desktop could see it; it is now the protocol's, and tested.
test "a steer without a kind is a prompt steer" {
  debug_inspect(
    cmd(
      (
        #|{"command":"steer","text":"go left"}
      ),
    ),
    content=(
      #|Ok(Steer(kind=Prompt, text="go left"))
    ),
  )
}

///|
/// `auto` is absent rather than `false`, so the line a controller writes for an
/// ordinary goal is byte for byte what the TUI has always written.
test "goal set omits auto unless it is armed" {
  inspect(
    (GoalSet(text="ship it", auto=false) : @openseek_protocol.Command)
    .to_json()
    .stringify(),
    content=(
      #|{"command":"goal","action":"set","text":"ship it"}
    ),
  )
  inspect(
    (GoalSet(text="grind it out", auto=true) : @openseek_protocol.Command)
    .to_json()
    .stringify(),
    content=(
      #|{"command":"goal","action":"set","text":"grind it out","auto":true}
    ),
  )
}

///|
/// These strings reach the controller as a `command_error` event, so they are
/// wire contract rather than diagnostics: a controller reads them to learn what
/// it got wrong. They are the engine's, verbatim.
test "a rejected command explains itself in the engine's own words" {
  debug_inspect(
    cmd(
      (
        #|{"command":"prompt","text":7}
      ),
    ),
    content=(
      #|Err("expected a string \"text\" field")
    ),
  )
  debug_inspect(
    cmd(
      (
        #|{"command":"steer","kind":"runtime","text":"x"}
      ),
    ),
    content=(
      #|Err("unknown steer kind: runtime")
    ),
  )
  debug_inspect(
    cmd(
      (
        #|{"command":"steer","kind":7,"text":"x"}
      ),
    ),
    content=(
      #|Err("expected a string \"kind\" field")
    ),
  )
  debug_inspect(
    cmd(
      (
        #|{"command":"goal","action":"set","text":"   "}
      ),
    ),
    content=(
      #|Err("goal text must not be blank")
    ),
  )
  debug_inspect(
    cmd(
      (
        #|{"command":"goal","action":"toggle"}
      ),
    ),
    content=(
      #|Err("expected {\"action\": \"set\", \"text\": ...} or {\"action\": \"clear\"}")
    ),
  )
  debug_inspect(
    cmd(
      (
        #|{"command":"inject","text":"x"}
      ),
    ),
    content=(
      #|Err("unknown command: inject")
    ),
  )
  debug_inspect(
    cmd(
      (
        #|["not an object"]
      ),
    ),
    content=(
      #|Err("expected a {\"command\": ...} object")
    ),
  )
}
