///|
/// A logging handler that drops every entry. Review mode installs it so the
/// agent's progress JSONL does not pollute stdout, which must carry exactly one
/// JSON `ReviewReport`.
priv struct DiscardLog {}

///|
impl @xlog.Handler for DiscardLog with fn handle(
  _self : DiscardLog,
  _entry : @xlog.Entry,
) -> Unit raise {

}

///|
/// Handle `--review`: run a read-only review of `base...HEAD` and print a single
/// JSON `ReviewReport` to stdout. Exit code: 0 (clean or non-blocking findings),
/// 1 (the review failed to produce a report), 2 (blocker findings present).
async fn run_review_cli(
  matches : @argparse.Matches,
  workspace_root~ : String,
) -> Unit {
  let api_url = @agentcli.api_url(matches)
  // Reviews always run on the strongest model; flash is too shallow for the
  // judgement a code review needs, so --model is not consulted here.
  let model = @deepseek.Deepseek(V4Pro)
  let api_key = @agentcli.api_key(matches, model)
  let max_steps = max_steps(matches)
  let (thinking, base) = match matches {
    { values: { "thinking": [thinking, ..], "base": [base, ..], .. }, .. } =>
      (@deepseek.ThinkingMode::parse(thinking), base)
    _ => fail("missing parsed review defaults")
  }
  if base.trim() == "" {
    @stdio.stderr.write("review failed: --base must be a non-empty git ref\n")
    @sys.exit(1)
    return
  }
  let report = @agent_review.run_review(
    api_key,
    model,
    base,
    workspace_root~,
    // Omission means context-bounded here too — uniform with run/serve/TUI.
    // (run_review's own 120 default remains the contract for direct API
    // callers only; before the flip the root flag default 1000 always won.)
    max_steps=max_steps.unwrap_or(@agent.unbounded_max_steps),
    thinking~,
    api_url?,
  ) catch {
    error => {
      @stdio.stderr.write("review failed: \{error}\n")
      // `@sys.exit` never returns at runtime but is typed `Unit`, so this arm
      // still needs a diverging expression to satisfy the report-branch type.
      @sys.exit(1)
      return
    }
  }
  @stdio.stdout.write(report.to_json_string() + "\n")
  if report.findings.any(f => f.severity == "blocker") {
    @sys.exit(2)
  }
}
