///|
/// Raised when a review run fails for an infrastructure reason (e.g. the model
/// finished without producing a structured report), as opposed to completing
/// with findings.
pub suberror ReviewError {
  ReviewError(String)
}

///|
/// Default step budget for one review run.
pub let default_review_max_steps : Int = 120

///|
/// Run a code review of the changes between `base` and HEAD and return the
/// structured report. The toolset is `read`, `shell` (in read-only mode), and
/// `submit_review` — no edit/multi_edit/write — so the review reports rather
/// than edits. Read-only is best-effort: the shell refuses obvious
/// source-mutating moon commands, but `moon check`/`moon test` may still trigger
/// pre-build source generation, so the checkout is not guaranteed byte-for-byte
/// unchanged. Raises `ReviewError` if the model finishes without submitting a
/// report.
///
/// Runs on the `@agent_subrun` substrate: an ephemeral child session whose
/// report is captured through the `submit_review` control tool. The child's
/// events go to the process log as before (the review CLI installs a
/// discarding handler; a future in-session gate passes an isolating sink and
/// a wall deadline instead).
pub async fn run_review(
  api_key : String,
  model : @deepseek.Model,
  base : String,
  workspace_root? : String = ".",
  max_steps? : Int = default_review_max_steps,
  thinking? : @deepseek.ThinkingMode = Max,
  api_url? : String,
) -> ReviewReport {
  let result = @agent_subrun.run_subrun(
    {
      session_id: "review",
      system_prompt: review_system_prompt(),
      task: review_task(base),
      tools: captured => {
        @agent_tool.Tools([
          @read.definition(workspace_root~),
          @shell.definition(workspace_root~, read_only=true),
          submit_review_tool(captured),
        ])
      },
      max_steps,
      wall_deadline_ms: None,
    },
    api_key~,
    model~,
    thinking~,
    api_url?,
    workspace_root~,
    event_sink=@emit.EventSink::global(),
  )
  match result.value() {
    Some(report) => report
    None =>
      raise ReviewError(
        "review finished without calling submit_review (no structured report)",
      )
  }
}
