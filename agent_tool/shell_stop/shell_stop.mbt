///|
/// Tool definition for `shell_stop`: terminate a background job started by
/// `shell` with `run_in_background`.
///
/// ## Arguments
/// - `job_id` (string, required): the id `shell` returned when it started the
///   job.
///
/// ## Result
/// - `Respond(ToolOutput("stopped background job <id>"))` once the job's process
///   is cancelled (or was already finished). Read any final output with
///   `shell_output`.
/// - `Respond(ToolOutput("error: no background job ...", is_error=true))` for an
///   unknown id, and `"error: shell_stop requires ..."` for invalid arguments.
pub fn definition(
  bg_runtime : @bgjobs.BgJobRuntime,
) -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="shell_stop",
    description="Stop a background job started by `shell` with run_in_background, cancelling its process. Argument: job_id (the id shell returned). Read any final output with shell_output.",
    schema=JsonSchema({
      "type": "object",
      "properties": { "job_id": { "type": "string" } },
      "required": ["job_id"],
    }),
    execute=Async(arguments => run(bg_runtime, arguments)),
  )
}

///|
async fn run(
  bg_runtime : @bgjobs.BgJobRuntime,
  arguments : Json,
) -> @agent_tool.ToolAction {
  let job_id = match job_id_argument(arguments) {
    Ok(id) => id
    Err(message) =>
      return @agent_tool.ToolAction::respond(message, is_error=true)
  }
  if bg_runtime.stop(job_id) {
    @agent_tool.ToolAction::respond(
      "stopped background job \{job_id}",
      brief="stop \{job_id}",
    )
  } else {
    @agent_tool.ToolAction::respond(
      "error: no background job with id \{job_id}",
      is_error=true,
    )
  }
}

///|
/// Extract a non-empty `job_id` string, or an error message naming the problem.
fn job_id_argument(arguments : Json) -> Result[String, String] {
  match arguments {
    Object(fields) =>
      match fields.get("job_id") {
        Some(String(id)) if id != "" => Ok(id)
        _ => Err("error: shell_stop requires a non-empty job_id string")
      }
    _ => Err("error: shell_stop requires object arguments")
  }
}
