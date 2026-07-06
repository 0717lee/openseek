///|
/// Tool definition for `shell_output`: read the captured output and current
/// status of a background job started by `shell` with `run_in_background`.
///
/// ## Arguments
/// - `job_id` (string, required): the id `shell` returned when it started the
///   job.
///
/// ## Result
/// - `Respond(ToolOutput("<output>\n<system>job=<id> status=<status> ...</system>"))`
///   with the retained output and a trailing status footer. `status` is
///   `running`, `exited=<code>`, or `stopped`; the result is a tool error only
///   when the job exited non-zero.
/// - `Respond(ToolOutput("error: no background job ...", is_error=true))` for an
///   unknown id, and `"error: shell_output requires ..."` for invalid arguments.
pub fn definition(
  bg_runtime : @bgjobs.BgJobRuntime,
) -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="shell_output",
    description="Read the captured output and status of a background job started by `shell` with run_in_background. Argument: job_id (the id shell returned). Call it again to see new output while the job is still running.",
    schema=JsonSchema({
      "type": "object",
      "properties": { "job_id": { "type": "string" } },
      "required": ["job_id"],
    }),
    execute=Sync(arguments => run(bg_runtime, arguments)),
  )
}

///|
fn run(
  bg_runtime : @bgjobs.BgJobRuntime,
  arguments : Json,
) -> @agent_tool.ToolAction {
  let job_id = match job_id_argument(arguments) {
    Ok(id) => id
    Err(message) =>
      return @agent_tool.ToolAction::respond(message, is_error=true)
  }
  match bg_runtime.snapshot(job_id) {
    None =>
      @agent_tool.ToolAction::respond(
        "error: no background job with id \{job_id}",
        is_error=true,
      )
    Some(snapshot) => render(snapshot)
  }
}

///|
/// Extract a non-empty `job_id` string, or an error message naming the problem.
fn job_id_argument(arguments : Json) -> Result[String, String] {
  match arguments {
    Object(fields) =>
      match fields.get("job_id") {
        Some(String(id)) if id != "" => Ok(id)
        _ => Err("error: shell_output requires a non-empty job_id string")
      }
    _ => Err("error: shell_output requires object arguments")
  }
}

///|
/// Render a snapshot as output plus a trailing `<system>...</system>` status
/// footer (the `read`/`shell` tool convention). A non-zero exit is a tool error.
fn render(snapshot : @bgjobs.BgJobSnapshot) -> @agent_tool.ToolAction {
  let truncated = if snapshot.output_truncated { " truncated=true" } else { "" }
  let footer = "<system>job=\{snapshot.id} status=\{status_text(snapshot.status)}\{truncated}</system>"
  let content = if snapshot.output == "" {
    footer
  } else if snapshot.output.has_suffix("\n") {
    "\{snapshot.output}\{footer}"
  } else {
    "\{snapshot.output}\n\{footer}"
  }
  let is_error = snapshot.status is Exited(code) && code != 0
  @agent_tool.ToolAction::respond(
    content,
    is_error~,
    brief="\{snapshot.id}: \{status_text(snapshot.status)}",
  )
}

///|
/// A background job's status as compact footer text.
fn status_text(status : @bgjobs.BgJobStatus) -> String {
  match status {
    Running => "running"
    Exited(code) => "exited=\{code}"
    Stopped => "stopped"
  }
}
