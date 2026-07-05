// Executing one assistant tool-call batch. Extracted from the step loop in
// `run_turn_in_scope` (agent.mbt) so the loop reads as a narrative; the batch
// mechanics — decode errors, finish/abort control results, steering
// overrides, plan cadence updates — live here.

///|
/// Outcome of one assistant tool-call batch.
priv enum BatchResult {
  // Every call got a result, even if terminal control or a steering override
  // prevented later calls in the batch from running; the turn takes another
  // model step with the carried session.
  Continue(@agent_session.Session)
  // A terminal event was appended; the turn is over.
  Done(@agent_session.Session)
}

///|
/// Record the assistant's tool-call response and execute every call in the
/// batch, in order.
///
/// The conversation must stay API-valid: every tool call in the assistant
/// message gets exactly one result message — real output, a decode error, a
/// finish or abort note, or a skipped note for calls terminal control or a
/// steering override prevented from running.
///
/// A `finish` control result ends the turn only when no steering is pending;
/// user input wins over model-initiated completion, so a pending steer turns
/// the finish into an ordinary result, marks the unexecuted remainder
/// skipped, folds the steer in, and continues. An abort always ends the
/// turn, after marking the unexecuted remainder skipped. A successful `plan`
/// write resets the plan-silence counter and refreshes the checklist.
async fn @agent_session.Session::append_skipped_tool_results(
  session : Self,
  messages : Array[@deepseek.ChatMessage],
  calls : ArrayView[@deepseek.ToolCall],
  note : String,
  append_item~ : async (@agent_session.Session, @agent_session.SessionItem) -> @agent_session.Session,
) -> @agent_session.Session {
  let mut session = session
  for skipped in calls {
    @xlog.info() <?
      {
        "event": "tool_result",
        "tool_call_id": skipped.id,
        "tool_name": skipped.name,
        "is_error": true,
        "content": note,
      }
    messages.push(ChatMessage(Tool(skipped.id), content=note))
    session = append_item(
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
async fn @agent_session.Session::run_tool_batch(
  session : Self,
  response : @deepseek.ChatResponse,
  messages : Array[@deepseek.ChatMessage],
  tools : @agent_tool.Tools,
  runtime : @agent_runtime.AgentRuntime,
  cadence : PlanCadence,
  append_item~ : async (@agent_session.Session, @agent_session.SessionItem) -> @agent_session.Session,
) -> BatchResult {
  let mut session = session
  let reasoning_content = match response.reasoning_content {
    "" => None
    content => Some(content)
  }
  messages.push(
    ChatMessage(
      Assistant,
      content=response.content,
      tool_calls=response.tool_calls,
      reasoning_content?,
    ),
  )
  session = append_item(
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
        messages.push(
          ChatMessage(Tool(native_call.id), content="error: \{error}"),
        )
        session = append_item(
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
    let result = @agent_tool.execute_tool_call(tool_call, tools)
    let output = match result {
      Control(Finish(answer)) => {
        session = append_item(
          session,
          Tool(
            ToolResult(
              tool_call_id=native_call.id,
              tool_name=tool_call.name,
              content="finished: \{answer}",
            ),
          ),
        )
        let steer_inputs = pending_steers(runtime)
        if steer_inputs.is_empty() {
          session = session.append_skipped_tool_results(
            messages,
            response.tool_calls[call_index + 1:],
            "skipped: finish ended the turn before this call ran",
            append_item~,
          )
          let next = append_item(session, Terminal(Finished(answer)))
          @xlog.info() <? { "event": "agent_finished", "answer": answer }
          return Done(next)
        }
        // User input wins over the finish tool as well. Continuing the turn
        // must keep the conversation API-valid: every call in the
        // assistant's batch needs a result message, so the finish call's
        // result and skipped notes for the unexecuted remainder are pushed
        // before the new input.
        messages.push(
          ChatMessage(Tool(native_call.id), content="finished: \{answer}"),
        )
        session = session.append_skipped_tool_results(
          messages,
          response.tool_calls[call_index + 1:],
          "skipped: user input arrived before this call ran",
          append_item~,
        )
        session = session.apply_steer_inputs(
          steer_inputs,
          messages,
          append_item~,
        )
        return Continue(session)
      }
      Control(Abort(reason)) => {
        session = append_item(
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
        session = session.append_skipped_tool_results(
          messages,
          response.tool_calls[call_index + 1:],
          "skipped: abort ended the turn before this call ran",
          append_item~,
        )
        let next = append_item(session, Terminal(Aborted(reason)))
        @xlog.warn() <? { "event": "agent_aborted", "reason": reason }
        return Done(next)
      }
      Respond(output) => output
    }
    if tool_call.name == "plan" && !output.is_error {
      // A successful plan write restarts the staleness cadence and
      // refreshes the checklist the next reminder would re-surface; a
      // cleared plan drops back to the plan-free nudge.
      cadence.steps_since_plan = 0
      cadence.checklist = @plan.reminder_checklist(tool_call.arguments)
    }
    @xlog.info() <?
      {
        "event": "tool_result",
        "tool_call_id": native_call.id,
        "tool_name": tool_call.name,
        "is_error": output.is_error,
        "content": output.content,
      }
    messages.push(ChatMessage(Tool(native_call.id), content=output.content))
    session = append_item(
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
  }
  Continue(session)
}
