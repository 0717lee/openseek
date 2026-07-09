///|
/// Decoded `goal` tool arguments: the model's structured verdict on the
/// standing session goal.
pub(all) enum GoalStatus {
  Met
  Continuing(String)
  /// The goal cannot proceed (impossible, blocked, or superseded): it
  /// keeps standing for the user, but auto-continuation pauses.
  Blocked(String)
} derive(Debug)

///|
/// Decode and validate `goal` tool-call arguments. `met` needs nothing else;
/// `continuing` requires a non-blank `remaining` — the durable record must be
/// actionable for whoever (or whatever turn) resumes the goal.
pub fn decode_status(arguments : Json) -> Result[GoalStatus, String] {
  match arguments {
    { "status": "met", .. } => Ok(Met)
    { "status": "continuing", "remaining": String(remaining), .. } =>
      if remaining.trim().is_empty() {
        Err(
          "goal requires a non-blank \"remaining\" when status is \"continuing\"",
        )
      } else {
        Ok(Continuing(remaining))
      }
    { "status": "continuing", .. } =>
      Err("goal requires a string \"remaining\" when status is \"continuing\"")
    { "status": "blocked", "reason": String(reason), .. } =>
      if reason.trim().is_empty() {
        Err("goal requires a non-blank \"reason\" when status is \"blocked\"")
      } else {
        Ok(Blocked(reason))
      }
    { "status": "blocked", .. } =>
      Err("goal requires a string \"reason\" when status is \"blocked\"")
    { "status": String(other), .. } =>
      Err(
        "goal status must be \"met\", \"continuing\", or \"blocked\", got \"\{other}\"",
      )
    _ => Err("goal requires a string \"status\" field")
  }
}

///|
/// Tool definition for `goal`: record the standing goal's status as
/// structured state instead of prose, so the engine can act on it — `met`
/// durably clears the goal (the auto-continue termination signal) and
/// `continuing` records what remains.
///
/// The agent loop intercepts calls to this tool before execution: only the
/// loop knows whether a goal currently stands and owns the durable log, and
/// the clear must land at a batch-safe boundary. This stateless execute is
/// the fallback for registries dispatched outside the loop; it validates the
/// arguments and acknowledges without touching any state.
pub fn definition() -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="goal",
    description=(
      #|Record the status of the standing session goal. Call with status "met" only when the goal is fully achieved and verified — this durably clears it. Call with status "continuing" plus a short "remaining" summary when you finish a task while goal work remains. Call with status "blocked" plus a "reason" when the goal cannot proceed (impossible, blocked, or superseded) — the goal keeps standing for the user, but autonomous continuation pauses. Only meaningful when a standing goal is set.
    ),
    schema=JsonSchema({
      "type": "object",
      "properties": {
        "status": { "type": "string", "enum": ["met", "continuing", "blocked"] },
        "remaining": {
          "type": "string",
          "description": "Required when status is \"continuing\": one or two lines on what is left to reach the goal.",
        },
        "reason": {
          "type": "string",
          "description": "Why the goal cannot proceed; required with status \"blocked\".",
        },
      },
      "required": ["status"],
      "additionalProperties": false,
    }),
    execute=Sync(execute),
    control=true,
  )
}

///|
fn execute(arguments : Json) -> @agent_tool.ToolAction {
  match decode_status(arguments) {
    Ok(_) => @agent_tool.ToolAction::respond("goal status recorded")
    Err(message) =>
      @agent_tool.ToolAction::respond("error: \{message}", is_error=true)
  }
}
