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
/// It reports a line this protocol cannot read, and nothing else. Whether a
/// readable command is *acceptable* is the engine's to say: a blank goal is
/// well-formed and refused, and `serve` refuses it. Were that check here,
/// `GoalSet(text="  ")` would be a value this type holds and `to_json` writes
/// but `parse` rejects — breaking the round-trip below for a value the type
/// itself offers.
///
/// Unlike `parse` for events, this returns a `Result`: an unreadable event is
/// a line to ignore, but an unreadable command is a request that will never be
/// answered, and silence is the one reply a controller cannot act on.
///
/// ## When a field may be absent
///
/// The same rule `parse` states for events, and both of its cases apply here —
/// one field each, verified against `git log -S` for the field versus its
/// command's introducing commit:
///
/// 1. **Added after its command existed.** `steer`'s `kind` arrived in
///    9b2f6c43; `steer` itself in 17562cc1. An engine from between them is sent
///    a `kind` it ignores, and a controller older than the field sends none —
///    so absent means `Prompt`, which is what every controller meant before
///    there was a choice. The desktop was still sending exactly that.
/// 2. **Optional since the command shipped.** `goal`'s `auto` arrived *with*
///    `goal` (c8cc6ad7), so case (1) does not cover it — but the engine has
///    read `auto` as absent-means-false from the first line it ever decoded.
///    It is a flag with a default, not a value that can go missing.
///
/// The distinction matters because only (1) is about talking to an old
/// binary. A field that is merely unread — `text` on a command nobody
/// inspects — is still required: its absence means the line is not what it
/// claims.
pub fn Command::parse(line : Json) -> Result[Command, String] {
  match line {
    { "command": "prompt", "text": String(text), .. } => Ok(Prompt(text~))
    { "command": "steer", .. } => parse_steer(line)
    { "command": "prompt", .. } => Err("expected a string \"text\" field")
    { "command": "compact", .. } => Ok(Compact)
    { "command": "cancel", .. } => Ok(Cancel)
    // A blank goal decodes: `{"action":"set","text":"  "}` is a well-formed
    // command, and refusing it is the engine's policy, not the wire's shape.
    // Keeping the check here would make `GoalSet(text="  ")` a value this type
    // can hold, `to_json` can write, and `parse` then rejects — a round-trip
    // the type advertises and would not have. `serve` rejects it, in the same
    // words, where the policy lives.
    { "command": "goal", "action": "set", "text": String(text), .. } =>
      Ok(GoalSet(text~, auto=line is { "auto": True, .. }))
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
  // `text` is required whatever the kind says, so it is checked once here
  // rather than restated in three arms, where the precedence between "no text"
  // and "bad kind" was emergent from their order.
  guard line is { "text": String(text), .. } else {
    return Err("expected a string \"text\" field")
  }
  match line {
    { "kind": String("prompt"), .. } => Ok(Steer(kind=Prompt, text~))
    { "kind": String("command"), .. } => Ok(Steer(kind=Command, text~))
    { "kind": String(other), .. } => Err("unknown steer kind: \{other}")
    { "kind": _, .. } => Err("expected a string \"kind\" field")
    // A steer with no kind at all is a prompt steer: see the rule above.
    _ => Ok(Steer(kind=Prompt, text~))
  }
}
