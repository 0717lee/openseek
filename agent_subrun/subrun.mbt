///|
/// `agent_subrun` runs one nested, ephemeral agent turn — a sub-run — with a
/// restricted toolset and a structured result captured through a submit-style
/// control tool. It is the substrate under every specialized subagent surface
/// (the review engine today; explore and the goal-review gate next): fresh
/// session, caller-chosen tools, bounded steps and wall clock, and event
/// isolation so a child's lifecycle events cannot masquerade as the outer
/// run's.

///|
/// How a sub-run ended. External cancellation is deliberately NOT a terminal:
/// it re-raises out of `run_subrun` so structured concurrency sees it, per
/// the engine-wide rule that cancellation is never folded into an ordinary
/// failure.
pub(all) enum SubrunTerminal {
  /// The capture tool sealed the run with a valid value. Also reported when
  /// a value landed just before the wall deadline cut the turn: the value
  /// is usable either way.
  Captured
  /// The child ended (final answer or finish) without ever capturing.
  NoReport
  /// The child exhausted its step budget without capturing.
  MaxSteps
  /// The child yielded at its context ceiling without capturing.
  ContextYield
  /// The runner-owned wall deadline cancelled the child internally. Unlike
  /// external cancellation this is absorbed here: the deadline belongs to
  /// the sub-run, not the caller.
  TimedOut
  /// The child raised a non-cancellation error (API failure, setup failure).
  Failed(String)
} derive(Debug, Eq)

///|
/// The outcome of one sub-run: the captured value when there is one, plus
/// the cost actually spent — steps and provider tokens — for budget
/// reconciliation and eval attribution. Costs are observed from the child's
/// own event stream, so they are exact for the requests the child made.
pub struct SubrunResult[T] {
  value : T?
  terminal : SubrunTerminal
  steps_used : Int
  prompt_tokens : Int
  completion_tokens : Int
} derive(Debug)

///|
/// The captured value, when the child submitted one.
pub fn[T] SubrunResult::value(self : SubrunResult[T]) -> T? {
  self.value
}

///|
/// How the sub-run ended.
pub fn[T] SubrunResult::terminal(self : SubrunResult[T]) -> SubrunTerminal {
  self.terminal
}

///|
/// Model requests the child actually made.
pub fn[T] SubrunResult::steps_used(self : SubrunResult[T]) -> Int {
  self.steps_used
}

///|
/// Provider prompt tokens the child consumed, summed over its requests.
pub fn[T] SubrunResult::prompt_tokens(self : SubrunResult[T]) -> Int {
  self.prompt_tokens
}

///|
/// Provider completion tokens the child consumed, summed over its requests.
pub fn[T] SubrunResult::completion_tokens(self : SubrunResult[T]) -> Int {
  self.completion_tokens
}

///|
/// One sub-run's static shape. `tools` receives the capture ref that
/// `run_subrun` owns and must build the FULL child registry around it —
/// handing the same ref to a `capture_tool` — so the tool registry and the
/// result channel cannot disagree.
pub(all) struct SubrunSpec[T] {
  /// Session id for the ephemeral child session (never persisted).
  session_id : String
  system_prompt : String
  task : String
  /// Builds the child's toolset around the runner-owned capture ref.
  tools : (Ref[T?]) -> @agent_tool.Tools raise
  /// Step ceiling for the child turn.
  max_steps : Int
  /// Runner-owned wall deadline in milliseconds; on expiry the child is
  /// cancelled internally and the run reports `TimedOut`. `None` runs
  /// without a deadline (the standalone review CLI's historical behavior);
  /// in-session sub-runs should always set one.
  wall_deadline_ms : Int?
}

///|
/// Sightings the accounting sink collects from the child's event stream.
priv struct SubrunObservations {
  mut steps : Int
  mut prompt_tokens : Int
  mut completion_tokens : Int
  mut max_steps_exhausted : Bool
  mut context_yield : Bool
  mut failure : String?
}

///|
/// Wrap the caller's sink with cost/terminal accounting. Every child event
/// passes through here; `forward` (default: drop everything) decides what,
/// if anything, the host stream sees. Dropping is the safe default — a
/// child's `AgentFinished` in the host stream reads as the OUTER run's
/// terminal.
fn observing_sink(
  observations : SubrunObservations,
  forward : @emit.EventSink,
) -> @emit.EventSink {
  @emit.EventSink((event, loc) => {
    match event {
      @protocol.AgentStep(step~) =>
        if step > observations.steps {
          observations.steps = step
        }
      @protocol.Usage(usage~) => {
        observations.prompt_tokens += usage.prompt_tokens
        observations.completion_tokens += usage.completion_tokens
      }
      @protocol.MaxStepsExhausted => observations.max_steps_exhausted = true
      @protocol.ContextYield(..) => observations.context_yield = true
      @protocol.TurnFailed(error~) | @protocol.AgentSetupFailed(error~) =>
        observations.failure = Some(error)
      @protocol.AgentAborted(reason~) => observations.failure = Some(reason)
      _ => ()
    }
    forward.emit(event, loc~)
  })
}

///|
/// A sink that drops every event: the default isolation for a sub-run.
pub fn suppressing_sink() -> @emit.EventSink {
  @emit.EventSink((_event, _loc) => ())
}

///|
/// Run one sub-run to completion and report what happened and what it cost.
///
/// The child gets a fresh in-memory session (never persisted), a fresh
/// runtime (steers cannot cross between parent and child), its own task
/// group, and the toolset `spec.tools` builds around the runner-owned
/// capture ref. `event_sink` is what the HOST stream sees of the child —
/// the default forwards nothing; cost accounting observes the child's
/// events either way.
///
/// Error contract: external cancellation re-raises (never a terminal); the
/// wall deadline is absorbed as `TimedOut`; any other child error becomes
/// `Failed`. A value captured before the deadline cut the turn still
/// reports `Captured`.
pub async fn[T] run_subrun(
  spec : SubrunSpec[T],
  api_key~ : String,
  model~ : @deepseek.Model,
  thinking? : @deepseek.ThinkingMode = Max,
  api_url? : String,
  workspace_root? : String = ".",
  event_sink? : @emit.EventSink = suppressing_sink(),
) -> SubrunResult[T] {
  let captured : Ref[T?] = { val: None }
  let observations = SubrunObservations::{
    steps: 0,
    prompt_tokens: 0,
    completion_tokens: 0,
    max_steps_exhausted: false,
    context_yield: false,
    failure: None,
  }
  let sink = observing_sink(observations, event_sink)
  let tools = (spec.tools)(captured) catch {
    error =>
      return {
        value: None,
        terminal: Failed("subrun toolset failed: \{error}"),
        steps_used: 0,
        prompt_tokens: 0,
        completion_tokens: 0,
      }
  }
  let session = @agent_session.Session(
    @agent_session.SessionId(spec.session_id),
    system_prompt=spec.system_prompt,
  )
  async fn child_turn() -> Unit {
    let _ : @agent_session.Session = @async.with_task_group() <| group => {
      @agent.run_turn_in_scope(
        runtime=@agent_runtime.AgentRuntime(workspace_root~),
        scope=@agent_runtime.AgentTaskScope(group),
        api_key~,
        model~,
        session~,
        task=spec.task,
        append_item=(session, item) => session.append(item),
        max_steps=spec.max_steps,
        thinking~,
        api_url?,
        tools~,
        event_sink=sink,
      )
    }
  }
  // The deadline wraps the whole child turn: on expiry the timeout cancels
  // the child's task group (tearing down any tool subprocesses) and returns
  // None. External cancellation of the caller propagates out of
  // with_timeout_opt untouched. No deadline -> Some(()) unconditionally.
  let completed = try {
    match spec.wall_deadline_ms {
      Some(deadline) => @async.with_timeout_opt(deadline, child_turn)
      None => {
        child_turn()
        Some(())
      }
    }
  } catch {
    error if @async.is_being_cancelled() => raise error
    error =>
      return {
        value: captured.val,
        terminal: match captured.val {
          Some(_) => Captured
          None => Failed("\{error}")
        },
        steps_used: observations.steps,
        prompt_tokens: observations.prompt_tokens,
        completion_tokens: observations.completion_tokens,
      }
  }
  let terminal = match (captured.val, completed) {
    // A captured value is usable even when the deadline cut the turn just
    // after the capture landed.
    (Some(_), _) => Captured
    (None, None) => TimedOut
    (None, Some(_)) =>
      match observations.failure {
        Some(error) => Failed(error)
        None if observations.max_steps_exhausted => MaxSteps
        None if observations.context_yield => ContextYield
        None => NoReport
      }
  }
  {
    value: captured.val,
    terminal,
    steps_used: observations.steps,
    prompt_tokens: observations.prompt_tokens,
    completion_tokens: observations.completion_tokens,
  }
}
