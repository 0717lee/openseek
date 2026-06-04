///|
/// Tool definition for `shell`: runs `arguments.cmd` through `sh -c`,
/// optionally in `arguments.cwd`, and returns the exit code plus merged
/// stdout/stderr output.
///
/// ## Arguments
/// - `cmd` (string, required): shell command line passed to `sh -c`.
/// - `cwd` (string, optional): working directory the command runs in.
///   An empty string is treated the same as a missing field.
/// - `max_output_chars` (number, optional): defaults to 12000 and is capped at
///   50000. Truncated output is reported as a tool error even when the process
///   exits zero.
/// - `timeout_ms` (number, optional): positive timeout in milliseconds. If the
///   command is still running after the timeout, the process is cancelled and
///   reported as a tool error.
///
/// ## Result
/// - `Respond(ToolOutput("exit=<code>\n<output>", is_error=<code != 0>))`
///   when `sh -c` runs. Non-zero exit codes are typed as tool errors while
///   preserving the full output for the model.
/// - `Respond(ToolOutput("error running shell: ...", is_error=true))` when
///   launching the process raises.
/// - `Respond(ToolOutput("error: shell requires ...", is_error=true))` for
///   invalid arguments.
pub fn definition() -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="shell",
    description="Run arguments.cmd through sh -c, optionally in arguments.cwd, and return exit code plus output.",
    schema=JsonSchema({
      "type": "object",
      "properties": {
        "cmd": { "type": "string" },
        "cwd": { "type": "string" },
        "timeout_ms": { "type": "number" },
        "max_output_chars": { "type": "number" },
      },
      "required": ["cmd"],
    }),
    execute=Async(execute),
  )
}

///|
async fn execute(arguments : Json) -> @agent_tool.ToolAction {
  let input = @decode.decode(arguments) catch {
    error => {
      let message = @tool_error.failure_message("\{error}")
      return @agent_tool.ToolAction::respond(
        "error: shell requires \{message}",
        is_error=true,
      )
    }
  }
  match @command_policy.moonbit_command_policy_error(input.cmd) {
    Some(message) =>
      return @agent_tool.ToolAction::respond(message, is_error=true)
    None => ()
  }
  shell(input) catch {
    error =>
      @agent_tool.ToolAction::respond(
        "error running shell: \{error}",
        is_error=true,
      )
  }
}

///|
async fn shell(input : @decode.ShellInput) -> @agent_tool.ToolAction {
  if input.cwd is Some(cwd) {
    let exists = @fs.exists(cwd)
    if !exists {
      return @agent_tool.ToolAction::respond(
        "error: cwd does not exist: \{cwd}",
        is_error=true,
      )
    }
    let kind = @fs.kind(cwd)
    if kind != Directory {
      return @agent_tool.ToolAction::respond(
        "error: cwd is not a directory: \{cwd}",
        is_error=true,
      )
    }
  }
  let result = match input.timeout_ms {
    Some(timeout_ms) =>
      @async.with_timeout_opt(timeout_ms, () => {
        collect_shell_output(input.cmd, input.cwd)
      })
    None => Some(collect_shell_output(input.cmd, input.cwd))
  }
  let (code, output) = match result {
    Some(result) => result
    None => {
      let timeout_ms = match input.timeout_ms {
        Some(timeout_ms) => timeout_ms
        None => 0
      }
      return @agent_tool.ToolAction::respond(
        "error: shell command timed out after \{timeout_ms}ms",
        is_error=true,
      )
    }
  }
  let body = output.text()
  let capped = cap_text(body, input.max_output_chars)
  let truncation = truncation_header(body, input.max_output_chars)
  @agent_tool.ToolAction::respond(
    "exit=\{code}\{truncation}\n\{capped}",
    is_error=code != 0 || is_truncated(body, input.max_output_chars),
  )
}

///|
async fn collect_shell_output(cmd : String, cwd : String?) -> (Int, &@io.Data) {
  match cwd {
    Some(cwd) => @process.collect_output_merged("sh", ["-c", cmd], cwd~)
    None => @process.collect_output_merged("sh", ["-c", cmd])
  }
}

///|
fn cap_text(content : String, max_chars : Int) -> String {
  if content.length() <= max_chars {
    content
  } else {
    content[:max_chars].to_owned()
  }
}

///|
fn is_truncated(content : String, max_chars : Int) -> Bool {
  content.length() > max_chars
}

///|
fn truncation_header(content : String, max_chars : Int) -> String {
  if is_truncated(content, max_chars) {
    "\ntruncated=true\noutput_chars=\{content.length()}\nshown_chars=\{max_chars}"
  } else {
    ""
  }
}

///|
test "shell parses and caps output limit" {
  let input = @decode.decode({
    "cmd": "echo hello",
    "cwd": "/tmp",
    "timeout_ms": 250,
    "max_output_chars": 999999,
  })
  assert_eq(input.cmd, "echo hello")
  assert_true(input.cwd is Some("/tmp"))
  assert_true(input.timeout_ms is Some(250))
  assert_eq(input.max_output_chars, @decode.hard_max_output_chars)
}

///|
test "shell records truncation metadata" {
  assert_eq(cap_text("abcdef", 3), "abc")
  assert_true(is_truncated("abcdef", 3))
  assert_eq(
    truncation_header("abcdef", 3),
    "\ntruncated=true\noutput_chars=6\nshown_chars=3",
  )
}
