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
  let api_key = api_key(matches)
  let api_url = api_url(matches)
  let model = @deepseek.Model::parse(value(matches, "model"))
  let max_steps = max_steps(matches)
  let thinking = @deepseek.ThinkingMode::parse(value(matches, "thinking"))
  let base = value(matches, "base")
  let report = @agent_review.run_review(
    api_key,
    model,
    base,
    workspace_root~,
    max_steps~,
    thinking~,
    api_url?,
  ) catch {
    error => {
      @stdio.stderr.write("review failed: \{error}\n")
      @sys.exit(1)
      return
    }
  }
  @stdio.stdout.write(report.to_json_string() + "\n")
  let blockers = report.findings.filter(f => f.severity == "blocker").length()
  if blockers > 0 {
    @sys.exit(2)
  }
}
