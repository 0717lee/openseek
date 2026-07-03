///|
/// Decoded arguments of the `create_goal` tool.
pub struct CreateGoalInput {
  objective : String
  token_budget : Int?
} derive(Debug)

///|
/// The status transition requested through `update_goal`. Only terminal
/// audited transitions are model-reachable; `active` is set by creation and
/// `budget_limited` belongs to the host.
pub enum RequestedStatus {
  Complete
  Blocked
} derive(Debug, Eq)

///|
/// Decoded arguments of the `update_goal` tool.
pub struct UpdateGoalInput {
  status : RequestedStatus
} derive(Debug)

///|
/// Decode `create_goal` arguments: a required non-blank string `objective`
/// and an optional positive integer `token_budget`. Semantic limits (length
/// cap) are enforced by the durable `GoalUpdate` constructor; this layer
/// checks shape and names the offending field.
pub fn decode_create(arguments : Json) -> CreateGoalInput raise {
  guard arguments is Object(fields) else { fail("object arguments") }
  guard fields.get("objective") is Some(String(objective)) else {
    fail("arguments.objective to be a string")
  }
  if objective.trim() == "" {
    fail("arguments.objective to be non-blank")
  }
  let token_budget = match fields.get("token_budget") {
    None | Some(Null) => None
    Some(Number(value, ..)) => {
      let budget = value.to_int()
      if budget <= 0 {
        fail("arguments.token_budget to be a positive integer")
      }
      Some(budget)
    }
    Some(_) => fail("arguments.token_budget to be a positive integer")
  }
  { objective, token_budget }
}

///|
/// Decode `update_goal` arguments: a required `status` of `"complete"` or
/// `"blocked"`.
pub fn decode_update(arguments : Json) -> UpdateGoalInput raise {
  guard arguments is { "status": String(status_text), .. } else {
    fail("arguments.status to be a string")
  }
  let status = match status_text {
    "complete" => RequestedStatus::Complete
    "blocked" => Blocked
    other =>
      fail("arguments.status to be one of complete|blocked, got \"\{other}\"")
  }
  { status, }
}
