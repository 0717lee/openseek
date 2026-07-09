///|
priv struct AgentLoop {
  runtime : @agent_runtime.AgentRuntime
  client : @client.Client
  /// Client for auto-compaction checkpoint summaries: thinking=No where the
  /// model honors the control — a handoff summary needs no reasoning budget.
  summary_client : @client.Client
  tools : @agent_tool.Tools
  append_item : async (@agent_session.Session, @agent_session.SessionItem) -> @agent_session.Session
  /// Turn-local DeepSeek request buffer. `AgentLoop` is private and per-run; a
  /// later user turn gets a fresh loop seeded from `Session::chat_messages`, not
  /// this array. Updates are append-first: whenever the loop adds a message here
  /// for a newly appended session item, the durable append has already
  /// succeeded.
  messages : Array[@deepseek.ChatMessage]
  plan_cadence : PlanCadence
  /// Latest session returned by a successful append. The run-level error
  /// handler uses it to persist a terminal failure/interruption even when the
  /// local loop state is behind the last durable session.
  mut last_session : @agent_session.Session
}

///|
fn AgentLoop::AgentLoop(
  runtime~ : @agent_runtime.AgentRuntime,
  client~ : @client.Client,
  summary_client~ : @client.Client,
  tools~ : @agent_tool.Tools,
  append_item~ : async (@agent_session.Session, @agent_session.SessionItem) -> @agent_session.Session,
  session~ : @agent_session.Session,
) -> AgentLoop {
  {
    runtime,
    client,
    summary_client,
    tools,
    append_item,
    messages: session.chat_messages(),
    plan_cadence: PlanCadence(registered=tools.find("plan") is Some(_)),
    last_session: session,
  }
}

///|
priv enum FinishOutcome {
  /// The terminal is appended; the turn is over.
  Sealed(@agent_session.Session)
  /// User input arrived during the compact-on-finish checkpoint: the
  /// answer stayed an ordinary assistant message, the steers are applied,
  /// and the turn continues from the compacted projection.
  ContinueTurn(@agent_session.Session)
}

///|
priv enum AgentStepOutcome {
  StepContinue(@agent_session.Session)
  StepDone(@agent_session.Session)
  /// The running batch budget stopped execution: the remainder is already
  /// skip-closed and the turn must yield at the ceiling checkpoint.
  StepYield(@agent_session.Session)
}

///|
priv enum ToolCallOutcome {
  /// The tool returned a normal result; continue executing the remaining calls
  /// in the current assistant tool-call batch.
  ContinueToolBatch(@agent_session.Session)
  /// Stop the current tool batch and let the agent make another model request
  /// with the updated session, without appending a terminal item.
  ContinueAgentLoop(@agent_session.Session)
  /// Stop the current tool batch and finish the agent turn with a terminal
  /// session item already appended.
  FinishAgentLoop(@agent_session.Session)
}

///|
/// Result note for tool calls discarded because the turn is ending at the
/// context ceiling.
let ceiling_skip_note : String = "skipped: the turn is yielding at the context ceiling; re-issue after the checkpoint if still needed"

///|
async fn AgentLoop::run(
  self : Self,
  session : @agent_session.Session,
  max_steps : Int,
) -> @agent_session.Session {
  self.last_session = session
  try {
    for step in 0..<max_steps; session = session {
      let session = self.prepare_step(session)
      let response = self.chat(step)
      // Usage only exists per response, so ceiling pressure is detected at
      // each exit point below by consulting this response's usage — no
      // pressure state exists anywhere, not even across lines: a pressured
      // step always ends the turn within its own iteration. Two tiers: at
      // the SOFT ceiling the turn ends gracefully at this step's boundary
      // (batches still execute, aggregate-budgeted); at the HARD ceiling —
      // or when a soft batch cannot be proven to fit — no batch starts.
      // Abort and error exits stay exempt by policy: failure paths never
      // wait on a checkpoint request.
      if response.tool_calls.is_empty() {
        let steer_inputs = self.runtime.pending_steers()
        if steer_inputs.is_empty() {
          // A true final answer is stored once as Terminal(Finished). Later turns
          // rebuild model context through Session::chat_messages, which projects
          // that terminal back into an assistant message; appending an Assistant
          // session item here would duplicate the answer on replay.
          match
            self.finish_turn(
              session,
              response.content,
              usage=response.usage,
              reasoning_content?=response.optional_reasoning_content(),
            ) {
            Sealed(next) => return next
            ContinueTurn(next) => continue next
          }
        }
        let reasoning_content = response.optional_reasoning_content()
        // The model considers itself done, but user-visible input arrived while the
        // final call was in flight: user input wins over model-initiated completion.
        // The would-be answer stays as an ordinary assistant message and the turn
        // continues with the new input folded in.
        let session = self.append(
          session,
          Assistant(AssistantMessage(response.content, reasoning_content?)),
        )
        self.messages.push(
          ChatMessage(Assistant, content=response.content, reasoning_content?),
        )
        if self.at_soft_context_ceiling(response.usage) {
          // Yield now rather than answering the steer in a starved context;
          // the steers survive the checkpoint verbatim.
          return self.yield_at_context_ceiling(session, steer_inputs)
        }
        let session = self.apply_steer_inputs(session, steer_inputs)
        continue session
      } else if self.at_hard_context_ceiling(response.usage) {
        // Past the hard ceiling the batch never executes: its results
        // could fill the remaining headroom, overflowing the checkpoint
        // request itself. Close every call with a skip note — API-valid, a
        // few bytes — and yield; the checkpoint summary carries the state
        // and the model re-issues the calls next turn if needed.
        let reasoning_content = response.optional_reasoning_content()
        let session = self.append(
          session,
          Assistant(
            AssistantMessage(
              response.content,
              tool_calls=response.tool_calls,
              reasoning_content?,
            ),
          ),
        )
        self.messages.push(
          ChatMessage(
            Assistant,
            content=response.content,
            tool_calls=response.tool_calls,
            reasoning_content?,
          ),
        )
        match self.salvage_finish_at_ceiling(session, response) {
          Some(StepDone(next)) => return next
          // A steer arrived during the salvaged finish's checkpoint: the
          // turn continues from the compacted projection.
          Some(StepContinue(next)) => continue next
          Some(StepYield(next)) =>
            return self.yield_at_context_ceiling(
              next,
              self.runtime.pending_steers(),
            )
          None => ()
        }
        let session = self.close_skipped_tool_calls(
          session,
          response.tool_calls,
          note=ceiling_skip_note,
        )
        return self.yield_at_context_ceiling(
          session,
          self.runtime.pending_steers(),
        )
      } else {
        match self.handle_tool_calls(session, response) {
          // Plain continuation — including after a checkpoint whose late
          // steer converted a finish into a continue: the soft decision
          // lives in handle_tool_calls, which knows the batch's real
          // growth and must not re-fire on stale pre-checkpoint usage.
          StepContinue(next) => continue next
          StepDone(next) => return next
          // The running budget stopped the batch mid-way — at ANY usage
          // level, including below the soft ceiling: a below-threshold
          // response with several large results could otherwise push the
          // next request past the window before any ceiling check runs.
          StepYield(next) =>
            return self.yield_at_context_ceiling(
              next,
              self.runtime.pending_steers(),
            )
        }
      }
    } nobreak {
      let session = self.append(
        session,
        Terminal(Failed("max steps exhausted")),
      )
      @xlog.warn() <? { "event": "max_steps_exhausted" }
      session
    }
  } catch {
    error => {
      let terminal : @agent_session.SessionItem = if @async.is_being_cancelled() ||
        @async.is_cancellation_error(error) {
        Terminal(Interrupted("cancelled"))
      } else {
        Terminal(Failed("agent failed: \{error}"))
      }
      ignore(
        self.append(self.last_session, terminal) catch {
          _ => self.last_session
        },
      )
      raise error
    }
  }
}

///|
async fn AgentLoop::append(
  self : Self,
  session : @agent_session.Session,
  item : @agent_session.SessionItem,
) -> @agent_session.Session {
  let next = (self.append_item)(session, item)
  self.last_session = next
  next
}

///|
fn AgentLoop::push_finished_message(self : Self, answer : String) -> Unit {
  if !answer.trim().is_empty() {
    self.messages.push(ChatMessage(Assistant, content=answer))
  }
}

///|
/// Fold steering input into the conversation: each becomes a durable session
/// item and a model-visible chat message. Prompt/command steering persists as a
/// user message; a background notice persists as a `RuntimeNotice` (so on resume
/// it renders as a system notice, not user input). All emit `steer_applied`; the
/// `kind` field distinguishes them.
async fn AgentLoop::apply_steer_inputs(
  self : Self,
  session : @agent_session.Session,
  inputs : ArrayView[@agent_runtime.SteerInput],
) -> @agent_session.Session {
  for input in inputs; current = session {
    let (kind, text, item) : (String, String, @agent_session.SessionItem) = match
      input {
      Prompt(text) => ("prompt", text, User(UserMessage(text)))
      Command(text) => ("command", text, User(UserMessage(text)))
      Notice(text) => ("notice", text, Runtime(RuntimeNotice(text)))
    }
    let next = self.append(current, item)
    self.messages.push(ChatMessage(User, content=text))
    @xlog.info() <? { "event": "steer_applied", "kind": kind, "content": text }
    continue next
  } nobreak {
    current
  }
}

///|
async fn AgentLoop::prepare_step(
  self : Self,
  session : @agent_session.Session,
) -> @agent_session.Session {
  // Steering first: user-visible mid-turn input should be applied before plan
  // reminders or the next model request.
  let mut session = self.apply_steer_inputs(
    session,
    self.runtime.pending_steers(),
  )
  if self.plan_cadence.should_remind() {
    let reminder = self.plan_cadence.reminder_text()
    session = self.append(session, Runtime(RuntimeNotice(reminder)))
    self.messages.push(ChatMessage(User, content=reminder))
    @xlog.info() <? { "event": "plan_reminder", "content": reminder }
    self.plan_cadence.record_reminder()
  }
  self.plan_cadence.record_model_request()
  session
}

///|
async fn AgentLoop::chat(self : Self, step : Int) -> @deepseek.ChatResponse {
  @xlog.info() <? { "event": "agent_step", "step": step + 1 }
  let response = self.client.chat(
    self.messages,
    tools=self.tools.function_tools(),
    stream=StreamHandler(on_content_delta=delta => {
      if delta != "" {
        @xlog.info() <? { "event": "assistant_delta", "content": delta }
      }
    }),
  )
  response.log_and_reasoning_content()
}

///|
fn @deepseek.ChatResponse::log_and_reasoning_content(
  response : Self,
) -> @deepseek.ChatResponse {
  // Reasoning first, so a consumer appending events in order shows the
  // thinking above the answer it led to.
  if response.reasoning_content != "" {
    @xlog.info() <?
      { "event": "reasoning_message", "content": response.reasoning_content }
  }
  if response.content != "" {
    @xlog.info() <?
      { "event": "assistant_message", "content": response.content }
  }
  print_usage(response.usage)
  response
}

///|
async fn AgentLoop::handle_tool_calls(
  self : Self,
  session : @agent_session.Session,
  response : @deepseek.ChatResponse,
) -> AgentStepOutcome {
  let reasoning_content = response.optional_reasoning_content()
  let session = self.append(
    session,
    Assistant(
      AssistantMessage(
        response.content,
        tool_calls=response.tool_calls,
        reasoning_content?,
      ),
    ),
  )
  self.messages.push(
    ChatMessage(
      Assistant,
      content=response.content,
      tool_calls=response.tool_calls,
      reasoning_content?,
    ),
  )
  let mut spent_result_chars : Int64 = 0
  for call_index, native_call in response.tool_calls; session = session {
    // Running batch budget: stop BEFORE a call whose worst case could push
    // the projection past what the checkpoint request needs. Uses actual
    // recorded sizes for everything already executed, so it only ever
    // pessimizes one call ahead — no pre-execution estimate over the whole
    // batch, no false positives at low usage.
    if !self.next_call_fits(response.usage, spent_result_chars) {
      // A finish call in the unexecuted remainder is a completion, not
      // more output — on small-window models the budget can trip well
      // below the hard ceiling, and skip-closing the finish would turn an
      // already-completed task into a context yield. The executed prefix's
      // growth rides along so the salvaged finish still checkpoints.
      match
        self.salvage_finish_at_ceiling(
          session,
          response,
          from=call_index,
          spent_result_chars~,
        ) {
        Some(outcome) => return outcome
        None => ()
      }
      let session = self.close_skipped_tool_calls(
        session,
        response.tool_calls[call_index:],
        note=ceiling_skip_note,
      )
      return StepYield(session)
    }
    let tool_call = @agent_tool.AgentToolCall(native_call) catch {
      error => {
        let content = "error: \{error}"
        let session = self.record_tool_result(
          session,
          tool_call_id=native_call.id,
          tool_name=native_call.name,
          content~,
          is_error=true,
        )
        @xlog.error() <?
          {
            "event": "tool_call_decode_error",
            "tool_call_id": native_call.id,
            "tool_name": native_call.name,
            "error": "\{error}",
          }
        continue session
      }
    }
    match
      self.execute_tool_call(
        session,
        response,
        call_index,
        native_call,
        tool_call,
        spent_result_chars~,
      ) {
      ContinueToolBatch(next) => {
        // Account the result actually recorded for this call (the loop
        // clamp bounds it at max_tool_result_chars).
        if next.events().peek() is Some(event) && event.item() is Tool(result) {
          spent_result_chars += result.content().length().to_int64()
        }
        continue next
      }
      ContinueAgentLoop(next) => return StepContinue(next)
      FinishAgentLoop(next) => return StepDone(next)
    }
  } nobreak {
    // The batch ran to completion. The soft decision includes the batch's
    // own growth: a below-threshold response whose results carried the
    // context into the soft band still ends here, gracefully, instead of
    // sending one more oversized request to find out.
    if self.at_soft_context_ceiling(
        response.usage,
        extra_result_chars=spent_result_chars,
      ) {
      StepYield(session)
    } else {
      StepContinue(session)
    }
  }
}

///|
async fn AgentLoop::execute_tool_call(
  self : Self,
  session : @agent_session.Session,
  response : @deepseek.ChatResponse,
  call_index : Int,
  native_call : @deepseek.ToolCall,
  tool_call : @agent_tool.AgentToolCall,
  spent_result_chars~ : Int64,
) -> ToolCallOutcome {
  let result = @agent_tool.execute_tool_call(tool_call, self.tools)
  match result {
    Control(Finish(answer)) => {
      let session = self.record_tool_result(
        session,
        tool_call_id=native_call.id,
        tool_name=tool_call.name,
        content="finished: \{answer}",
      )
      // Close the batch's unexecuted remainder, whatever comes next: every
      // call in the assistant's batch needs a result message — in CALL
      // order, matching the assistant's tool_calls echo sequence — so the
      // durable log and any checkpoint request generated from it stay
      // API-valid without projection repair text leaking into summaries.
      // Step attribution downstream does not need the finish result last:
      // analyzers treat "a finish result seen since the last assistant
      // message" as finish-completion, because everything recorded after
      // it in the same batch is by construction a skip note.
      let remaining_tool_calls = response.tool_calls[call_index + 1:]
      let session = self.close_skipped_tool_calls(
        session,
        remaining_tool_calls,
        note="skipped: an earlier finish tool call ended the batch before this call ran",
      )
      let steer_inputs = self.runtime.pending_steers()
      if steer_inputs.is_empty() {
        return match
          self.finish_turn(
            session,
            answer,
            usage=response.usage,
            spent_result_chars~,
          ) {
          Sealed(next) => FinishAgentLoop(next)
          ContinueTurn(next) => ContinueAgentLoop(next)
        }
      }
      // User input wins over the finish tool as well — but never answered in
      // a starved context: at the ceiling the turn yields and the steers
      // survive the checkpoint verbatim.
      if self.at_soft_context_ceiling(
          response.usage,
          extra_result_chars=spent_result_chars,
        ) {
        return FinishAgentLoop(
          self.yield_at_context_ceiling(session, steer_inputs),
        )
      }
      let session = self.apply_steer_inputs(session, steer_inputs)
      ContinueAgentLoop(session)
    }
    Control(Abort(reason)) => {
      let session = self.append(
        session,
        Tool(
          ToolResult(
            tool_call_id=native_call.id,
            tool_name=tool_call.name,
            content="aborted: \{reason}",
            is_error=true,
          ),
        ),
      )
      let session = self.append(session, Terminal(Aborted(reason)))
      @xlog.warn() <? { "event": "agent_aborted", "reason": reason }
      return FinishAgentLoop(session)
    }
    Respond(output) => {
      // Clamp once, here, so the durable item, the in-flight model message
      // (via record_tool_result), and the live JSONL/TUI event all carry
      // the SAME bounded content — a log that disagrees with what the
      // model saw defeats the cap for live consumers.
      let content = clamp_tool_result_content(output.content)
      let session = self.record_tool_result(
        session,
        tool_call_id=native_call.id,
        tool_name=tool_call.name,
        content~,
        is_error=output.is_error,
        brief?=output.brief,
      )
      self.plan_cadence.record_plan_success(tool_call, output)
      log_tool_result(
        native_call,
        tool_call,
        is_error=output.is_error,
        content~,
        brief=output.brief,
      )
      ContinueToolBatch(session)
    }
  }
}

///|
/// Append synthetic error results for tool calls left unexecuted after a finish
/// tool loses to newly arrived user input.
///
/// Every call in the assistant's batch needs a result message, so the finish
/// call's result and skipped notes for the unexecuted remainder are pushed
/// before the new input.
async fn AgentLoop::close_skipped_tool_calls(
  self : Self,
  session : @agent_session.Session,
  remaining_tool_calls : ArrayView[@deepseek.ToolCall],
  note~ : String,
) -> @agent_session.Session {
  for skipped in remaining_tool_calls; session = session {
    let session = self.record_tool_result(
      session,
      tool_call_id=skipped.id,
      tool_name=skipped.name,
      content=note,
      is_error=true,
    )
    @xlog.info() <?
      {
        "event": "tool_result",
        "tool_call_id": skipped.id,
        "tool_name": skipped.name,
        "is_error": true,
        "content": note,
      }
    continue session
  } nobreak {
    session
  }
}

///|
/// At the context ceiling, a batch carrying the built-in `finish` call is a
/// completion, not more work — honor it instead of discarding it. Calls
/// before the finish are skip-closed (their results cannot change the
/// already-decided answer, and executing them would grow the checkpoint
/// request); the finish call itself executes — a few bytes of result — and
/// its Control(Finish) path closes the remainder, checkpoints, and seals
/// the real answer. `finish` is matched by name: it is the loop's
/// documented structured-completion contract (see agent_tool/finish). A
/// custom tool returning Control(Finish) under another name still works
/// whenever its batch executes; it just cannot be salvaged at the ceiling.
///
/// Returns None when the batch carries no decodable finish call — nothing
/// was appended and the caller proceeds with the plain yield. Otherwise
/// the outcome distinguishes a sealed turn (StepDone: finished or yielded)
/// from a continuation (StepContinue: a steer arriving during the salvaged
/// finish's checkpoint converted it into ContinueTurn — treating that as a
/// failed salvage would close already-closed calls again and fold the
/// steer into a second summary).
///
/// `from` is where the unexecuted remainder starts: 0 when the whole batch
/// is being skipped (hard ceiling), or the tripping call's index when the
/// running budget stopped execution mid-batch — calls before it already
/// executed and have results (their growth arrives as
/// `spent_result_chars`, so the salvaged finish still checkpoints). The
/// finish call itself is exempt from the budget: its result is a few bytes
/// of completion, not tool output.
async fn AgentLoop::salvage_finish_at_ceiling(
  self : Self,
  session : @agent_session.Session,
  response : @deepseek.ChatResponse,
  from? : Int = 0,
  spent_result_chars? : Int64 = 0,
) -> AgentStepOutcome? {
  // The registry must declare the finish tool a CONTROL tool: that is how
  // the loop knows — without executing — that honoring the call appends a
  // few bytes, not tool output. A custom non-control tool shadowing the
  // name is skip-closed like any other call at the ceiling.
  guard self.tools.find("finish") is Some(definition) && definition.is_control() else {
    return None
  }
  let mut finish_index = -1
  for index, call in response.tool_calls {
    if index >= from && call.name == "finish" {
      finish_index = index
      break
    }
  }
  if finish_index < 0 {
    return None
  }
  let native_call = response.tool_calls[finish_index]
  let tool_call = @agent_tool.AgentToolCall(native_call) catch {
    _ => return None
  }
  let session = self.close_skipped_tool_calls(
    session,
    response.tool_calls[from:finish_index],
    note=ceiling_skip_note,
  )
  match
    self.execute_tool_call(
      session,
      response,
      finish_index,
      native_call,
      tool_call,
      spent_result_chars~,
    ) {
    FinishAgentLoop(next) => Some(StepDone(next))
    // The finish ran but a steer converted it into a continuation: its
    // remainder is already closed and the checkpoint appended.
    ContinueAgentLoop(next) => Some(StepContinue(next))
    // A tool named `finish` that did not finish (custom override returning
    // Respond): close the remainder and fall back to the ceiling yield.
    ContinueToolBatch(next) => {
      let next = self.close_skipped_tool_calls(
        next,
        response.tool_calls[finish_index + 1:],
        note=ceiling_skip_note,
      )
      Some(
        StepDone(
          self.yield_at_context_ceiling(next, self.runtime.pending_steers()),
        ),
      )
    }
  }
}

///|
/// Ceiling for one recorded tool result, in UTF-16 units. It MUST sit
/// above every in-tree tool's self-cap PLUS its metadata footer (shell
/// inline output caps at 12K; read caps its body budget at 50K and then
/// appends a `<system>…</system>` footer), so in-tree results always pass
/// through untouched — a loop-level cut would strip exactly the
/// truncation/line/exit metadata the model needs to know a result is
/// incomplete. The clamp therefore only ever fires on custom tool
/// registrations, which is what gives the soft-tier batch budget a real
/// per-call bound.
let max_tool_result_chars : Int = 60_000

///|
/// Clamp an oversized tool result to `max_tool_result_chars`, never
/// splitting a surrogate pair.
fn clamp_tool_result_content(content : String) -> String {
  if content.length() <= max_tool_result_chars {
    return content
  }
  // The marker fits INSIDE the cap: the recorded result must never exceed
  // the per-call figure soft_batch_fits budgets with.
  let marker = "\n[truncated: result exceeded the \{max_tool_result_chars}-char cap]"
  let body_budget = max_tool_result_chars - marker.length()
  let kept = StringBuilder()
  for ch in content; units = 0 {
    let width : Int = if ch.to_int() > 0xFFFF { 2 } else { 1 }
    if units + width > body_budget {
      break
    }
    kept.write_char(ch)
    continue units + width
  } nobreak {

  }
  kept.write_string(marker)
  kept.to_string()
}

///|
/// Record one tool result: append it durably and mirror it into the in-flight
/// chat messages. The two must stay in lockstep — every tool call in an
/// assistant batch needs a matching result message for the conversation to
/// stay API-valid.
async fn AgentLoop::record_tool_result(
  self : Self,
  session : @agent_session.Session,
  tool_call_id~ : String,
  tool_name~ : String,
  content~ : String,
  is_error? : Bool = false,
  brief? : String,
) -> @agent_session.Session {
  let content = clamp_tool_result_content(content)
  let session = self.append(
    session,
    Tool(ToolResult(tool_call_id~, tool_name~, content~, is_error~, brief?)),
  )
  self.messages.push(ChatMessage(Tool(tool_call_id), content~))
  session
}

///|
/// Durably record the turn's final answer and mirror it for the still-live
/// loop state.
///
/// Compact-on-finish: a turn that completes at the context ceiling still
/// leaves a checkpoint, so the next turn seeds from the compacted
/// projection instead of landing its first request on a pressured one. The
/// answer is not yet durable when the summary generates, so it cannot fold
/// into the checkpoint text — it projects verbatim after the summary, and
/// the turn stays a normal success (`agent_finished`, real answer) on both
/// the wire and the durable log. Fail-open: a failed checkpoint finishes
/// uncompacted.
///
/// EXCEPT when user input queued during the checkpoint request: then the
/// steer-beats-finish rule applies once more and the turn CONTINUES from
/// the compacted projection (`ContinueTurn`) — the answer becomes ordinary
/// history and the model addresses the steer with fresh headroom.
async fn AgentLoop::finish_turn(
  self : Self,
  session : @agent_session.Session,
  answer : String,
  usage~ : @deepseek.Usage,
  spent_result_chars? : Int64 = 0,
  reasoning_content? : String,
) -> FinishOutcome {
  let session = if self.at_soft_context_ceiling(
      usage,
      extra_result_chars=spent_result_chars,
    ) {
    let (session, compacted) = self.checkpoint_at_ceiling(session, [])
    // The checkpoint request takes seconds; user input may have queued
    // while it was in flight. Appending it before the terminal would make
    // the decided answer read as its reply, and leaving it queued gets it
    // boundary-dropped at TurnDone — so the steer-beats-finish rule
    // applies once more: the answer stays an ordinary assistant message
    // and the turn continues, from the compacted projection.
    let steers = self.runtime.pending_steers()
    if !steers.is_empty() {
      let to_sequence = session.last_sequence()
      // Keep the response's reasoning on the converted message: Kimi
      // requires preserved reasoning_content on historical assistant
      // messages, and this answer is history now.
      let session = self.append(
        session,
        Assistant(AssistantMessage(answer, reasoning_content?)),
      )
      let session = self.apply_steer_inputs(session, steers)
      if !compacted {
        // The checkpoint FAILED: continuing would build the next request
        // from the same pressured, uncheckpointed history plus two more
        // messages — the exact overflow the guard exists to prevent.
        // Yield fail-open instead: the answer and steers are durable
        // (uncovered, heading the next turn) and the next turn's pressure
        // retries the checkpoint.
        return Sealed(
          self.finish_context_yield(session, to_sequence, compacted=false),
        )
      }
      // Re-seed the in-flight buffer from the projection: the whole point
      // of the checkpoint is that the continuation request is small, and
      // the buffer must never disagree with Session::chat_messages.
      self.messages.clear()
      for message in session.chat_messages() {
        self.messages.push(message)
      }
      return ContinueTurn(session)
    }
    session
  } else {
    session
  }
  let session = self.append(session, Terminal(Finished(answer)))
  self.push_finished_message(answer)
  @xlog.info() <? { "event": "agent_finished", "answer": answer }
  Sealed(session)
}

///|
fn log_tool_result(
  native_call : @deepseek.ToolCall,
  tool_call : @agent_tool.AgentToolCall,
  is_error~ : Bool,
  content~ : String,
  brief~ : String?,
) -> Unit {
  @xlog.info() <?
    {
      "event": "tool_result",
      "tool_call_id": native_call.id,
      "tool_name": tool_call.name,
      "is_error": is_error,
      "content": content,
      "brief": if brief is Some(brief) {
        Json::string(brief)
      } else {
        Json::null()
      },
    }
}

///|
fn @deepseek.ChatResponse::optional_reasoning_content(
  response : Self,
) -> String? {
  match response.reasoning_content {
    "" => None
    content => Some(content)
  }
}
