///|
/// Render this single-session result as Markdown.
pub fn EvalResult::markdown(self : EvalResult) -> String {
  self.as_report().markdown()
}

///|
/// Render this single-session result as standalone HTML.
pub fn EvalResult::html(self : EvalResult) -> String {
  self.as_report().html()
}

///|
/// Render this single-session result as JSON for tooling.
pub fn EvalResult::to_json(self : EvalResult) -> Json {
  {
    "session_id": self.session_id,
    "success": self.success,
    "reason": self.reason,
    "warnings": self.warnings,
    "steps": self.steps,
    "tool_results": self.tool_results,
    "tool_errors": self.tool_errors,
    "shell_uses": self.shell_uses,
    "shell_failures": self.shell_failures,
    "runtime_notices": self.runtime_notices,
    "finished": self.finished,
    "finish_message": self.finish_message,
    "terminal_status": self.terminal_status,
    "terminal_message": self.terminal_message,
  }
}

///|
/// Write `report.md`, `report.html`, and `report.json` under `out_dir`.
pub async fn EvalResult::write_files(
  self : EvalResult,
  out_dir : String,
) -> Unit {
  @report.write_files(
    out_dir,
    self.markdown(),
    self.to_json(),
    html=self.html(),
  )
}

///|
fn EvalResult::as_report(self : EvalResult) -> @report.Report {
  Report(
    title="Session Eval Result: " + empty_dash(self.session_id),
    summary=[
      Metric(name="session", value=empty_dash(self.session_id)),
      Metric(name="result", value=if self.success { "pass" } else { "fail" }),
      Metric(name="reason", value=self.reason),
      Metric(name="terminal", value=empty_dash(self.terminal_status)),
    ],
    metric_columns=[
      "Steps", "Tool Results", "Tool Errors", "Shell Uses", "Shell Failures", "Runtime Notices",
      "Finished",
    ],
    rows=[
      ReportRow(
        index=1,
        name=empty_dash(self.session_id),
        success=self.success,
        reason=self.reason,
        warnings=self.warnings,
        metrics=[
          Metric(name="Steps", value=self.steps.to_string()),
          Metric(name="Tool Results", value=self.tool_results.to_string()),
          Metric(name="Tool Errors", value=self.tool_errors.to_string()),
          Metric(name="Shell Uses", value=self.shell_uses.to_string()),
          Metric(name="Shell Failures", value=self.shell_failures.to_string()),
          Metric(name="Runtime Notices", value=self.runtime_notices.to_string()),
          Metric(name="Finished", value=self.finished.to_string()),
        ],
        details=[
          Metric(name="Finish Message", value=self.finish_message),
          Metric(name="Terminal Message", value=self.terminal_message),
        ],
      ),
    ],
  )
}

///|
fn empty_dash(value : String) -> String {
  if value == "" {
    "-"
  } else {
    value
  }
}
