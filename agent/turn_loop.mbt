///|
priv struct AgentLoop {
  runtime : @agent_runtime.AgentRuntime
  client : @client.Client
  tools : @agent_tool.Tools
  append_item : async (@agent_session.Session, @agent_session.SessionItem) -> @agent_session.Session
  messages : Array[@deepseek.ChatMessage]
  plan_registered : Bool
  cadence : PlanCadence
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
    plan_registered: tools.find("plan") is Some(_),
    cadence: { steps_since_plan: 0, steps_since_reminder: 0, checklist: None },
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
  ContinueToolBatch(@agent_session.Session)
  ContinueAgentLoop(@agent_session.Session)
  FinishAgentLoop(@agent_session.Session)
}

///|
async fn AgentLoop::run(
  self : Self,
  session : @agent_session.Session,
  max_steps : Int,
) -> @agent_session.Session {
  self.last_session = session
  let mut session = session
  try {
    loop_steps~: for step in 0..<max_steps {
      session = self.prepare_step(session)
      let response = self.chat(step)
      match self.handle_response(session, response) {
        StepContinue(next) => {
          session = next
          continue loop_steps~
        }
        StepDone(next) => return next
      }
    }
    @xlog.warn() <? { "event": "max_steps_exhausted" }
    self.append(session, Terminal(Failed("max steps exhausted")))
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
async fn AgentLoop::apply_steer_inputs(
  self : Self,
  session : @agent_session.Session,
  inputs : Array[@agent_runtime.SteerInput],
) -> @agent_session.Session {
  session.apply_steer_inputs(inputs, self.messages, append_item=(session, item) => {
    self.append(session, item)
  })
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
  if self.plan_registered &&
    self.cadence.steps_since_plan >= plan_reminder_after_steps &&
    self.cadence.steps_since_reminder >= plan_reminder_after_steps {
    let reminder = plan_reminder_text(self.cadence.checklist)
    @xlog.info() <? { "event": "plan_reminder", "content": reminder }
    session = self.append(session, Runtime(RuntimeNotice(reminder)))
    self.messages.push(ChatMessage(User, content=reminder))
    self.cadence.steps_since_reminder = 0
  }
  self.cadence.steps_since_plan += 1
  self.cadence.steps_since_reminder += 1
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
async fn AgentLoop::handle_response(
  self : Self,
  session : @agent_session.Session,
  response : @deepseek.ChatResponse,
) -> AgentStepOutcome {
  if response.tool_calls.is_empty() {
    self.handle_final_response(session, response)
  } else {
    self.handle_tool_calls(session, response)
  }
}

///|
async fn AgentLoop::handle_final_response(
  self : Self,
  session : @agent_session.Session,
  response : @deepseek.ChatResponse,
) -> AgentStepOutcome {
  let steer_inputs = self.runtime.pending_steers()
  if steer_inputs.is_empty() {
    @xlog.info() <? { "event": "agent_finished", "answer": response.content }
    return StepDone(self.append(session, Terminal(Finished(response.content))))
  }
  let reasoning_content = response.optional_reasoning_content()
  // The model considers itself done, but user-visible input arrived while the
  // final call was in flight: user input wins over model-initiated completion.
  // The would-be answer stays as an ordinary assistant message and the turn
  // continues with the new input folded in.
  self.messages.push(
    ChatMessage(Assistant, content=response.content, reasoning_content?),
  )
  let session = self.append(
    session,
    Assistant(AssistantMessage(response.content, reasoning_content?)),
  )
  let session = self.apply_steer_inputs(session, steer_inputs)
  StepContinue(session)
}

///|
async fn AgentLoop::handle_tool_calls(
  self : Self,
  session : @agent_session.Session,
  response : @deepseek.ChatResponse,
) -> AgentStepOutcome {
  let reasoning_content = response.optional_reasoning_content()
  self.messages.push(
    ChatMessage(
      Assistant,
      content=response.content,
      tool_calls=response.tool_calls,
      reasoning_content?,
    ),
  )
  let mut session = self.append(
    session,
    Assistant(
      AssistantMessage(
        response.content,
        tool_calls=response.tool_calls,
        reasoning_content?,
      ),
    ),
  )
  for call_index, native_call in response.tool_calls {
    let tool_call = @agent_tool.AgentToolCall(native_call) catch {
      error => {
        @xlog.error() <?
          {
            "event": "tool_call_decode_error",
            "tool_call_id": native_call.id,
            "tool_name": native_call.name,
            "error": "\{error}",
          }
        self.messages.push(
          ChatMessage(Tool(native_call.id), content="error: \{error}"),
        )
        session = self.append(
          session,
          Tool(
            ToolResult(
              tool_call_id=native_call.id,
              tool_name=native_call.name,
              content="error: \{error}",
              is_error=true,
            ),
          ),
        )
        continue
      }
    }
    match
      self.execute_tool_call(
        session, response, call_index, native_call, tool_call,
      ) {
      ContinueToolBatch(next) => {
        session = next
        continue
      }
      ContinueAgentLoop(next) => return StepContinue(next)
      FinishAgentLoop(next) => return StepDone(next)
    }
  }
  StepContinue(session)
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
  let mut session = session
  let output = match result {
    Control(Finish(answer)) =>
      return self.finish_from_tool(
        session, response, call_index, native_call, tool_call, answer,
      )
    Control(Abort(reason)) =>
      return self.abort_from_tool(session, native_call, tool_call, reason)
    Respond(output) => output
  }
  self.record_plan_success(tool_call, output)
  log_tool_result(native_call, tool_call, output)
  self.messages.push(ChatMessage(Tool(native_call.id), content=output.content))
  session = self.append(
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
  ContinueToolBatch(session)
}

///|
async fn AgentLoop::finish_from_tool(
  self : Self,
  session : @agent_session.Session,
  response : @deepseek.ChatResponse,
  call_index : Int,
  native_call : @deepseek.ToolCall,
  tool_call : @agent_tool.AgentToolCall,
  answer : String,
) -> ToolCallOutcome {
  let mut session = self.append(
    session,
    Tool(
      ToolResult(
        tool_call_id=native_call.id,
        tool_name=tool_call.name,
        content="finished: \{answer}",
      ),
    ),
  )
  let steer_inputs = self.runtime.pending_steers()
  if steer_inputs.is_empty() {
    @xlog.info() <? { "event": "agent_finished", "answer": answer }
    return FinishAgentLoop(self.append(session, Terminal(Finished(answer))))
  }
  // User input wins over the finish tool as well. Continuing the turn must keep
  // the conversation API-valid: every call in the assistant's batch needs a
  // result message, so the finish call's result and skipped notes for the
  // unexecuted remainder are pushed before the new input.
  self.messages.push(
    ChatMessage(Tool(native_call.id), content="finished: \{answer}"),
  )
  session = self.close_skipped_tool_calls(session, response, call_index)
  session = self.apply_steer_inputs(session, steer_inputs)
  ContinueAgentLoop(session)
}

///|
async fn AgentLoop::close_skipped_tool_calls(
  self : Self,
  session : @agent_session.Session,
  response : @deepseek.ChatResponse,
  call_index : Int,
) -> @agent_session.Session {
  let mut session = session
  for skipped in response.tool_calls[call_index + 1:] {
    let note = "skipped: user input arrived before this call ran"
    @xlog.info() <?
      {
        "event": "tool_result",
        "tool_call_id": skipped.id,
        "tool_name": skipped.name,
        "is_error": true,
        "content": note,
      }
    self.messages.push(ChatMessage(Tool(skipped.id), content=note))
    session = self.append(
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
  }
  session
}

///|
async fn AgentLoop::abort_from_tool(
  self : Self,
  session : @agent_session.Session,
  native_call : @deepseek.ToolCall,
  tool_call : @agent_tool.AgentToolCall,
  reason : String,
) -> ToolCallOutcome {
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
  @xlog.warn() <? { "event": "agent_aborted", "reason": reason }
  FinishAgentLoop(self.append(session, Terminal(Aborted(reason))))
}

///|
fn AgentLoop::record_plan_success(
  self : Self,
  tool_call : @agent_tool.AgentToolCall,
  output : @agent_tool.ToolOutput,
) -> Unit {
  if tool_call.name == "plan" && !output.is_error {
    // A successful plan write restarts the staleness cadence and refreshes the
    // checklist the next reminder would re-surface; a cleared plan drops back to
    // the plan-free nudge.
    self.cadence.steps_since_plan = 0
    self.cadence.checklist = @plan.reminder_checklist(tool_call.arguments)
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
