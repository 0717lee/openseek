///|
/// Tool `shell_output`: read a background shell job's output and status by id.
/// The id comes from `shell run_in_background`, or from a foreground command that
/// was moved to the background when it exceeded its `timeout_ms`.
pub fn definition(
  bg_runtime : @bgjobs.BgJobRuntime,
) -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="shell_output",
    description="Read a background shell job's output and status by its job_id (returned by shell run_in_background, or by a command moved to the background on timeout). Returns the full output captured so far and whether the job is still running.",
    schema=JsonSchema({
      "type": "object",
      "properties": { "job_id": { "type": "string" } },
      "required": ["job_id"],
    }),
    execute=Async(arguments => execute(bg_runtime, arguments)),
  )
}

///|
async fn execute(
  bg_runtime : @bgjobs.BgJobRuntime,
  arguments : Json,
) -> @agent_tool.ToolAction {
  guard arguments is { "job_id": String(job_id), .. } else {
    return @agent_tool.ToolAction::respond(
      "error: shell_output requires a string job_id",
      is_error=true,
    )
  }
  guard bg_runtime.snapshot(job_id) is Some(snapshot) else {
    return @agent_tool.ToolAction::respond(
      "error: no background job with id \{job_id}",
      is_error=true,
    )
  }
  // Recent output, bounded to a window so a poll cannot flood the conversation
  // with a large job's full log. For output over the window, show the *tail*
  // (recent progress) and note the total size.
  let window = 12000
  let output = bg_runtime
    .read_output_tail(job_id, window)
    .unwrap_or(snapshot.output)
  let (status_label, is_error) = match snapshot.status {
    Running => ("running", false)
    Exited(code) => ("exit=\{code}", code != 0)
    Stopped => ("stopped", true)
  }
  let truncation = if snapshot.size > window {
    " truncated=true total_chars=\{snapshot.size} showing_last=\{window}"
  } else {
    ""
  }
  let footer = "<system>job=\{job_id} \{status_label}\{truncation}</system>"
  let content = if output == "" {
    footer
  } else if output.has_suffix("\n") {
    "\{output}\{footer}"
  } else {
    "\{output}\n\{footer}"
  }
  @agent_tool.ToolAction::respond(content, is_error~)
}
