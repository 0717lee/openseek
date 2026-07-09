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
pub async fn run_review(
  api_key : String,
  model : @deepseek.Model,
  base : String,
  workspace_root? : String = ".",
  max_steps? : Int = default_review_max_steps,
  thinking? : @deepseek.ThinkingMode = Max,
  api_url? : String,
) -> ReviewReport {
  let captured : Ref[ReviewReport?] = { val: None }
  let tools = @agent_tool.Tools([
    @read.definition(workspace_root~),
    @shell.definition(workspace_root~, read_only=true),
    submit_review_tool(captured),
  ])
  let session = @agent_session.Session(
    @agent_session.SessionId("review"),
    system_prompt=review_system_prompt(),
  )
  let task = review_task(base)
  // Review is read-only and ephemeral; the final session is not persisted.
  let _ : @agent_session.Session = @async.with_task_group() <| group => {
    @agent.run_turn_in_scope(
      runtime=@agent_runtime.AgentRuntime(workspace_root~),
      scope=@agent_runtime.AgentTaskScope(group),
      api_key~,
      model~,
      session~,
      task~,
      append_item=(s, i) => s.append(i),
      max_steps~,
      thinking~,
      api_url?,
      tools~,
    )
  }
  match captured.val {
    Some(report) => report
    None =>
      raise ReviewError(
        "review finished without calling submit_review (no structured report)",
      )
  }
}
