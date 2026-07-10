///|
/// The turn-start reminder is a DECISION POINT, not just an alignment
/// note: each turn — under auto-continue, each context-window cycle —
/// opens with a brief three-way assessment. Catching "already met" or
/// "cannot proceed" here saves a whole window of work; the finish check
/// still gates the exit so a completion cannot slip out unverified.
fn goal_reminder_text(goal : String, tool_registered~ : Bool) -> String {
  let met_action = if tool_registered {
    "record that by calling the goal tool with status \"met\", then finish"
  } else {
    "finish and say so"
  }
  (
    $|\{@agent_session.GoalReminderPrefix}
    $|The standing goal for this session:
    $|\{goal}
    $|Assess it briefly at this turn boundary:
    $|- Fully met? Verify per the goal's own criteria first, then
    $|  \{met_action}.
    $|- Unable to proceed (blocked, impossible, or superseded)? Record that
    $|  — call the goal tool with status "blocked" and a reason if it is
    $|  available, otherwise say why — then finish; the user decides what
    $|  is next.
    $|- Otherwise continue working toward it. If the current task conflicts
    $|  with the goal, the current task wins; note the conflict briefly.
  )
}

///|
fn goal_check_text(goal : String, tool_registered~ : Bool) -> String {
  if tool_registered {
    (
      $|\{@agent_session.GoalCheckPrefix}
      $|The standing goal for this session:
      $|\{goal}
      $|You attempted to finish. If the goal is fully met, record that by
      $|calling the goal tool with status "met", then finish. If this task
      $|is complete but the goal is not, call the goal tool with status
      $|"continuing" and what remains, then finish. If the goal cannot
      $|proceed (blocked, impossible, or superseded), call the goal tool
      $|with status "blocked" and a reason, then finish — the user decides
      $|what is next. Otherwise continue working toward the goal.
    )
  } else {
    (
      $|\{@agent_session.GoalCheckPrefix}
      $|The standing goal for this session:
      $|\{goal}
      $|You attempted to finish. If the goal is fully met, finish again and
      $|say so. If this task is complete but the goal is not, finish with a
      $|one-line status of what remains. Otherwise continue working toward
      $|the goal.
    )
  }
}

///|
/// Standing-goal tracking for one turn, parallel to `PlanCadence`. Seeded
/// from the durable log at loop construction; a mid-turn goal set/clear
/// steer updates it live through `observe_notice`. Turn-local by design — a
/// fresh loop re-derives the goal from the session.
///
/// `remind_now` starts true only when the model has already answered since
/// the goal was set: a fresh set marker still rides the next request, so a
/// turn-start reminder would only duplicate it. `finish_checked` caps the
/// finish-time goal check at one per turn — the model may end the turn
/// immediately after answering the check, so a turn is never held hostage.
priv struct GoalCadence {
  /// Whether the goal status tool is in this turn's registry: selects the
  /// tool-aware finish-check text and enables the structured met/continuing
  /// protocol.
  tool_registered : Bool
  mut goal : String?
  mut remind_now : Bool
  mut finish_checked : Bool
  /// A blocked verdict awaiting its durable marker at a batch-safe
  /// boundary, exactly like the met tombstone.
  mut pending_blocked_reason : String?
  /// A goal(met) call was recorded mid-batch; the durable [goal cleared]
  /// tombstone must land only at a batch-safe boundary (next step start or
  /// turn finish) — a mid-batch runtime notice would make replay synthesize
  /// exited-errors for the batch's remaining tool calls.
  mut pending_tombstone : Bool
}

///|
fn GoalCadence::GoalCadence(
  session : @agent_session.Session,
  tool_registered~ : Bool,
) -> GoalCadence {
  let standing = session.current_goal()
  {
    tool_registered,
    goal: standing.map(goal => goal.text()),
    remind_now: standing.map(goal => goal.answered_since_set()).unwrap_or(false),
    finish_checked: false,
    pending_blocked_reason: None,
    pending_tombstone: false,
  }
}

///|
/// The goal text when a finish attempt should be answered with a goal check
/// instead of ending the turn.
fn GoalCadence::due_finish_check(self : GoalCadence) -> String? {
  if self.finish_checked {
    None
  } else {
    self.goal
  }
}

///|
/// A structured goal(met) call: the goal stops standing immediately (the
/// finish check disarms) and the durable tombstone is deferred to the next
/// batch-safe boundary.
fn GoalCadence::record_goal_met(self : GoalCadence) -> Unit {
  self.goal = None
  self.pending_tombstone = true
}

///|
/// A structured goal(continuing) call answers exactly what the finish check
/// would ask, so the check disarms for the rest of the turn.
fn GoalCadence::record_goal_continuing(self : GoalCadence) -> Unit {
  self.finish_checked = true
}

///|
fn GoalCadence::record_finish_check(self : GoalCadence) -> Unit {
  self.finish_checked = true
  // The check restates the goal, so it counts as the turn's reminder:
  // without the reset, a pending turn-start reminder could fire right
  // after the check, burying the confirmation ask it just injected.
  self.remind_now = false
}

///|
/// The goal text when a reminder is due: once per turn, at the start. No
/// mid-turn re-reminders — since turns became context-bounded, nothing
/// ever leaves the model's context within a turn, so the turn-start
/// reminder (or the goal marker itself) stays visible throughout; the
/// finish check is the enforcement point, and under auto-continue each
/// context-window cycle starts a fresh turn that re-surfaces the goal
/// right after the checkpoint.
fn GoalCadence::due_reminder(self : GoalCadence) -> String? {
  if self.remind_now {
    self.goal
  } else {
    None
  }
}

///|
fn GoalCadence::record_reminder(self : GoalCadence) -> Unit {
  self.remind_now = false
}

///|
/// Track a durably applied notice steer. A goal set/clear marker updates the
/// live cadence and reports the new state as a `goal_updated` event. The
/// event is emitted here — after the durable append, never at queue time —
/// so a controller can only learn a goal that was actually persisted.
fn GoalCadence::observe_notice(self : GoalCadence, content : String) -> Unit {
  match @agent_session.goal_marker(content) {
    Some(GoalSet(text)) => {
      self.goal = Some(text)
      self.remind_now = false
      // A NEW goal deserves its own finish check: without this reset, a
      // goal set after an earlier check in the same turn would let the
      // next finish attempt end the turn unconfirmed.
      self.finish_checked = false
      // A deferred tombstone belonged to the goal this set supersedes;
      // flushing it after the new marker would wipe the new goal (last
      // marker wins in the scan).
      self.pending_tombstone = false
      // Same for a deferred blocked verdict: flushing it after the new
      // marker would mark the REPLACEMENT goal blocked.
      self.pending_blocked_reason = None
      @xlog.info() <? { "event": "goal_updated", "goal": text }
    }
    Some(GoalCleared) => {
      self.goal = None
      // A durable clear just landed; a second tombstone would be noise.
      self.pending_tombstone = false
      self.pending_blocked_reason = None
      @xlog.info() <? { "event": "goal_updated", "goal": (None : String?) }
    }
    // A blocked marker changes auto-continuation policy (serve reads it
    // from the standing goal), not the cadence: the goal still stands.
    Some(GoalBlocked(_)) => ()
    None => ()
  }
}

///|
/// Flush a deferred goal tombstone at a batch-safe boundary: the durable
/// `[goal cleared]` clear for a goal(met) recorded mid-batch, appended
/// through the loop's persistence seam and reported as `goal_updated` only
/// after that append succeeds.
async fn AgentLoop::flush_goal_tombstone(
  self : Self,
  session : @agent_session.Session,
) -> @agent_session.Session {
  let session = if self.goal_cadence.pending_blocked_reason is Some(reason) {
    let next = self.append_runtime_notice(
      session,
      "\{@agent_session.GoalBlockedPrefix}\n\{reason}",
    )
    // Cleared only AFTER the durable append, like the tombstone.
    self.goal_cadence.pending_blocked_reason = None
    @xlog.info() <? { "event": "goal_blocked", "reason": reason }
    next
  } else {
    session
  }
  if !self.goal_cadence.pending_tombstone {
    return session
  }
  let next = self.append_runtime_notice(
    session,
    @agent_session.GoalClearedNotice,
  )
  // Cleared only AFTER the durable append: a failed append must leave the
  // flag set so the error-path retry still lands the tombstone — otherwise
  // a durable goal(met) result coexists with a resurrected goal on resume.
  self.goal_cadence.pending_tombstone = false
  @xlog.info() <? { "event": "goal_updated", "goal": (None : String?) }
  next
}

///|
/// Handle a `goal` status tool call in place of executing the registry
/// entry: only the loop knows whether a goal currently stands, and the
/// durable clear must be sequenced at a batch-safe boundary. `met` clears
/// the standing goal (tombstone deferred via `record_goal_met`);
/// `continuing` records the structured remainder and stands in for the
/// finish check. Either with no standing goal is an error result — a
/// semantic assertion against missing state should read as model confusion
/// in the transcript, not success.
async fn AgentLoop::handle_goal_tool_call(
  self : Self,
  session : @agent_session.Session,
  native_call : @deepseek.ToolCall,
  tool_call : @agent_tool.AgentToolCall,
) -> ToolCallOutcome {
  let verdict = (
    @goal.decode_status(tool_call.arguments),
    self.goal_cadence.goal,
  )
  let (content, is_error) = match verdict {
    (Err(message), _) => ("error: \{message}", true)
    (Ok(_), None) => ("error: no standing goal is set", true)
    (Ok(Met), Some(_)) =>
      ("goal recorded as met; the standing goal is now cleared", false)
    (Ok(Continuing(remaining)), Some(_)) =>
      ("goal status recorded as continuing: \{remaining}", false)
    (Ok(Blocked(reason)), Some(_)) =>
      (
        "goal recorded as blocked: \{reason}. The goal still stands; auto-continuation is paused for the user",
        false,
      )
  }
  let session = self.record_tool_result(
    session,
    tool_call_id=native_call.id,
    tool_name=tool_call.name,
    content~,
    is_error~,
  )
  // Cadence updates only after the result append succeeded: a rejected
  // append must not leave a pending tombstone (the error-path flush would
  // then durably clear a goal whose met verdict was never persisted).
  match verdict {
    (Ok(Met), Some(_)) => self.goal_cadence.record_goal_met()
    (Ok(Continuing(_)), Some(_)) => self.goal_cadence.record_goal_continuing()
    // Blocked answers the check like continuing, and lands a durable
    // marker so serve pauses auto-continuation while the goal stands.
    (Ok(Blocked(reason)), Some(_)) => {
      self.goal_cadence.record_goal_continuing()
      self.goal_cadence.pending_blocked_reason = Some(reason)
    }
    _ => ()
  }
  @xlog.info() <?
    {
      "event": "tool_result",
      "tool_call_id": native_call.id,
      "tool_name": tool_call.name,
      "is_error": is_error,
      "content": content,
    }
  ContinueToolBatch(session)
}
