///|
let default_max_steps : Int = 1000

///|
/// Returns the base built-in system prompt.
pub fn default_system_prompt() -> String {
  @prompt.system_prompt_for_model(V4Pro)
}

///|
/// Returns the default system prompt for a DeepSeek model.
pub fn default_system_prompt_for_model(model : @deepseek.Model) -> String {
  @prompt.system_prompt_for_model(model)
}

///|
/// Runs the OpenSeek agent loop for a single task.
pub async fn run(
  api_key : String,
  model : @deepseek.Model,
  task : String,
  max_steps? : Int = default_max_steps,
  system_prompt_text? : String = default_system_prompt_for_model(model),
) -> Unit {
  let client = @client.Client(
    api_key~,
    model~,
    thinking=Some(Enabled),
    reasoning_effort=Some(Max),
  )
  let tools = tool_definitions() catch {
    error => {
      if log.at(ERROR) is Some(error_log) {
        error_log.write_object({
          "event": "agent_setup_failed",
          "error": "\{error}",
        })
      }
      return
    }
  }
  let messages : Array[@deepseek.ChatMessage] = [
    ChatMessage(System, content=system_prompt_text),
    ChatMessage(User, content=task),
  ]
  for step in 0..<max_steps {
    if log.at(INFO) is Some(info_log) {
      info_log.write_object({ "event": "agent_step", "step": step + 1 })
    }
    let response = client.chat(messages, tools=tools.function_tools())
    if response.content != "" {
      if log.at(INFO) is Some(info_log) {
        info_log.write_object({
          "event": "assistant_message",
          "content": response.content,
        })
      }
    }
    print_usage(response.usage)
    if response.tool_calls.length() == 0 {
      if log.at(INFO) is Some(info_log) {
        info_log.write_object({
          "event": "agent_finished",
          "answer": response.content,
        })
      }
      return
    }
    let reasoning_content = match response.reasoning_content {
      "" => None
      content => Some(content)
    }
    let assistant_message : @deepseek.ChatMessage = ChatMessage(
      Assistant,
      content=response.content,
      tool_calls=response.tool_calls,
      reasoning_content?,
    )
    messages.push(assistant_message)
    for native_call in response.tool_calls {
      let tool_call = @agent_tool.AgentToolCall(native_call) catch {
        error => {
          if log.at(ERROR) is Some(error_log) {
            error_log.write_object({
              "event": "tool_call_decode_error",
              "tool_call_id": native_call.id,
              "tool_name": native_call.name,
              "error": "\{error}",
            })
          }
          messages.push(
            ChatMessage(Tool(native_call.id), content="error: \{error}"),
          )
          continue
        }
      }
      let result = @agent_tool.execute_tool_call(tool_call, tools)
      let output = match result {
        Control(Finish(answer)) => {
          if log.at(INFO) is Some(info_log) {
            info_log.write_object({
              "event": "agent_finished",
              "answer": answer,
            })
          }
          return
        }
        Control(Abort(reason)) => {
          if log.at(WARN) is Some(warn_log) {
            warn_log.write_object({ "event": "agent_aborted", "reason": reason })
          }
          return
        }
        Respond(output) => output
      }
      if log.at(INFO) is Some(info_log) {
        info_log.write_object({
          "event": "tool_result",
          "tool_call_id": native_call.id,
          "tool_name": tool_call.name,
          "is_error": output.is_error,
          "content": output.content,
        })
      }
      messages.push(ChatMessage(Tool(native_call.id), content=output.content))
    }
  }
  if log.at(WARN) is Some(warn_log) {
    warn_log.write_object({ "event": "max_steps_exhausted" })
  }
}

///|
let log : @logger.Logger = @logger.stdout(min_level=INFO)

///|
async fn print_usage(usage : @deepseek.Usage) -> Unit {
  if log.at(INFO) is Some(info_log) {
    info_log.write_object({
      "event": "usage",
      "prompt_tokens": usage.prompt_tokens,
      "completion_tokens": usage.completion_tokens,
      "cache_hit_tokens": usage.prompt_cache_hit_tokens,
      "cache_miss_tokens": usage.prompt_cache_miss_tokens,
    })
  }
}
