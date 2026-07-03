///|
/// Default cap on automatic goal continuations per `run_goal_in_scope` call.
/// A safety valve independent of the token budget: unattended loops stop
/// even when the model neither finishes nor blocks and no budget was set.
pub const DEFAULT_MAX_CONTINUATIONS : Int = 25

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
  max_steps? : Int = default_max_steps,
  max_continuations? : Int = DEFAULT_MAX_CONTINUATIONS,
  thinking? : @deepseek.ThinkingMode = Max,
  api_url? : String,
) -> @agent_session.Session {
  let goal_cell = @goal_tool.GoalCell()
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
  let mut session = run_opened_turn_in_scope(
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
    if snapshot.budget_exhausted() {
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
  append_item(session, Goal(limited))
}
