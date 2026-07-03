///|
/// Default cap on automatic goal continuations per `run_goal_in_scope` call.
/// A safety valve independent of the token budget: unattended loops stop
/// even when the model neither finishes nor blocks and no budget was set.
pub const DEFAULT_MAX_CONTINUATIONS : Int = 25

///|
/// Default host-level token ceiling for goal runs whose goal carries no
/// explicit budget. Unattended auto-continuation without a budget is the
/// one way this feature can burn unbounded spend, so unbudgeted goals stop
/// here. A goal with an explicit budget is governed by that budget alone.
pub const DEFAULT_GOAL_TOKEN_BUDGET : Int = 1_000_000

///|
/// Whether the goal has spent its governing budget: the goal's own budget
/// when set, otherwise the host ceiling.
fn goal_over_budget(
  snapshot : @agent_session.GoalSnapshot,
  host_token_budget : Int,
) -> Bool {
  match snapshot.goal().token_budget() {
    Some(_) => snapshot.budget_exhausted()
    None => snapshot.tokens_used() >= host_token_budget
  }
}

///|
/// Whether the session's last event is a cleanly finished turn. The goal
/// loop only continues after `Terminal(Finished)`: aborted, interrupted,
/// and failed turns stop the run and leave the goal for the user.
fn last_turn_finished(session : @agent_session.Session) -> Bool {
  let events = session.events()
  guard events.length() > 0 else { return false }
  events[events.length() - 1].item() is Terminal(Finished(_))
}

///|
/// Run one user turn, then keep starting automatic goal turns while the
/// session's goal stays active — the OpenSeek analog of Codex's goal
/// runtime (docs/plans/goal_feature_plan.md, phase 3).
///
/// Each continuation opens with a hidden internal-context item (source
/// `goal`) rendered from the continuation template: objective, budget
/// numbers, fidelity rules, the completion audit, and the blocked audit.
/// The turn itself runs exactly like a user turn, with the same tools.
///
/// Stop conditions, in the order they are checked after every turn:
/// - the turn did not end `Terminal(Finished)` (abort/interrupt/failure);
/// - no goal exists (the model never called `create_goal`);
/// - the goal is no longer active (`update_goal` complete/blocked);
/// - the token budget is exhausted — the host appends the `BudgetLimited`
///   transition itself and stops;
/// - `max_continuations` automatic turns already ran (the goal stays
///   active; a later run may resume it).
pub async fn[X] run_goal_in_scope(
  runtime : @agent_runtime.AgentRuntime,
  scope : @agent_runtime.AgentTaskScope[X],
  api_key : String,
  model : @deepseek.Model,
  session : @agent_session.Session,
  task : String,
  append_item~ : async (@agent_session.Session, @agent_session.SessionItem) -> @agent_session.Session,
  objective? : String,
  token_budget? : Int,
  max_steps? : Int = default_max_steps,
  max_continuations? : Int = DEFAULT_MAX_CONTINUATIONS,
  host_token_budget? : Int = DEFAULT_GOAL_TOKEN_BUDGET,
  thinking? : @deepseek.ThinkingMode = Max,
  api_url? : String,
) -> @agent_session.Session {
  // Host-created goal (`--goal`): the user set the objective directly, so
  // the goal exists before the first turn instead of waiting for the model
  // to call create_goal. Resuming a session whose goal is still unfinished
  // or blocked keeps that goal: the new objective text is ignored in favor
  // of continuing what was started (log records the resume).
  let mut session = session
  if objective is Some(text) {
    match session.current_goal() {
      Some(snapshot) if snapshot.is_active() || snapshot.goal().is_unfinished() => {
        @xlog.info() <?
          {
            "event": "goal_resumed",
            "goal_id": snapshot.goal().goal_id(),
            "status": goal_status_text(snapshot.goal().status()),
          }
        // A budget-limited goal resumes as active: the user explicitly
        // re-ran with --goal, which is the re-funding decision.
        if !snapshot.is_active() {
          let goal = snapshot.goal()
          let reactivated = @agent_session.GoalUpdate(
            goal_id=goal.goal_id(),
            objective=goal.objective(),
            status=Active,
            token_budget?,
          ) catch {
            error =>
              return append_item(
                session,
                Terminal(Failed("goal resume failed: \{error}")),
              )
          }
          session = append_item(session, Goal(reactivated))
        }
      }
      _ => {
        let update = @agent_session.GoalUpdate(
          goal_id="goal-\{count_goal_events(session) + 1}",
          objective=text,
          status=Active,
          token_budget?,
        ) catch {
          error =>
            return append_item(
              session,
              Terminal(Failed("invalid goal: \{error}")),
            )
        }
        session = append_item(session, Goal(update))
        @xlog.info() <?
          {
            "event": "goal_created",
            "goal_id": update.goal_id(),
            "objective": update.objective(),
          }
      }
    }
  }
  let goal_cell = @goal_tool.GoalCell()
  goal_cell.set_host_token_budget(Some(host_token_budget))
  refresh_goal_cell(goal_cell, session)
  let tools = tool_definitions(runtime, scope, goal_cell~) catch {
    error => {
      let next = append_item(
        session,
        Terminal(Failed("agent setup failed: \{error}")),
      )
      @xlog.error() <? { "event": "agent_setup_failed", "error": "\{error}" }
      return next
    }
  }
  let has_plan_tool = tools.find("plan") is Some(_)
  // A resumed goal that is already over its governing budget gets no model
  // call at all: record the stop and return before the first turn.
  if session.current_goal() is Some(pre) &&
    pre.is_active() &&
    goal_over_budget(pre, host_token_budget) {
    return mark_budget_limited(pre, session, append_item~)
  }
  session = run_opened_turn_in_scope(
    runtime,
    scope,
    api_key,
    model,
    session,
    User(UserMessage(task)),
    append_item~,
    max_steps~,
    thinking~,
    api_url?,
    tools~,
    goal_cell~,
  )
  for continuation in 0..<max_continuations {
    guard last_turn_finished(session) else { return session }
    guard session.current_goal() is Some(snapshot) else { return session }
    guard snapshot.is_active() else { return session }
    if goal_over_budget(snapshot, host_token_budget) {
      session = mark_budget_limited(snapshot, session, append_item~)
      refresh_goal_cell(goal_cell, session)
      return session
    }
    let goal = snapshot.goal()
    let prompt = @prompt.goal_continuation_prompt(
      objective=goal.objective(),
      tokens_used=snapshot.tokens_used(),
      token_budget?=goal.token_budget(),
      has_plan_tool~,
    )
    let opening : @agent_session.SessionItem = Internal(
      InternalContext(source="goal", prompt),
    ) catch {
      // "goal" is a statically valid source; construction cannot fail.
      error => {
        @xlog.error() <?
          { "event": "goal_continuation_failed", "error": "\{error}" }
        return session
      }
    }
    @xlog.info() <?
      {
        "event": "goal_continuation",
        "goal_id": goal.goal_id(),
        "continuation": continuation + 1,
        "tokens_used": snapshot.tokens_used(),
      }
    session = run_opened_turn_in_scope(
      runtime,
      scope,
      api_key,
      model,
      session,
      opening,
      append_item~,
      max_steps~,
      thinking~,
      api_url?,
      tools~,
      goal_cell~,
    )
  }
  if session.current_goal() is Some(snapshot) && snapshot.is_active() {
    // Budget beats the cap: if the final allowed continuation crossed the
    // governing budget, the durable outcome is BudgetLimited, not a goal
    // left silently active.
    if goal_over_budget(snapshot, host_token_budget) {
      return mark_budget_limited(snapshot, session, append_item~)
    }
    @xlog.warn() <?
      {
        "event": "goal_continuations_exhausted",
        "goal_id": snapshot.goal().goal_id(),
        "max_continuations": max_continuations,
      }
  }
  session
}

///|
/// Record the host-side budget stop: append the `BudgetLimited` transition
/// for the active goal. The objective was not met; `create_goal` refuses to
/// replace an unfinished goal, so the outcome stays visible to the user.
async fn mark_budget_limited(
  snapshot : @agent_session.GoalSnapshot,
  session : @agent_session.Session,
  append_item~ : async (@agent_session.Session, @agent_session.SessionItem) -> @agent_session.Session,
) -> @agent_session.Session {
  let goal = snapshot.goal()
  let limited = @agent_session.GoalUpdate(
    goal_id=goal.goal_id(),
    objective=goal.objective(),
    status=BudgetLimited,
    token_budget?=goal.token_budget(),
  ) catch {
    // The fields round-trip from an already-validated goal; construction
    // cannot fail, but the constructor's contract is explicit.
    error => {
      @xlog.error() <?
        { "event": "goal_budget_limit_failed", "error": "\{error}" }
      return session
    }
  }
  @xlog.warn() <?
    {
      "event": "goal_budget_exhausted",
      "goal_id": goal.goal_id(),
      "tokens_used": snapshot.tokens_used(),
    }
  let session = append_item(session, Goal(limited))
  // A durable, model-visible notice: Goal events are hidden metadata, so
  // without this a resumed transcript would end on an ordinary answer with
  // no explanation of why the loop stopped.
  let notice : @agent_session.SessionItem = Internal(
    InternalContext(
      source="goal",
      {
        let cause = match goal.token_budget() {
          Some(budget) => "its token budget of \{budget} is exhausted"
          None => "the host token ceiling for unbudgeted goals is exhausted"
        }
        (
          $|The goal \{goal.goal_id()} was stopped by the host: \{cause} (\{snapshot.tokens_used()} tokens used). The objective was not completed. Re-running with --goal re-funds and resumes it.
        )
      },
    ),
  ) catch {
    error => {
      @xlog.error() <?
        { "event": "goal_budget_notice_failed", "error": "\{error}" }
      return session
    }
  }
  append_item(session, notice)
}

///|
/// Like `run_turn_with_append`, but goal-aware: owns a fresh runtime and
/// task group, then drives `run_goal_in_scope` (one user turn plus automatic
/// goal continuations) with every committed event persisted through
/// `append_item`. `objective` host-creates (or resumes) the goal up front —
/// the `--goal` CLI path.
pub async fn run_goal_with_append(
  api_key : String,
  model : @deepseek.Model,
  session : @agent_session.Session,
  task : String,
  append_item~ : async (@agent_session.Session, @agent_session.SessionItem) -> @agent_session.Session,
  objective? : String,
  token_budget? : Int,
  max_steps? : Int = default_max_steps,
  max_continuations? : Int = DEFAULT_MAX_CONTINUATIONS,
  host_token_budget? : Int = DEFAULT_GOAL_TOKEN_BUDGET,
  thinking? : @deepseek.ThinkingMode = Max,
  api_url? : String,
  workspace_root? : String = ".",
) -> @agent_session.Session {
  @async.with_task_group() <| group => {
    run_goal_in_scope(
      AgentRuntime(workspace_root~),
      AgentTaskScope(group),
      api_key,
      model,
      session,
      task,
      append_item~,
      objective?,
      token_budget?,
      max_steps~,
      max_continuations~,
      host_token_budget~,
      thinking~,
      api_url?,
    )
  }
}
