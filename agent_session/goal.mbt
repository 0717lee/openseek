///|
/// Lifecycle status of a session goal. Deliberately disjoint from plan-step
/// statuses (`pending`/`in_progress`/`completed`): a goal is a durable
/// destination with lifecycle gates, not checklist bookkeeping.
///
/// `Active` — the continuation loop keeps starting turns. `Complete` — the
/// model proved the objective against current evidence. `Blocked` — the model
/// hit a repeated impasse needing user input. `BudgetLimited` — the host
/// stopped the loop because the token budget ran out.
pub(all) enum GoalStatus {
  Active
  Complete
  Blocked
  BudgetLimited
} derive(Debug, Eq)

///|
/// Objective size cap, mirroring Codex's MAX_THREAD_GOAL_OBJECTIVE_CHARS.
/// The objective is re-injected into model context on every continuation, so
/// an unbounded objective would tax every turn of a long-running goal.
pub const MAX_GOAL_OBJECTIVE_CHARS : Int = 4000

///|
/// One durable goal transition: creation (`Active`) or a later status change.
///
/// Goal events are metadata-only session items: they store and replay but
/// never project into model messages. The goal reaches the model through
/// continuation steering (`Internal` items), not through the event itself.
/// The current goal is a fold over these events — see `Session::current_goal`.
pub struct GoalUpdate {
  priv goal_id : String
  priv objective : String
  priv status : GoalStatus
  priv token_budget : Int?
} derive(Debug, ToJson, FromJson)

///|
/// Record one goal transition.
///
/// `goal_id` must be non-empty; `objective` must be non-blank and at most
/// `MAX_GOAL_OBJECTIVE_CHARS` chars; `token_budget`, when present, must be
/// positive. Later transitions of the same goal repeat the `goal_id` (and
/// normally the objective and budget) with the new status.
pub fn GoalUpdate::GoalUpdate(
  goal_id~ : String,
  objective~ : String,
  status~ : GoalStatus,
  token_budget? : Int,
) -> GoalUpdate raise {
  guard goal_id != "" else { fail("goal_id must not be empty") }
  guard objective.trim() != "" else { fail("goal objective must not be empty") }
  if objective.length() > MAX_GOAL_OBJECTIVE_CHARS {
    fail(
      "goal objective must be at most \{MAX_GOAL_OBJECTIVE_CHARS} chars, got \{objective.length()}",
    )
  }
  if token_budget is Some(budget) && budget <= 0 {
    fail("goal token_budget must be positive, got \{budget}")
  }
  { goal_id, objective, status, token_budget }
}

///|
/// Return the stable identifier shared by all transitions of one goal.
pub fn GoalUpdate::goal_id(self : GoalUpdate) -> String {
  self.goal_id
}

///|
/// Return the goal objective text.
pub fn GoalUpdate::objective(self : GoalUpdate) -> String {
  self.objective
}

///|
/// Return the goal lifecycle status recorded by this transition.
pub fn GoalUpdate::status(self : GoalUpdate) -> GoalStatus {
  self.status
}

///|
/// Return the token budget, if one was set.
pub fn GoalUpdate::token_budget(self : GoalUpdate) -> Int? {
  self.token_budget
}

///|
/// The current goal as derived from the event log: the latest transition plus
/// usage accounting folded from `Usage` events.
///
/// `tokens_used` sums every usage event recorded after the goal was created
/// (its first `Goal` event), so it spans all of the goal's turns and replays
/// identically after resume.
pub struct GoalSnapshot {
  priv goal : GoalUpdate
  priv tokens_used : Int
} derive(Debug)

///|
/// Return the latest transition of the current goal.
pub fn GoalSnapshot::goal(self : GoalSnapshot) -> GoalUpdate {
  self.goal
}

///|
/// Return total tokens used since the goal was created.
pub fn GoalSnapshot::tokens_used(self : GoalSnapshot) -> Int {
  self.tokens_used
}

///|
/// Return the remaining token budget, or `None` when the goal is unbudgeted.
/// Never negative: an overshoot reports zero remaining.
pub fn GoalSnapshot::remaining_tokens(self : GoalSnapshot) -> Int? {
  match self.goal.token_budget() {
    Some(budget) => {
      let remaining = budget - self.tokens_used
      Some(if remaining < 0 { 0 } else { remaining })
    }
    None => None
  }
}

///|
/// Fold the event log into the current goal, or `None` when the session has
/// no goal events.
///
/// The latest `Goal` event wins. Usage accounting starts at the goal's
/// creating event: the first `Goal` event carrying the same `goal_id`. Usage
/// recorded before the goal existed does not count against its budget.
pub fn Session::current_goal(self : Session) -> GoalSnapshot? {
  let mut latest : GoalUpdate? = None
  for event in self.events() {
    if event.item() is Goal(update) {
      latest = Some(update)
    }
  }
  guard latest is Some(goal) else { return None }
  // Find the goal's creating event, then sum usage recorded after it.
  let mut created_sequence = -1
  for event in self.events() {
    if event.item() is Goal(update) && update.goal_id() == goal.goal_id() {
      created_sequence = event.sequence()
      break
    }
  }
  let mut tokens_used = 0
  for event in self.events() {
    if event.sequence() > created_sequence && event.item() is Usage(usage) {
      tokens_used += usage.total_tokens()
    }
  }
  Some({ goal, tokens_used })
}
