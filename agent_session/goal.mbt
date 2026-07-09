///|
/// First line of the runtime notice that sets a standing goal. The full
/// marker content is `[goal]\n<text>`; `Session::current_goal` keys off the
/// exact prefix line, so it lives here with `RuntimeNotice` alongside
/// `PlanReminderPrefix` where producers (the serve engine, the agent loop)
/// and readers (the scan, viz, tests) share it. The bracket tags below are
/// reserved: only the goal command paths write notices with these first
/// lines.
pub const GoalPrefix : String = "[goal]"

///|
/// Exact content of the tombstone notice that clears a standing goal.
pub const GoalClearedNotice : String = "[goal cleared]"

///|
/// Marker prefix recording that the model declared the standing goal
/// BLOCKED: the goal keeps standing (the user decides what is next), but
/// auto-continuation must pause instead of relaunching declared-impossible
/// work.
pub const GoalBlockedPrefix : String = "[goal blocked]"

///|
/// First line of the reminder notice the agent loop re-injects so a
/// long-running conversation keeps the standing goal near the context tail.
pub const GoalReminderPrefix : String = "[goal reminder]"

///|
/// First line of the notice the agent loop injects when the model tries to
/// end a turn while a standing goal is set.
pub const GoalCheckPrefix : String = "[goal check]"

///|
/// A standing goal derived from the durable event log.
pub struct StandingGoal {
  priv text : String
  priv answered_since_set : Bool
  priv set_sequence : Int
  priv blocked : Bool
} derive(Debug)

///|
/// The goal text as it was set (may span lines when set over the wire).
pub fn StandingGoal::text(self : StandingGoal) -> String {
  self.text
}

///|
/// Sequence of the set marker event that established this goal. Marker
/// identity for consumers that must distinguish "this exact set persisted"
/// from "an identical-text goal was already standing" — text alone cannot.
pub fn StandingGoal::set_sequence(self : StandingGoal) -> Int {
  self.set_sequence
}

///|
/// Whether any model response (assistant message or turn terminal) was
/// appended after the goal was set. When false the set marker itself is
/// still ahead of the model's next request, so injecting a turn-start
/// reminder would only duplicate it.
pub fn StandingGoal::answered_since_set(self : StandingGoal) -> Bool {
  self.answered_since_set
}

///|
/// Whether the model durably declared this goal blocked since it was set:
/// the goal still stands for the user, but auto-continuation must pause.
pub fn StandingGoal::blocked(self : StandingGoal) -> Bool {
  self.blocked
}

///|
/// A goal marker recognized in a runtime notice.
pub(all) enum GoalMarker {
  GoalSet(String)
  GoalCleared
  GoalBlocked(String)
} derive(Debug)

///|
/// Parse a runtime-notice content as a goal marker, if it is one. The set
/// marker requires the exact `[goal]` first line and the tombstone requires
/// exact content, so other notices (plan reminders, goal reminders, goal
/// checks) never match.
pub fn goal_marker(content : String) -> GoalMarker? {
  if content == GoalClearedNotice {
    Some(GoalCleared)
  } else if content.has_prefix("\{GoalBlockedPrefix}\n") {
    Some(
      GoalBlocked(
        "\{content.view(start_offset=GoalBlockedPrefix.length() + 1)}",
      ),
    )
  } else if content.has_prefix("\{GoalPrefix}\n") {
    Some(GoalSet(content[GoalPrefix.length() + 1:].to_owned()))
  } else {
    None
  }
}

///|
/// Standing goal state: the last goal marker in the log wins — a
/// `[goal]\n<text>` notice yields that goal, a `[goal cleared]` tombstone
/// yields none.
///
/// The scan reads raw events, not the compacted projection, so a goal whose
/// set marker is covered by a later compaction summary is still recovered
/// verbatim from the append-only log.
pub fn Session::current_goal(self : Session) -> StandingGoal? {
  let events = self.events()
  let mut answered = false
  let mut blocked = false
  let covered : Array[(Int, Int)] = []
  for index = events.length() - 1; index >= 0; index = index - 1 {
    match events[index].item() {
      Assistant(_) | Terminal(_) => answered = true
      // A summary whose range CONTAINS the set marker removes its verbatim
      // text from the projection: treat the goal as "answered" so the
      // cadence re-surfaces it — the next request must not see only the
      // lossy summary where the standing goal used to be. A summary of
      // later events leaves the marker verbatim and must not re-remind.
      Summary(summary) =>
        covered.push((summary.from_sequence(), summary.to_sequence()))
      Runtime(notice) =>
        match goal_marker(notice.content()) {
          Some(GoalCleared) => return None
          // Newest-first: a blocked marker precedes the set it follows
          // temporally; a NEWER set is found first and naturally resets it.
          Some(GoalBlocked(_)) => blocked = true
          Some(GoalSet(text)) => {
            let sequence = events[index].sequence()
            let mut is_covered = false
            for range in covered {
              let (from, to) = range
              if from <= sequence && sequence <= to {
                is_covered = true
                break
              }
            }
            return Some({
              text,
              answered_since_set: answered || is_covered,
              set_sequence: sequence,
              blocked,
            })
          }
          None => ()
        }
      _ => ()
    }
  }
  None
}
