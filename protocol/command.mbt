///|
/// How a mid-turn steer reaches the model.
///
/// The wire spells these `"prompt"` and `"command"`. `Notice` is deliberately
/// absent: the engine synthesizes notices for itself (a background job
/// finishing), and reports them back as `steer_applied` with `kind: "notice"`,
/// but no controller may send one — `decode` has always rejected an unknown
/// kind, and a notice is not a thing a client has to say.
pub(all) enum SteerKind {
  Prompt
  Command
} derive(Eq, Debug)

///|
/// One command a controller writes to `openseek serve`'s stdin.
///
/// The other half of the serve protocol: `Event` is what the engine reports,
/// this is what it is told. Both directions used to be anonymous JSON at each
/// end — the events for ~60 call sites and three decoders, these for one
/// decoder and two encoders that had already drifted apart:
///
/// - the TUI sent `steer` with a `kind`; the desktop sent it without one, and
///   worked only because `parse` falls back to `Prompt`. Neither end wrote that
///   rule down.
/// - the desktop had no `goal` at all, so the same protocol meant different
///   things to its two clients, and nothing said whether that was a decision.
///
/// One type, one encoder, one decoder — the same shape the event direction now
/// has.
pub(all) enum Command {
  Prompt(text~ : String)
  Steer(kind~ : SteerKind, text~ : String)
  Compact
  Cancel
  /// `auto` arms autonomous continuation toward the goal. No in-repo client
  /// sends it — the TUI's `/goal` always sets a manual goal — but `serve` is a
  /// protocol, not a private channel, and an external controller drives this.
  GoalSet(text~ : String, auto~ : Bool)
  GoalClear
} derive(Eq, Debug)

///|
/// The command as the line a controller writes.
pub fn Command::to_json(self : Command) -> Json {
  match self {
    Prompt(text~) => { "command": "prompt", "text": text }
    Steer(kind~, text~) =>
      {
        "command": "steer",
        "kind": match kind {
          Prompt => "prompt"
          Command => "command"
        },
        "text": text,
      }
    Compact => { "command": "compact" }
    Cancel => { "command": "cancel" }
    // `auto` is written only when set: an engine older than the flag ignores an
    // unknown key, but the field's absence is also what `false` has always
    // looked like on this wire, so omitting it keeps the common line unchanged.
    GoalSet(text~, auto~) =>
      if auto {
        { "command": "goal", "action": "set", "text": text, "auto": true }
      } else {
        { "command": "goal", "action": "set", "text": text }
      }
    GoalClear => { "command": "goal", "action": "clear" }
  }
}

///|
/// The command as a JSONL line, newline included.
pub fn Command::to_jsonl(self : Command) -> String {
  self.to_json().stringify() + "\n"
}

///|
/// Read one stdin line back into a `Command`.
///
/// `Err` carries the text the engine reports to its controller as a
/// `command_error` event, so these strings are themselves wire contract, not
/// diagnostics — they are what a controller reads to learn what it got wrong.
///
/// Unlike `parse` for events, this returns a `Result`: an unreadable event is
/// a line to ignore, but an unreadable command is a request that will never be
/// answered, and silence is the one reply a controller cannot act on.
///
/// `steer` without a `kind` is `Prompt`. That is not leniency for its own sake:
/// the desktop has always sent exactly that, and it is what every controller
/// meant before the field existed.
pub fn Command::parse(line : Json) -> Result[Command, String] {
  match line {
    { "command": "prompt", "text": String(text), .. } => Ok(Prompt(text~))
    { "command": "steer", .. } => parse_steer(line)
    { "command": "prompt", .. } => Err("expected a string \"text\" field")
    { "command": "compact", .. } => Ok(Compact)
    { "command": "cancel", .. } => Ok(Cancel)
    { "command": "goal", "action": "set", "text": String(text), .. } =>
      if text.trim().is_empty() {
        Err("goal text must not be blank")
      } else {
        Ok(GoalSet(text~, auto=line is { "auto": True, .. }))
      }
    { "command": "goal", "action": "clear", .. } => Ok(GoalClear)
    { "command": "goal", .. } =>
      Err(
        "expected {\"action\": \"set\", \"text\": ...} or {\"action\": \"clear\"}",
      )
    { "command": String(other), .. } => Err("unknown command: \{other}")
    _ => Err("expected a {\"command\": ...} object")
  }
}

///|
fn parse_steer(line : Json) -> Result[Command, String] {
  match line {
    { "kind": String(kind), "text": String(text), .. } =>
      match kind {
        "prompt" => Ok(Steer(kind=Prompt, text~))
        "command" => Ok(Steer(kind=Command, text~))
        other => Err("unknown steer kind: \{other}")
      }
    { "kind": _, "text": String(_), .. } =>
      Err("expected a string \"kind\" field")
    { "text": String(text), .. } => Ok(Steer(kind=Prompt, text~))
    _ => Err("expected a string \"text\" field")
  }
}
