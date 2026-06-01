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
  let log = AgentLog()
  let client = @client.Client(
    api_key~,
    model~,
    thinking=Some(Enabled),
    reasoning_effort=Some(Max),
  )
  let tools = tool_definitions() catch {
    error => {
      log.agent_setup_failed("\{error}")
      return
    }
  }
  let messages : Array[@deepseek.ChatMessage] = [
    ChatMessage(System, content=system_prompt_text),
    ChatMessage(User, content=task),
  ]
  for step in 0..<max_steps {
    log.step(step + 1)
    let response = client.chat(messages, tools=tools.function_tools())
    if response.content != "" {
      log.agent_content(response.content)
    }
    log.usage(response.usage)
    if response.tool_calls.length() == 0 {
      log.finish(response.content)
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
          log.tool_decode_error("\{error}")
          messages.push(
            ChatMessage(Tool(native_call.id), content="error: \{error}"),
          )
          continue
        }
      }
      let result = @agent_tool.execute_tool_call(tool_call, tools)
      let output = match result {
        Control(Finish(answer)) => {
          log.finish(answer)
          return
        }
        Control(Abort(reason)) => {
          log.abort(reason)
          return
        }
        Respond(output) => output
      }
      log.tool_output(output.is_error, output.content)
      messages.push(ChatMessage(Tool(native_call.id), content=output.content))
    }
  }
  log.max_steps_exhausted()
}

///|
priv struct AgentLog {
  logger : @logger.Logger
}

///|
fn AgentLog::AgentLog() -> AgentLog {
  { logger: @logger.stdout() }
}

///|
async fn AgentLog::agent_setup_failed(
  self : AgentLog,
  message : String,
) -> Unit {
  self.jsonl(
    "ERROR",
    "agent_setup_failed",
    Map([("message", Json::string(message))]),
  )
}

///|
async fn AgentLog::step(self : AgentLog, step : Int) -> Unit {
  self.jsonl("INFO", "step", Map([("step", int_json(step))]))
}

///|
async fn AgentLog::agent_content(self : AgentLog, content : String) -> Unit {
  self.jsonl("INFO", "assistant", Map([("content", Json::string(content))]))
}

///|
async fn AgentLog::usage(self : AgentLog, usage : @deepseek.Usage) -> Unit {
  self.jsonl(
    "INFO",
    "usage",
    Map([
      ("prompt_tokens", int_json(usage.prompt_tokens)),
      ("completion_tokens", int_json(usage.completion_tokens)),
      ("total_tokens", int_json(usage.total_tokens)),
      ("prompt_cache_hit_tokens", int_json(usage.prompt_cache_hit_tokens)),
      ("prompt_cache_miss_tokens", int_json(usage.prompt_cache_miss_tokens)),
    ]),
  )
}

///|
async fn AgentLog::finish(self : AgentLog, answer : String) -> Unit {
  self.jsonl("INFO", "finish", Map([("answer", Json::string(answer))]))
}

///|
async fn AgentLog::tool_decode_error(self : AgentLog, message : String) -> Unit {
  self.jsonl("ERROR", "tool_error", Map([("message", Json::string(message))]))
}

///|
async fn AgentLog::abort(self : AgentLog, reason : String) -> Unit {
  self.jsonl("WARN", "abort", Map([("reason", Json::string(reason))]))
}

///|
async fn AgentLog::tool_output(
  self : AgentLog,
  is_error : Bool,
  content : String,
) -> Unit {
  let level = if is_error { "ERROR" } else { "INFO" }
  self.jsonl(
    level,
    "tool",
    Map([
      ("is_error", Json::boolean(is_error)),
      ("content", Json::string(content)),
    ]),
  )
}

///|
async fn AgentLog::max_steps_exhausted(self : AgentLog) -> Unit {
  self.jsonl("WARN", "max_steps_exhausted", Map([]))
}

///|
async fn AgentLog::jsonl(
  self : AgentLog,
  level : String,
  event : String,
  fields : Map[String, Json],
) -> Unit {
  fields.set("level", Json::string(level))
  fields.set("event", Json::string(event))
  self.logger.write(fields)
}

///|
fn int_json(value : Int) -> Json {
  Json::number(value.to_double(), repr=value.to_string())
}
