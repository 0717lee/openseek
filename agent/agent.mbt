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
  @async.with_task_group() <| group => {
    run_with_runtime(
      AgentRuntime(group),
      api_key,
      model,
      task,
      max_steps~,
      system_prompt_text~,
    )
  }
}

///|
async fn run_with_runtime(
  runtime : @agent_tool.AgentRuntime[Unit],
  api_key : String,
  model : @deepseek.Model,
  task : String,
  max_steps~ : Int,
  system_prompt_text~ : String,
) -> Unit {
  let client = @client.Client(
    api_key~,
    model~,
    thinking=Some(Enabled),
    reasoning_effort=Some(Max),
  )
  let tools = tool_definitions(runtime) catch {
    error => {
      log.at(ERROR) <? { "event": "agent_setup_failed", "error": "\{error}" }
      return
    }
  }
  let messages : Array[@deepseek.ChatMessage] = [
    ChatMessage(System, content=system_prompt_text),
    ChatMessage(User, content=task),
  ]
  for step in 0..<max_steps {
    if runtime_update_message(runtime.drain_events()) is Some(update) {
      log.at(INFO) <? { "event": "runtime_update", "content": update }
      messages.push(ChatMessage(User, content=update))
    }
    log.at(INFO) <? { "event": "agent_step", "step": step + 1 }
    let response = client.chat(messages, tools=tools.function_tools())
    if response.content != "" {
      log.at(INFO) <?
        { "event": "assistant_message", "content": response.content }
    }
    print_usage(response.usage)
    if response.tool_calls.length() == 0 {
      log.at(INFO) <? { "event": "agent_finished", "answer": response.content }
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
          log.at(ERROR) <?
            {
              "event": "tool_call_decode_error",
              "tool_call_id": native_call.id,
              "tool_name": native_call.name,
              "error": "\{error}",
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
          log.at(INFO) <? { "event": "agent_finished", "answer": answer }
          return
        }
        Control(Abort(reason)) => {
          log.at(WARN) <? { "event": "agent_aborted", "reason": reason }
          return
        }
        Respond(output) => output
      }
      log.at(INFO) <?
        {
          "event": "tool_result",
          "tool_call_id": native_call.id,
          "tool_name": tool_call.name,
          "is_error": output.is_error,
          "content": output.content,
        }
      messages.push(ChatMessage(Tool(native_call.id), content=output.content))
    }
  }
  log.at(WARN) <? { "event": "max_steps_exhausted" }
}

///|
fn runtime_update_message(events : Array[@agent_tool.AgentEvent]) -> String? {
  let latest_daemons : Map[String, @agent_tool.DaemonEvent] = {}
  let latest_moon_checks : Map[String, @agent_tool.MoonCheckSnapshot] = {}
  let mut daemon_count = 0
  let mut moon_check_count = 0
  for event in events {
    match event {
      DaemonUpdate(update) => {
        latest_daemons[update.id] = update
        daemon_count += 1
      }
      MoonCheckUpdate(update) => {
        latest_moon_checks[update.key] = update
        moon_check_count += 1
      }
    }
  }
  let count = daemon_count + moon_check_count
  if count == 0 {
    None
  } else if moon_check_count == 0 {
    let parts = [
      for update in latest_daemons.values() => daemon_update_text(update)
    ]
    Some("[check_daemon update]\nevents=\{daemon_count}\n" + parts.join("\n\n"))
  } else if daemon_count == 0 {
    let parts = [
      for update in latest_moon_checks.values() => {
        moon_check_update_text(update)
      }
    ]
    Some(
      "[moon_check update]\nevents=\{moon_check_count}\n" + parts.join("\n\n"),
    )
  } else {
    let daemon_parts = [
      for update in latest_daemons.values() => daemon_update_text(update)
    ]
    let moon_check_parts = [
      for update in latest_moon_checks.values() => {
        moon_check_update_text(update)
      }
    ]
    Some(
      "[runtime update]\nevents=\{count}\n\n[check_daemon]\nevents=\{daemon_count}\n" +
      daemon_parts.join("\n\n") +
      "\n\n[moon_check]\nevents=\{moon_check_count}\n" +
      moon_check_parts.join("\n\n"),
    )
  }
}

///|
fn daemon_update_text(update : @agent_tool.DaemonEvent) -> String {
  let name = match update.name {
    Some(name) => "\nname=\{name}"
    None => ""
  }
  let cwd = match update.cwd {
    Some(cwd) => cwd
    None => "."
  }
  let exit = match update.exit_code {
    Some(code) => "\nexit=\{code}"
    None => ""
  }
  let truncated = if update.output_truncated { "\ntruncated=true" } else { "" }
  let output = if update.output == "" {
    "\n(no output yet)"
  } else {
    "\n" + update.output
  }
  "id=\{update.id}\{name}\ncwd=\{cwd}\ncommand=\{update.command}\nstatus=\{daemon_status_label(update.status)}\nseq=\{update.seq}\{exit}\{truncated}\{output}"
}

///|
fn moon_check_update_text(update : @agent_tool.MoonCheckSnapshot) -> String {
  let cwd = match update.cwd {
    Some(cwd) => cwd
    None => "."
  }
  let exit = match update.exit_code {
    Some(code) => "\nexit=\{code}"
    None => ""
  }
  let truncated = if update.output_truncated { "\ntruncated=true" } else { "" }
  let restart = if update.restart_count > 0 || update.restart_reason is Some(_) {
    let reason = match update.restart_reason {
      Some(reason) => "\nrestart_reason=\{reason}"
      None => ""
    }
    "\nrestart_count=\{update.restart_count}\nrestart_limit=\{update.restart_limit}\{reason}"
  } else {
    ""
  }
  let output = if update.output == "" {
    "\n(no output yet)"
  } else {
    "\n" + update.output
  }
  "id=\{update.id}\ncwd=\{cwd}\ncommand=\{update.command}\nstatus=\{daemon_status_label(update.status)}\nseq=\{update.seq}\{exit}\{truncated}\{restart}\{output}"
}

///|
fn daemon_status_label(status : @agent_tool.DaemonStatus) -> String {
  match status {
    Running => "running"
    Stopped => "stopped"
  }
}

///|
test "daemon update message coalesces by daemon id" {
  let message = runtime_update_message([
    DaemonUpdate(
      DaemonEvent(
        id="daemon-1",
        name=Some("check"),
        command="moon check --watch",
        cwd=None,
        status=Running,
        seq=1,
        output="old",
        output_truncated=false,
        max_output_chars=12000,
        exit_code=None,
      ),
    ),
    DaemonUpdate(
      DaemonEvent(
        id="daemon-1",
        name=Some("check"),
        command="moon check --watch",
        cwd=None,
        status=Running,
        seq=2,
        output="new",
        output_truncated=false,
        max_output_chars=12000,
        exit_code=None,
      ),
    ),
  ])
  guard message is Some(text) else { fail("expected message") }
  assert_true(text.contains("events=2"))
  assert_true(text.contains("seq=2"))
  assert_true(text.contains("new"))
  assert_false(text.contains("old"))
}

///|
test "moon_check update message coalesces by watcher key" {
  let message = runtime_update_message([
    MoonCheckUpdate(
      MoonCheckSnapshot(
        id="moon-check-1",
        key="cwd=.",
        command="moon check --watch --output-json --diagnostic-limit 10",
        cwd=None,
        status=Running,
        seq=1,
        output="old",
        output_truncated=false,
        max_output_chars=12000,
        exit_code=None,
        restart_count=0,
        restart_limit=3,
        restart_reason=None,
      ),
    ),
    MoonCheckUpdate(
      MoonCheckSnapshot(
        id="moon-check-1",
        key="cwd=.",
        command="moon check --watch --output-json --diagnostic-limit 10",
        cwd=None,
        status=Running,
        seq=2,
        output="new",
        output_truncated=false,
        max_output_chars=12000,
        exit_code=None,
        restart_count=0,
        restart_limit=3,
        restart_reason=None,
      ),
    ),
  ])
  guard message is Some(text) else { fail("expected message") }
  assert_true(text.contains("[moon_check update]"))
  assert_true(text.contains("events=2"))
  assert_true(text.contains("seq=2"))
  assert_true(text.contains("new"))
  assert_false(text.contains("old"))
}

///|
let log : @logger.Logger = @logger.stdout(min_level=INFO)

///|
async fn print_usage(usage : @deepseek.Usage) -> Unit {
  log.at(INFO) <?
    {
      "event": "usage",
      "prompt_tokens": usage.prompt_tokens,
      "completion_tokens": usage.completion_tokens,
      "cache_hit_tokens": usage.prompt_cache_hit_tokens,
      "cache_miss_tokens": usage.prompt_cache_miss_tokens,
    }
}
