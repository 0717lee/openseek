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
  // (recent progress).
  let window = 12000
  let output = bg_runtime
    .read_output_tail(job_id, window)
    .unwrap_or(snapshot.output)
  let (status_label, exit_error) = match snapshot.status {
    Running => ("running", false)
    Exited(code) => ("exit=\{code}", code != 0)
    Stopped => ("stopped", true)
  }
  // Preserve the foreground path's error semantics for a job read later: binary
  // (non-UTF-8) output and a sandboxed source-write denial are tool errors even
  // when the command exited 0.
  let sandbox_denied = snapshot.source_write_sandboxed &&
    @shell.source_write_denied_in_text(output, snapshot.sandbox_denial_subjects)
  let is_error = exit_error || snapshot.had_invalid_utf8 || sandbox_denied
  // Truncated whenever what we show is less than what the job produced — this
  // covers the window (large output), a memory-only runtime that dropped output
  // past the budget, and a hard-cap drop — so a prefix is never presented as the
  // complete output.
  let shown = output.char_length()
  let truncation = if shown < snapshot.size || snapshot.output_truncated {
    let cap = if snapshot.output_truncated {
      " output_dropped_at_cap=true"
    } else {
      ""
    }
    " truncated=true total_chars=\{snapshot.size} shown_chars=\{shown}\{cap}"
  } else {
    ""
  }
  let binary = if snapshot.had_invalid_utf8 {
    " binary_output=true"
  } else {
    ""
  }
  let footer = "<system>job=\{job_id} \{status_label}\{truncation}\{binary}</system>"
  let body = if output == "" {
    footer
  } else if output.has_suffix("\n") {
    "\{output}\{footer}"
  } else {
    "\{output}\n\{footer}"
  }
  // Append the source-write denial guidance, exactly as the foreground path does.
  let content = if sandbox_denied {
    "\{body}\n\n\{@shell.source_write_denial_feedback()}"
  } else {
    body
  }
  @agent_tool.ToolAction::respond(content, is_error~)
}
