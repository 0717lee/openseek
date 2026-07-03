///|
/// Per-run execution context shared by the goal tools and the agent loop.
///
/// Tool executors are pure `Json -> ToolAction` functions, so they cannot
/// append session events themselves. Instead the tools record requested
/// transitions here and the loop drains them (`drain_pending`) into durable
/// `Goal` session events right after each tool result — single-threaded, in
/// event order, owned by the same code path that owns every other append.
/// The cell's in-memory view is refreshed by the loop from the durable fold
/// (`refresh`), so tools always answer from state consistent with the log.
pub struct GoalCell {
  priv mut current : @agent_session.GoalUpdate?
  priv mut tokens_used : Int
  priv mut goal_events_seen : Int
  priv mut creation_allowed : Bool
  priv mut host_token_budget : Int?
  priv pending : Array[@agent_session.GoalUpdate]
}

///|
/// Build the per-run cell from the session's folded goal state.
///
/// `goal_events_seen` counts all durable `Goal` events and seeds goal-id
/// allocation: each creation appends at least one event, so
/// `goal-<seen + 1>` can never collide with an earlier goal's id.
pub fn GoalCell::GoalCell(
  current? : @agent_session.GoalUpdate,
  tokens_used? : Int = 0,
  goal_events_seen? : Int = 0,
) -> GoalCell {
  {
    current,
    tokens_used,
    goal_events_seen,
    creation_allowed: true,
    host_token_budget: None,
    pending: [],
  }
}

///|
/// Set the host-level token ceiling for active goals. Independent of any
/// budget stored on the goal itself: unattended goal runs always stop at
/// this ceiling even when the user set no explicit budget.
pub fn GoalCell::set_host_token_budget(self : GoalCell, budget : Int?) -> Unit {
  self.host_token_budget = budget
}

///|
/// Gate `create_goal` on the turn's provenance. Goals are created only from
/// user-opened turns: in an automatic continuation the "user request" a
/// creation claims to answer cannot exist, and allowing it would let a
/// blocked goal be replaced by a fresh active one in the same breath —
/// keeping the loop running past the user boundary the block should reach.
pub fn GoalCell::allow_creation(self : GoalCell, allowed : Bool) -> Unit {
  self.creation_allowed = allowed
}

///|
/// Return the latest goal transition visible to the tools.
pub fn GoalCell::current(self : GoalCell) -> @agent_session.GoalUpdate? {
  self.current
}

///|
/// Return tokens used since the current goal's creation, as last refreshed.
pub fn GoalCell::tokens_used(self : GoalCell) -> Int {
  self.tokens_used
}

///|
/// Replace the in-memory view from the durable fold. The loop calls this
/// after appending usage or goal events so tool answers track the log.
pub fn GoalCell::refresh(
  self : GoalCell,
  current : @agent_session.GoalUpdate?,
  tokens_used~ : Int,
  goal_events_seen~ : Int,
) -> Unit {
  self.current = current
  self.tokens_used = tokens_used
  self.goal_events_seen = goal_events_seen
  // Re-pointing at the durable fold makes it the truth: any requested
  // transition that never got drained (failed turn, reused cell) is stale
  // against the log and would replay old ids after newer events.
  self.pending.clear()
}

///|
/// Whether the cell's goal is active with a spent token budget, as of the
/// last refresh. The loop checks this at step boundaries so a single turn
/// cannot burn arbitrarily far past the budget before the inter-turn stop.
pub fn GoalCell::budget_exhausted(self : GoalCell) -> Bool {
  guard self.current is Some(goal) else { return false }
  guard goal.is_active() else { return false }
  let goal_spent = goal.token_budget() is Some(budget) &&
    self.tokens_used >= budget
  let host_spent = self.host_token_budget is Some(ceiling) &&
    self.tokens_used >= ceiling
  goal_spent || host_spent
}

///|
/// Remove and return the transitions requested by tools since the last
/// drain, oldest first. The caller appends them as durable `Goal` events.
pub fn GoalCell::drain_pending(
  self : GoalCell,
) -> Array[@agent_session.GoalUpdate] {
  let drained = self.pending.copy()
  self.pending.clear()
  drained
}

///|
fn GoalCell::request(
  self : GoalCell,
  update : @agent_session.GoalUpdate,
) -> Unit {
  self.pending.push(update)
  self.current = Some(update)
}

///|
fn GoalCell::next_goal_id(self : GoalCell) -> String {
  // Count the not-yet-drained requests too, so two creations in one batch
  // (rejected anyway, but cheap to keep safe) cannot collide.
  "goal-\{self.goal_events_seen + self.pending.length() + 1}"
}

///|
/// The three goal tools bound to one per-run cell: `create_goal`,
/// `update_goal`, and `get_goal`. Register the returned definitions together;
/// they share the cell's view of the current goal.
pub fn definitions(cell : GoalCell) -> Array[@agent_tool.AgentToolDefinition] {
  [
    create_goal_definition(cell),
    update_goal_definition(cell),
    get_goal_definition(cell),
  ]
}

///|
fn create_goal_definition(cell : GoalCell) -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="create_goal",
    description=(
      #|Create a persistent goal only when the user explicitly asks for one; never infer a goal from an ordinary task. The goal keeps the agent working across turns until it is complete or blocked. Set token_budget only when the user explicitly requests a budget. Fails while an unfinished goal exists; use update_goal to finish that one first.
    ),
    schema=JsonSchema({
      "type": "object",
      "properties": {
        "objective": {
          "type": "string",
          "description": "The concrete end state to pursue, at most 4000 chars.",
          "minLength": 1,
          "maxLength": 4000,
        },
        "token_budget": {
          "type": "integer",
          "description": "Positive token budget. Omit unless explicitly requested.",
          "minimum": 1,
        },
      },
      "required": ["objective"],
      "additionalProperties": false,
    }),
    execute=Sync(arguments => execute_create(cell, arguments)),
  )
}

///|
fn execute_create(cell : GoalCell, arguments : Json) -> @agent_tool.ToolAction {
  let input = @decode.decode_create(arguments) catch {
    error => {
      let message = @tool_error.failure_message("\{error}")
      return @agent_tool.ToolAction::respond(
        "error: create_goal requires \{message}",
        is_error=true,
      )
    }
  }
  if !cell.creation_allowed {
    return @agent_tool.ToolAction::respond(
      "error: goals are created from user turns only; this automatic goal turn cannot start a new goal",
      is_error=true,
    )
  }
  if cell.current() is Some(existing) && existing.is_unfinished() {
    // BudgetLimited counts as unfinished: the objective was not met, and a
    // silent replacement would discard that fact. The user decides whether
    // to re-fund or abandon it.
    return @agent_tool.ToolAction::respond(
      "error: an unfinished goal exists (\{existing.goal_id()}); use update_goal to mark it complete or blocked before creating a new one",
      is_error=true,
    )
  }
  let update = @agent_session.GoalUpdate(
    goal_id=cell.next_goal_id(),
    objective=input.objective,
    status=Active,
    token_budget?=input.token_budget,
  ) catch {
    error => {
      let message = @tool_error.failure_message("\{error}")
      return @agent_tool.ToolAction::respond(
        "error: create_goal rejected: \{message}",
        is_error=true,
      )
    }
  }
  cell.request(update)
  let budget_note = match update.token_budget() {
    Some(budget) => "token budget \{budget}"
    None => "no token budget"
  }
  @agent_tool.ToolAction::respond(
    (
      $|goal \{update.goal_id()} created (status: active, \{budget_note})
      $|<objective>
      $|\{update.objective()}
      $|</objective>
    ),
    brief="goal created · \{@agent_tool.brief_line(update.objective())}",
  )
}

///|
fn update_goal_definition(cell : GoalCell) -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="update_goal",
    description=(
      #|Set the current goal's status. Use "complete" only after a completion audit proves, from current evidence (files, command output, test results), that every requirement of the objective is satisfied — a finished checklist or plausible final answer is not proof, and stopping work or a nearly exhausted budget never justifies "complete". If the completed goal had a token budget, report the final consumed tokens to the user after update_goal succeeds. Use "blocked" only when the same blocking condition has repeated for at least three consecutive goal turns and no meaningful progress is possible without user input or an external change — never merely because the work is hard, slow, uncertain, or would benefit from clarification; if the user resumes a previously blocked goal, run a fresh blocked audit before using "blocked" again. Do not call this tool otherwise; ending a turn does not require updating the goal.
    ),
    schema=JsonSchema({
      "type": "object",
      "properties": {
        "status": { "type": "string", "enum": ["complete", "blocked"] },
      },
      "required": ["status"],
      "additionalProperties": false,
    }),
    execute=Sync(arguments => execute_update(cell, arguments)),
  )
}

///|
fn execute_update(cell : GoalCell, arguments : Json) -> @agent_tool.ToolAction {
  let input = @decode.decode_update(arguments) catch {
    error => {
      let message = @tool_error.failure_message("\{error}")
      return @agent_tool.ToolAction::respond(
        "error: update_goal requires \{message}",
        is_error=true,
      )
    }
  }
  guard cell.current() is Some(existing) else {
    return @agent_tool.ToolAction::respond(
      "error: no goal is set; create_goal starts one",
      is_error=true,
    )
  }
  // Unfinished covers Active and BudgetLimited: a budget-limited goal must
  // still be closable (complete after a final audit, or blocked), otherwise
  // no tool path out of BudgetLimited exists and goal creation deadlocks.
  guard existing.is_unfinished() else {
    return @agent_tool.ToolAction::respond(
      "error: the goal \{existing.goal_id()} is already \{status_label(existing.status())}; nothing to update",
      is_error=true,
    )
  }
  let status : @agent_session.GoalStatus = match input.status {
    Complete => Complete
    Blocked => Blocked
  }
  let update = @agent_session.GoalUpdate(
    goal_id=existing.goal_id(),
    objective=existing.objective(),
    status~,
    token_budget?=existing.token_budget(),
  ) catch {
    // The fields were validated when the goal was created; re-validation
    // cannot fail, but the constructor's contract is explicit about raising.
    error => {
      let message = @tool_error.failure_message("\{error}")
      return @agent_tool.ToolAction::respond(
        "error: update_goal rejected: \{message}",
        is_error=true,
      )
    }
  }
  cell.request(update)
  let label = status_label(update.status())
  @agent_tool.ToolAction::respond(
    "goal \{update.goal_id()} marked \{label} after \{cell.tokens_used()} tokens",
    brief="goal \{label}",
  )
}

///|
fn status_label(status : @agent_session.GoalStatus) -> String {
  match status {
    Active => "active"
    Complete => "complete"
    Blocked => "blocked"
    BudgetLimited => "budget_limited"
  }
}

///|
fn get_goal_definition(cell : GoalCell) -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="get_goal",
    description=(
      #|Get the current goal for this session: objective, status, token budget, tokens used, and remaining budget.
    ),
    schema=JsonSchema({
      "type": "object",
      "properties": {},
      "additionalProperties": false,
    }),
    execute=Sync(arguments => execute_get(cell, arguments)),
  )
}

///|
fn execute_get(cell : GoalCell, arguments : Json) -> @agent_tool.ToolAction {
  ignore(arguments)
  guard cell.current() is Some(goal) else {
    return @agent_tool.ToolAction::respond("no goal is set", brief="no goal")
  }
  let status = match goal.status() {
    Active => "active"
    Complete => "complete"
    Blocked => "blocked"
    BudgetLimited => "budget_limited"
  }
  let (budget, remaining) = match goal.token_budget() {
    Some(budget) => {
      let left = budget - cell.tokens_used()
      (budget.to_string(), (if left < 0 { 0 } else { left }).to_string())
    }
    None => ("none", "unbounded")
  }
  @agent_tool.ToolAction::respond(
    (
      $|goal \{goal.goal_id()} (status: \{status})
      $|tokens used: \{cell.tokens_used()} · budget: \{budget} · remaining: \{remaining}
      $|<objective>
      $|\{goal.objective()}
      $|</objective>
    ),
    brief="goal \{status} · \{cell.tokens_used()} tokens",
  )
}
