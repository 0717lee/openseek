///|
/// Tool definition for `check_daemon`: starts, inspects, and stops
/// session-scoped background monitor commands. Commands run through the
/// platform shell, optionally in `arguments.cwd`, and later output updates are
/// posted to the agent runtime event queue.
///
/// ## Arguments
/// - `action` (string, required): `start`, `status`, or `stop`.
/// - `cmd` (string, required for `start`): shell command to monitor.
/// - `cwd` (string, optional): working directory. Empty means current process
///   directory.
/// - `name` (string, optional): human label shown in update messages.
/// - `id` (string, required for `status` and `stop`): daemon id returned by
///   `start`.
/// - `max_output_chars` (number, optional): defaults to 12000 and is capped at
///   50000. The daemon keeps the latest retained output tail.
/// - `initial_wait_ms` (number, optional): defaults to 500 and is capped at
///   5000. `start` waits this long for initial output before responding.
pub fn[X] definition(
  runtime : @agent_tool.AgentRuntime[X],
) -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="check_daemon",
    description="Start, inspect, or stop a session-scoped background monitor command. Use it for long-running checks such as `moon check --watch --output-json` or review/status watchers. Unlike shell, this daemon tool intentionally allows monitored MoonBit commands.",
    schema=JsonSchema({
      "type": "object",
      "properties": {
        "action": { "type": "string", "enum": ["start", "status", "stop"] },
        "cmd": { "type": "string" },
        "cwd": { "type": "string" },
        "name": { "type": "string" },
        "id": { "type": "string" },
        "max_output_chars": { "type": "number" },
        "initial_wait_ms": { "type": "number" },
      },
      "required": ["action"],
    }),
    execute=Async(arguments => execute(runtime, arguments)),
  )
}

///|
async fn[X] execute(
  runtime : @agent_tool.AgentRuntime[X],
  arguments : Json,
) -> @agent_tool.ToolAction {
  let input = @decode.decode(arguments) catch {
    error => {
      let message = @tool_error.failure_message("\{error}")
      return @agent_tool.ToolAction::respond(
        "error: check_daemon requires \{message}",
        is_error=true,
      )
    }
  }
  try {
    match input.action {
      Start => start_daemon(runtime, input)
      Status => daemon_status(runtime, input)
      Stop => stop_daemon(runtime, input)
    }
  } catch {
    error if @async.is_being_cancelled() => raise error
    error =>
      @agent_tool.ToolAction::respond(
        "error running check_daemon: \{error}",
        is_error=true,
      )
  }
}

///|
async fn[X] start_daemon(
  runtime : @agent_tool.AgentRuntime[X],
  input : @decode.CheckDaemonInput,
) -> @agent_tool.ToolAction {
  guard input.cmd is Some(cmd) else {
    return @agent_tool.ToolAction::respond(
      "error: check_daemon requires arguments.cmd for action start",
      is_error=true,
    )
  }
  let cwd_check = validate_cwd(input.cwd)
  if cwd_check is Some(message) {
    return @agent_tool.ToolAction::respond(message, is_error=true)
  }
  let id = runtime.next_daemon_id()
  let (reader, writer) = @process.read_from_process()
  let process = @process.spawn(
    runtime.group(),
    platform_shell_program(),
    platform_shell_args(cmd),
    stdout=writer,
    stderr=writer,
    cwd?=input.cwd.map(cwd => cwd.view()),
    cancel_handler=@process.hard_cancel(),
    no_wait=true,
  )
  ignore(
    runtime.register_daemon(
      id~,
      name=input.name,
      command=cmd,
      cwd=input.cwd,
      process~,
      max_output_chars=input.max_output_chars,
    ),
  )
  runtime.group().spawn_bg(no_wait=true) <| () => {
    monitor_output(runtime, id, reader, process)
  }
  @async.sleep(input.initial_wait_ms)
  match runtime.daemon_event(id) {
    None =>
      @agent_tool.ToolAction::respond(
        "error: check_daemon lost daemon state for \{id}",
        is_error=true,
      )
    Some(event) =>
      @agent_tool.ToolAction::respond(
        daemon_response("started", event),
        is_error=false,
      )
  }
}

///|
async fn validate_cwd(cwd : String?) -> String? {
  match cwd {
    None => None
    Some(path) =>
      if !@fs.exists(path) {
        Some("error: cwd does not exist: \{path}")
      } else if @fs.kind(path) != Directory {
        Some("error: cwd is not a directory: \{path}")
      } else {
        None
      }
  }
}

///|
async fn[X] monitor_output(
  runtime : @agent_tool.AgentRuntime[X],
  id : String,
  reader : @process.ReadFromProcess,
  process : @process.Process,
) -> Unit {
  defer reader.close()
  for ;; {
    let chunk = reader.read_some(max_len=1024) catch {
      error if @async.is_being_cancelled() => raise error
      error => {
        ignore(
          runtime.record_daemon_output(
            id,
            "\n[check_daemon reader error: \{error}]\n",
          ),
        )
        ignore(runtime.mark_daemon_stopped(id, None))
        return
      }
    }
    match chunk {
      None => {
        let exit_code = process.wait()
        ignore(runtime.mark_daemon_stopped(id, Some(exit_code)))
        return
      }
      Some(bytes) =>
        ignore(runtime.record_daemon_output(id, @utf8.decode_lossy(bytes)))
    }
  }
}

///|
fn[X] daemon_status(
  runtime : @agent_tool.AgentRuntime[X],
  input : @decode.CheckDaemonInput,
) -> @agent_tool.ToolAction {
  guard input.id is Some(id) else {
    return @agent_tool.ToolAction::respond(
      "error: check_daemon requires arguments.id for action status",
      is_error=true,
    )
  }
  match runtime.daemon_event(id) {
    None =>
      @agent_tool.ToolAction::respond(
        "error: unknown check_daemon id=\{id}",
        is_error=true,
      )
    Some(event) =>
      @agent_tool.ToolAction::respond(daemon_response("status", event))
  }
}

///|
fn[X] stop_daemon(
  runtime : @agent_tool.AgentRuntime[X],
  input : @decode.CheckDaemonInput,
) -> @agent_tool.ToolAction {
  guard input.id is Some(id) else {
    return @agent_tool.ToolAction::respond(
      "error: check_daemon requires arguments.id for action stop",
      is_error=true,
    )
  }
  match runtime.stop_daemon(id) {
    None =>
      @agent_tool.ToolAction::respond(
        "error: unknown check_daemon id=\{id}",
        is_error=true,
      )
    Some(event) =>
      @agent_tool.ToolAction::respond(daemon_response("stopped", event))
  }
}

///|
fn daemon_response(action : String, event : @agent_tool.DaemonEvent) -> String {
  let name = match event.name {
    Some(name) => "\nname=\{name}"
    None => ""
  }
  let cwd = match event.cwd {
    Some(cwd) => cwd
    None => "."
  }
  let exit = match event.exit_code {
    Some(code) => "\nexit=\{code}"
    None => ""
  }
  let truncated = if event.output_truncated {
    "\ntruncated=true\nmax_output_chars=\{event.max_output_chars}"
  } else {
    ""
  }
  let output = if event.output == "" {
    "\n(no output yet)"
  } else {
    "\n" + event.output
  }
  "check_daemon \{action}\nid=\{event.id}\{name}\ncwd=\{cwd}\ncommand=\{event.command}\nstatus=\{daemon_status_label(event.status)}\nseq=\{event.seq}\{exit}\{truncated}\{output}"
}

///|
fn daemon_status_label(status : @agent_tool.DaemonStatus) -> String {
  match status {
    Running => "running"
    Stopped => "stopped"
  }
}

///|
#cfg(platform="windows")
fn platform_shell_program() -> String {
  "pwsh"
}

///|
#cfg(not(platform="windows"))
fn platform_shell_program() -> String {
  "sh"
}

///|
#cfg(platform="windows")
fn platform_shell_args(cmd : String) -> Array[String] {
  ["-NoProfile", "-Command", cmd]
}

///|
#cfg(not(platform="windows"))
fn platform_shell_args(cmd : String) -> Array[String] {
  ["-c", cmd]
}
