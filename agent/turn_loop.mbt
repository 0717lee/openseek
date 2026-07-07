///|
priv struct AgentLoop {
  runtime : @agent_runtime.AgentRuntime
  client : @client.Client
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
  tools~ : @agent_tool.Tools,
  append_item~ : async (@agent_session.Session, @agent_session.SessionItem) -> @agent_session.Session,
  session~ : @agent_session.Session,
) -> AgentLoop {
  {
    runtime,
    client,
    tools,
    append_item,
    messages: session.chat_messages(),
    plan_cadence: PlanCadence(registered=tools.find("plan") is Some(_)),
    last_session: session,
  }
}

///|
priv enum AgentStepOutcome {
  StepContinue(@agent_session.Session)
  StepDone(@agent_session.Session)
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
      if response.tool_calls.is_empty() {
        let steer_inputs = self.runtime.pending_steers()
        if steer_inputs.is_empty() {
          // A true final answer is stored once as Terminal(Finished). Later turns
          // rebuild model context through Session::chat_messages, which projects
          // that terminal back into an assistant message; appending an Assistant
          // session item here would duplicate the answer on replay.
          let session = self.append(
            session,
            Terminal(Finished(response.content)),
          )
          self.push_finished_message(response.content)
          @xlog.info() <?
            { "event": "agent_finished", "answer": response.content }
          return session
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
        let session = self.apply_steer_inputs(session, steer_inputs)
        continue session
      } else {
        match self.handle_tool_calls(session, response) {
          StepContinue(next) => continue next
          StepDone(next) => return next
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
  for call_index, native_call in response.tool_calls; session = session {
    let tool_call = @agent_tool.AgentToolCall(native_call) catch {
      error => {
        let content = "error: \{error}"
        let session = self.append(
          session,
          Tool(
            ToolResult(
              tool_call_id=native_call.id,
              tool_name=native_call.name,
              content~,
              is_error=true,
            ),
          ),
        )
        self.messages.push(ChatMessage(Tool(native_call.id), content~))
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
        session, response, call_index, native_call, tool_call,
      ) {
      ContinueToolBatch(next) => continue next
      ContinueAgentLoop(next) => return StepContinue(next)
      FinishAgentLoop(next) => return StepDone(next)
    }
  } nobreak {
    StepContinue(session)
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
) -> ToolCallOutcome {
  let result = @agent_tool.execute_tool_call(tool_call, self.tools)
  match result {
    Control(Finish(answer)) => {
      let session = self.append(
        session,
        Tool(
          ToolResult(
            tool_call_id=native_call.id,
            tool_name=tool_call.name,
            content="finished: \{answer}",
          ),
        ),
      )
      self.messages.push(
        ChatMessage(Tool(native_call.id), content="finished: \{answer}"),
      )
      let steer_inputs = self.runtime.pending_steers()
      if steer_inputs.is_empty() {
        let session = self.append(session, Terminal(Finished(answer)))
        self.push_finished_message(answer)
        @xlog.info() <? { "event": "agent_finished", "answer": answer }
        return FinishAgentLoop(session)
      }
      // User input wins over the finish tool as well. Continuing the turn must keep
      // the conversation API-valid: every call in the assistant's batch needs a
      // result message, so the finish call's result and skipped notes for the
      // unexecuted remainder are pushed before the new input.
      let remaining_tool_calls = response.tool_calls[call_index + 1:]
      let session = self.close_skipped_tool_calls(session, remaining_tool_calls)
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
      let session = self.append(
        session,
        Tool(
          ToolResult(
            tool_call_id=native_call.id,
            tool_name=tool_call.name,
            content=output.content,
            is_error=output.is_error,
            brief?=output.brief,
          ),
        ),
      )
      self.plan_cadence.record_plan_success(tool_call, output)
      self.messages.push(
        ChatMessage(Tool(native_call.id), content=output.content),
      )
      log_tool_result(native_call, tool_call, output)
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
) -> @agent_session.Session {
  for skipped in remaining_tool_calls; session = session {
    let note = "skipped: user input arrived before this call ran"
    let session = self.append(
      session,
      Tool(
        ToolResult(
          tool_call_id=skipped.id,
          tool_name=skipped.name,
          content=note,
          is_error=true,
        ),
      ),
    )
    self.messages.push(ChatMessage(Tool(skipped.id), content=note))
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
fn log_tool_result(
  native_call : @deepseek.ToolCall,
  tool_call : @agent_tool.AgentToolCall,
  output : @agent_tool.ToolOutput,
) -> Unit {
  @xlog.info() <?
    {
      "event": "tool_result",
      "tool_call_id": native_call.id,
      "tool_name": tool_call.name,
      "is_error": output.is_error,
      "content": output.content,
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
