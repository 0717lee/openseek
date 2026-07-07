///|
let default_max_steps : Int = 1000

///|
/// Model requests since the last successful `plan` call — and since the last
/// reminder — before the loop injects a plan staleness reminder. Both
/// thresholds mirror the 10-turn / 10-turn cadence Claude Code uses for its
/// todo reminder: long enough that short tasks never see a nag, and the
/// second threshold caps re-nagging of a model that ignores the first at
/// once per ten requests.
let plan_reminder_after_steps : Int = 10

///|
/// The staleness reminder injected when the `plan` tool has gone unused for
/// `plan_reminder_after_steps` model requests. With a known current plan the
/// reminder re-surfaces it — the last plan call may sit dozens of steps back
/// in context — and otherwise it nudges once toward recording a plan, while
/// staying explicit that trivial work should ignore it.
fn plan_reminder_text(checklist : String?) -> String {
  match checklist {
    Some(lines) =>
      (
        $|[plan reminder]
        $|The plan tool has not been called in a while. If progress was made,
        $|update step statuses; if the plan no longer matches the work,
        $|replace it or clear it with steps: []. Current plan:
        $|\{lines}
      )
    None =>
      (
        #|[plan reminder]
        #|The plan tool has not been used in this turn. If this task takes
        #|several distinct steps, record a plan with the plan tool and keep
        #|step statuses current. If not, ignore this reminder.
      )
  }
}

///|
/// Plan staleness tracking for one turn. When the plan tool is registered,
/// counters advance once per model request. A successful `plan` call resets
/// `steps_since_plan` and refreshes `checklist`; injecting a reminder resets
/// `steps_since_reminder`, so the reminder fires only after both enough plan
/// silence and enough reminder silence. Turn-local by design — a fresh user
/// turn resets the cadence. `checklist` carries the last successfully recorded
/// plan for the reminder to re-surface.
priv struct PlanCadence {
  registered : Bool
  mut steps_since_plan : Int
  mut steps_since_reminder : Int
  mut checklist : String?
}

///|
fn PlanCadence::PlanCadence(registered~ : Bool) -> PlanCadence {
  { registered, steps_since_plan: 0, steps_since_reminder: 0, checklist: None }
}

///|
fn PlanCadence::should_remind(self : Self) -> Bool {
  self.registered &&
  self.steps_since_plan >= plan_reminder_after_steps &&
  self.steps_since_reminder >= plan_reminder_after_steps
}

///|
fn PlanCadence::reminder_text(self : Self) -> String {
  plan_reminder_text(self.checklist)
}

///|
fn PlanCadence::record_reminder(self : Self) -> Unit {
  self.steps_since_reminder = 0
}

///|
fn PlanCadence::record_model_request(self : Self) -> Unit {
  if self.registered {
    self.steps_since_plan += 1
    self.steps_since_reminder += 1
  }
}

///|
fn PlanCadence::record_plan_success(
  self : Self,
  tool_call : @agent_tool.AgentToolCall,
  output : @agent_tool.ToolOutput,
) -> Unit {
  if self.registered && tool_call.name == "plan" && !output.is_error {
    self.steps_since_plan = 0
    self.checklist = @plan.reminder_checklist(tool_call.arguments)
  }
}

///|
/// Run a one-shot OpenSeek task and discard the returned session.
///
/// This is the highest-level convenience entry point. It creates a fresh
/// in-memory session with id `"one-shot"`, appends `task` as the first user
/// event, runs the agent loop, logs progress through the configured process
/// logger, and returns `Unit`. It does not persist the session and does not
/// expose the final `Session` value to the caller.
///
/// `system_prompt_text` is required. Prompt selection is intentionally owned by
/// the application layer, not by `agent`; this package does not depend on the
/// `prompt` package. `thinking` defaults to `Max`. `workspace_root` defaults to
/// `"."` and is passed into the per-turn `AgentRuntime`; local file and shell
/// tools resolve relative paths against that root. `api_url` is forwarded to
/// the DeepSeek client and is mainly useful for tests or compatible endpoints.
///
/// Use `run_turn_with_append` when every committed event must be persisted as
/// the turn progresses, or `run_turn_in_scope` when runtime/tool state must span
/// turns.
pub async fn run(
  api_key~ : String,
  model~ : @deepseek.Model,
  task~ : String,
  system_prompt_text~ : String,
  max_steps? : Int = default_max_steps,
  thinking? : @deepseek.ThinkingMode = Max,
  api_url? : String,
  workspace_root? : String = ".",
) -> Unit {
  let session = @agent_session.Session(
    SessionId("one-shot"),
    system_prompt=system_prompt_text,
  )
  ignore(
    run_turn_with_append(
      api_key~,
      model~,
      session~,
      task~,
      append_item=(session, item) => session.append(item),
      max_steps~,
      thinking~,
      api_url?,
      workspace_root~,
    ),
  )
}

///|
/// Runs one user turn and calls `append_item` for every session event as soon as
/// it is committed. This lets a filesystem-backed caller preserve progress even
/// if the engine process exits later in the turn.
///
/// This is the persistence hook for one-shot and CLI session recording. The
/// callback receives the current session snapshot and the next `SessionItem`;
/// it must return the new session snapshot after appending that item. The agent
/// uses the returned value as the current session for all later work, so the
/// callback is the single source of truth for sequencing.
///
/// `append_item` is called for the initial user task, every assistant/tool/
/// runtime/steer event that is committed, and the terminal event. If the
/// callback raises, the turn attempts to append a failure terminal describing
/// that append failure and then re-raises the original error. This means a
/// durable store can preserve the partial turn up to the failure point.
///
/// This owns a fresh runtime, task group, and tool registry for the duration of
/// one turn. Use `run_turn_in_scope` when the caller needs to preserve runtime
/// state or tool state across turns.
pub async fn run_turn_with_append(
  api_key~ : String,
  model~ : @deepseek.Model,
  session~ : @agent_session.Session,
  task~ : String,
  append_item~ : async (@agent_session.Session, @agent_session.SessionItem) -> @agent_session.Session,
  max_steps? : Int = default_max_steps,
  thinking? : @deepseek.ThinkingMode = Max,
  api_url? : String,
  workspace_root? : String = ".",
) -> @agent_session.Session {
  @async.with_task_group() <| group => {
    run_turn_in_scope(
      runtime=AgentRuntime(workspace_root~),
      scope=AgentTaskScope(group),
      api_key~,
      model~,
      session~,
      task~,
      append_item~,
      max_steps~,
      thinking~,
      api_url?,
    )
  }
}

///|
async test "run_turn_with_append closes failed persisted turns" {
  let initial = @agent_session.Session(SessionId("s1"), system_prompt="system")
  let mut calls = 0
  let mut persisted = initial
  let _ = run_turn_with_append(
    api_key="unused",
    model=Deepseek(V4Pro),
    session=initial,
    task="hello",
    append_item=(session, item) => {
      calls = calls + 1
      if calls == 2 {
        fail("persist terminal failed")
      }
      let next = session.append(item)
      persisted = next
      next
    },
    max_steps=0,
  ) catch {
    error => {
      assert_true("\{error}".contains("persist terminal failed"))
      assert_eq(calls, 3)
      let events = persisted.events()
      assert_eq(events.length(), 2)
      assert_true(events[0].item() is User(_))
      guard events[1].item() is Terminal(Failed(message)) else {
        fail("expected failed terminal")
      }
      assert_true(message.contains("persist terminal failed"))
      return
    }
  }
  fail("expected failed append to be re-raised")
}

///|
/// Runs one user turn inside a caller-owned runtime and task scope.
///
/// This is the building block for callers that keep an engine alive across
/// turns (serve mode): the shared `runtime` carries steering input across the
/// turn boundary, and a `tools` registry can be built once with `build_tools`
/// and reused across turns. When `tools` is
/// omitted a fresh registry is built for this turn only. `scope` bounds
/// background work the turn's tools spawn, so it must outlive every turn that
/// may have spawned some. One-shot callers should prefer `run` or
/// `run_turn_with_append`, which own everything for the duration of a single
/// turn.
///
/// The loop appends `task` as a user message before the first model request.
/// At each step boundary it first drains and applies pending non-blank steers.
/// When the registry includes the `plan` tool and
/// `plan_reminder_after_steps` model requests pass without a successful
/// `plan` call, the loop also injects a durable plan staleness reminder that
/// re-surfaces the recorded plan (rate-limited by the same threshold). It
/// sends the current DeepSeek chat projection with the active tool schemas,
/// records assistant responses, executes tool calls in order, and records
/// tool results. The turn ends when the model answers with no tool calls, the
/// `finish` tool returns `Control(Finish)`, a tool returns `Control(Abort)`,
/// `max_steps` is exhausted, the task is cancelled, or an unexpected error
/// escapes.
///
/// A steer that arrives while the model's apparent final answer or a `finish`
/// tool call is in flight keeps the turn alive. The would-be final answer is
/// stored as an ordinary assistant message, or the finish batch is closed with
/// tool-result messages, then the steer is appended and the loop continues.
///
/// `tools` should normally be a registry built once with `build_tools(runtime,
/// scope)` for a long-lived engine. If `tools` is omitted, this function builds
/// a fresh registry for this call only. `api_url` is forwarded to the DeepSeek
/// client. The caller owns the lifetime of `runtime`, `scope`, and any shared
/// `tools` registry passed here.
pub async fn[X] run_turn_in_scope(
  runtime~ : @agent_runtime.AgentRuntime,
  scope~ : @agent_runtime.AgentTaskScope[X],
  api_key~ : String,
  model~ : @deepseek.Model,
  session~ : @agent_session.Session,
  task~ : String,
  append_item~ : async (@agent_session.Session, @agent_session.SessionItem) -> @agent_session.Session,
  max_steps? : Int = default_max_steps,
  thinking? : @deepseek.ThinkingMode = Max,
  api_url? : String,
  tools? : @agent_tool.Tools,
) -> @agent_session.Session {
  let client = @client.Client(api_key~, model~, thinking~, api_url?)
  let session = session |> append_item(User(UserMessage(task)))
  let tools = tools.unwrap_or_else(() => build_tools(runtime, scope)) catch {
    error => {
      @xlog.error() <? { "event": "agent_setup_failed", "error": "\{error}" }
      return session
        |> append_item(Terminal(Failed("agent setup failed: \{error}")))
    }
  }
  AgentLoop(runtime~, client~, tools~, append_item~, session~).run(
    session, max_steps,
  )
}

///|
/// Queued steering input worth applying: drained losslessly, blanks dropped.
fn @agent_runtime.AgentRuntime::pending_steers(
  runtime : Self,
) -> Array[@agent_runtime.SteerInput] {
  [
    for input in runtime.drain_steers() if input
    is (Prompt(text) | Command(text)) &&
    !text.trim().is_empty() => input
  ]
}

///|
/// Fold steering input into the conversation: each becomes a durable user
/// message and a model-visible chat message. Both variants emit
/// `steer_applied`; the `kind` field distinguishes prompt steering from
/// command context.
async fn @agent_session.Session::apply_steer_inputs(
  session : Self,
  inputs : Array[@agent_runtime.SteerInput],
  messages : Array[@deepseek.ChatMessage],
  append_item~ : async (@agent_session.Session, @agent_session.SessionItem) -> @agent_session.Session,
) -> Self {
  for input in inputs; current = session {
    let (kind, text) = match input {
      Prompt(text) => ("prompt", text)
      Command(text) => ("command", text)
    }
    let next = append_item(current, User(UserMessage(text)))
    messages.push(ChatMessage(User, content=text))
    @xlog.info() <? { "event": "steer_applied", "kind": kind, "content": text }
    continue next
  } nobreak {
    current
  }
}

///|
fn print_usage(usage : @deepseek.Usage) -> Unit {
  @xlog.info() <? { "event": "usage", "usage": usage }
}
