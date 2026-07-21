///|
/// Wall deadline for one gate audit: a reviewer that has not reported in
/// ten minutes is stuck, not thorough.
const GateDeadlineMs : Int = 600_000

///|
/// Whether `--review-gate` was passed: the advisory goal-met audit is
/// opt-in while its precision is being calibrated on dogfood runs.
fn review_gate_enabled(matches : @argparse.Matches) -> Bool {
  matches is { flags: { "review-gate": true, .. }, .. }
}

///|
/// Parse-and-validate the audit child's report line — the same contract the
/// child's submit tool enforced, re-checked at the trust boundary.
fn parse_audit_report(
  json : Json,
) -> Result[@agent_review.ReviewReport, String] {
  match @agent_review.ReviewReport::parse(json) {
    Err(msg) => Err(msg)
    Ok(report) => {
      let problems = report.validate()
      if problems.length() > 0 {
        Err(problems.join("; "))
      } else {
        Ok(report)
      }
    }
  }
}

///|
/// Build the advisory goal-met gate: on a durably recorded met, spawn the
/// `subrun review` child against the goal's baseline and return the bounded
/// digest notice. Advisory by contract — every failure shape (budget
/// exhausted, no report, timeout, spawn trouble) degrades to an
/// `[review] unavailable` notice; only external cancellation re-raises
/// (through run_subrun's own contract).
fn build_goal_met_gate(
  self_exe~ : String,
  model~ : @deepseek.Model,
  api_url~ : String?,
  budget~ : @agent_subrun.SubrunBudget,
  workspace_root~ : String,
) -> async (String, @agent_session.GoalBaseline?) -> String? {
  (goal, baseline) => {
    guard budget.reserve(@agent_review.default_audit_max_steps)
      is Some(granted_steps) else {
      return Some(
        "[review] unavailable: subrun budget exhausted for this turn — the met claim is unaudited.",
      )
    }
    let args = [
      "subrun",
      "review",
      "--model",
      "\{model}",
      "--max-steps",
      "\{granted_steps}",
    ]
    if api_url is Some(url) {
      args.push("--api-url")
      args.push(url)
    }
    let input : Json = match baseline {
      Some(baseline) =>
        { "goal": goal, "sha": baseline.sha, "dirty": baseline.dirty }
      None => { "goal": goal }
    }
    let result = @agent_subrun.run_subrun(
      command=self_exe,
      args~,
      input~,
      parse_report=parse_audit_report,
      wall_deadline_ms=GateDeadlineMs,
      kind="review",
      label=@agent_tool.brief_line(goal, limit=48),
      cwd=workspace_root,
    )
    budget.reconcile(reserved=granted_steps, used=result.steps_used())
    match result.value() {
      Some(report) => Some(report.digest())
      None =>
        Some(
          "[review] unavailable (\{to_repr(result.terminal())}) — treat the met claim as unaudited.",
        )
    }
  }
}

///|
/// The `--review-gate` flag, shared by `run` and `serve`.
fn review_gate_flag() -> @argparse.FlagArg {
  FlagArg(
    "review-gate",
    long="review-gate",
    about="On goal(met), audit the worktree against the goal with a review subagent and inject the findings as an advisory notice.",
  )
}
