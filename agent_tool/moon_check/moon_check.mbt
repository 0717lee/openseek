///|
/// Tool definition for `moon_check`: starts or reuses a session-scoped
/// `moon check --watch --output-json --diagnostic-limit 10` watcher for the
/// given check arguments. Repeated calls with the same arguments return the
/// latest watcher snapshot instead of starting another process.
///
/// ## Arguments
/// - `cwd` (string, optional): working directory. Empty means current process
///   directory.
/// - `path` (string, optional): one package path to pass as `--package-path`.
/// - `paths` (array of strings, optional): additional paths. Watch mode rejects
///   more than one path because Moon rejects positional paths with `--watch`.
/// - `target` (string, optional): one of MoonBit's `moon check --target`
///   values.
/// - `warn_list` (string, optional): value for `--warn-list`.
/// - `deny_warn` (bool, optional): add `--deny-warn` when true.
/// - `fmt` (bool, optional): add `--fmt` when true.
/// - `explain` (bool, optional): add `--explain` when true.
///
/// ## Result
/// - `Respond(ToolOutput("cwd=...\ncommand=...\nwatcher=...\n...",
///   is_error=<latest check has errors>))` when `moon` runs or is already
///   running.
/// - `Respond(ToolOutput("error running moon_check: ...", is_error=true))`
///   when launching the process raises.
/// - `Respond(ToolOutput("error: moon_check requires ...", is_error=true))`
///   for invalid arguments.
pub fn[X] definition(
  runtime : @agent_tool.AgentRuntime[X],
) -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="moon_check",
    description="Start or inspect a persistent `moon check --watch --output-json --diagnostic-limit 10` watcher for the given cwd/paths/options. The first call starts the watcher; later calls with the same arguments return the latest snapshot without starting another watcher.",
    schema=JsonSchema({
      "type": "object",
      "properties": {
        "cwd": { "type": "string" },
        "path": { "type": "string" },
        "paths": { "type": "array", "items": { "type": "string" } },
        "target": {
          "type": "string",
          "enum": ["wasm", "wasm-gc", "js", "native", "llvm", "all"],
        },
        "warn_list": { "type": "string" },
        "deny_warn": { "type": "boolean" },
        "fmt": { "type": "boolean" },
        "explain": { "type": "boolean" },
      },
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
        "error: moon_check requires \{message}",
        is_error=true,
      )
    }
  }
  moon_check(runtime, input) catch {
    error if @async.is_being_cancelled() => raise error
    error =>
      @agent_tool.ToolAction::respond(
        "error running moon_check: \{error}",
        is_error=true,
      )
  }
}

///|
let default_initial_wait_ms : Int = 1000

///|
let default_max_output_chars : Int = 12000

///|
let default_diagnostic_limit : Int = 10

///|
fn command_args(input : @decode.MoonCheckInput, watch~ : Bool) -> Array[String] {
  let args : Array[String] = ["check"]
  if watch {
    args.push("--watch")
  }
  args.push("--output-json")
  args.push("--diagnostic-limit")
  args.push(default_diagnostic_limit.to_string())
  match input.target {
    Some(target) => {
      args.push("--target")
      args.push(target)
    }
    None => ()
  }
  match input.warn_list {
    Some(warn_list) => {
      args.push("--warn-list")
      args.push(warn_list)
    }
    None => ()
  }
  if input.deny_warn {
    args.push("--deny-warn")
  }
  if input.fmt {
    args.push("--fmt")
  }
  if input.explain {
    args.push("--explain")
  }
  if watch {
    if input.paths.length() == 1 {
      args.push("--package-path")
      args.push(input.paths[0])
    }
  } else {
    for path in input.paths {
      args.push(path)
    }
  }
  args
}

///|
async fn[X] moon_check(
  runtime : @agent_tool.AgentRuntime[X],
  input : @decode.MoonCheckInput,
) -> @agent_tool.ToolAction {
  if input.paths.length() > 1 {
    return @agent_tool.ToolAction::respond(
      "error: moon_check watch mode supports at most one package path; `moon check --watch` rejects positional path lists",
      is_error=true,
    )
  }
  let key = moon_check_key(input)
  match runtime.moon_check_snapshot(key) {
    Some(snapshot) if snapshot.status is Running =>
      @agent_tool.ToolAction::respond(
        moon_check_response("reused", snapshot),
        is_error=moon_check_snapshot_is_error(snapshot),
      )
    Some(_) => start_moon_check(runtime, input, key, action="restarted")
    None => start_moon_check(runtime, input, key, action="started")
  }
}

///|
async fn[X] start_moon_check(
  runtime : @agent_tool.AgentRuntime[X],
  input : @decode.MoonCheckInput,
  key : String,
  action~ : String,
) -> @agent_tool.ToolAction {
  let args = command_args(input, watch=true)
  let id = runtime.next_moon_check_id()
  let (reader, writer) = @process.read_from_process()
  let process = @process.spawn(
    runtime.group(),
    "moon",
    args,
    stdout=writer,
    stderr=writer,
    cwd?=input.cwd.map(cwd => cwd.view()),
    cancel_handler=@process.hard_cancel(),
    no_wait=true,
  )
  ignore(
    runtime.register_moon_check(
      key~,
      id~,
      command="moon \{args.join(" ")}",
      cwd=input.cwd,
      process~,
      max_output_chars=default_max_output_chars,
    ),
  )
  runtime.group().spawn_bg(no_wait=true, allow_failure=true) <| () => {
    monitor_moon_check(runtime, key, reader, process)
  }
  wait_for_initial_snapshot(runtime, key)
  match runtime.moon_check_snapshot(key) {
    None =>
      @agent_tool.ToolAction::respond(
        "error: moon_check lost watcher state for \{id}",
        is_error=true,
      )
    Some(snapshot) =>
      @agent_tool.ToolAction::respond(
        moon_check_response(action, snapshot),
        is_error=moon_check_snapshot_is_error(snapshot),
      )
  }
}

///|
async fn[X] wait_for_initial_snapshot(
  runtime : @agent_tool.AgentRuntime[X],
  key : String,
) -> Unit {
  let ticks = default_initial_wait_ms / 50
  for _ in 0..<ticks {
    match runtime.moon_check_snapshot(key) {
      Some(snapshot) if snapshot.output != "" || snapshot.status is Stopped =>
        return
      _ => @async.sleep(50)
    }
  }
}

///|
async fn[X] monitor_moon_check(
  runtime : @agent_tool.AgentRuntime[X],
  key : String,
  reader : @process.ReadFromProcess,
  process : @process.Process,
) -> Unit {
  defer reader.close()
  for ;; {
    let chunk = reader.read_some(max_len=1024) catch {
      error if @async.is_being_cancelled() => raise error
      error => {
        ignore(
          runtime.record_moon_check_output(
            key,
            "\n[moon_check reader error: \{error}]\n",
          ),
        )
        ignore(runtime.mark_moon_check_stopped(key, None))
        return
      }
    }
    match chunk {
      None => {
        let exit_code = process.wait()
        ignore(runtime.mark_moon_check_stopped(key, Some(exit_code)))
        return
      }
      Some(bytes) =>
        ignore(runtime.record_moon_check_output(key, @utf8.decode_lossy(bytes)))
    }
  }
}

///|
fn moon_check_response(
  watcher : String,
  snapshot : @agent_tool.MoonCheckSnapshot,
) -> String {
  let cwd_text = match snapshot.cwd {
    Some(cwd) => cwd
    None => "."
  }
  let exit = match snapshot.exit_code {
    Some(code) => "\nexit=\{code}"
    None => ""
  }
  let truncated = if snapshot.output_truncated {
    "\ntruncated=true\nmax_output_chars=\{snapshot.max_output_chars}"
  } else {
    ""
  }
  let output = if snapshot.output == "" {
    "\n(no output yet)"
  } else {
    "\n" + snapshot.output
  }
  "cwd=\{cwd_text}\ncommand=\{snapshot.command}\nwatcher=\{watcher}\nid=\{snapshot.id}\nstatus=\{moon_check_status_label(snapshot.status)}\nseq=\{snapshot.seq}\{exit}\{truncated}\{output}"
}

///|
fn moon_check_status_label(status : @agent_tool.DaemonStatus) -> String {
  match status {
    Running => "running"
    Stopped => "stopped"
  }
}

///|
fn moon_check_snapshot_is_error(
  snapshot : @agent_tool.MoonCheckSnapshot,
) -> Bool {
  match snapshot.exit_code {
    Some(code) if code != 0 => true
    _ =>
      snapshot.output.contains("Had errors, waiting for filesystem changes...") ||
      snapshot.output.contains("\"level\":\"error\"") ||
      snapshot.output.contains("ERROR Run failed") ||
      snapshot.output.contains("Error: failed when checking project")
  }
}

///|
fn moon_check_key(input : @decode.MoonCheckInput) -> String {
  let cwd = match input.cwd {
    Some(cwd) => cwd
    None => "."
  }
  let target = match input.target {
    Some(target) => target
    None => ""
  }
  let warn_list = match input.warn_list {
    Some(warn_list) => warn_list
    None => ""
  }
  "cwd=\{cwd}\ntarget=\{target}\nwarn_list=\{warn_list}\ndeny_warn=\{input.deny_warn}\nfmt=\{input.fmt}\nexplain=\{input.explain}\npaths=\{input.paths.join("\n")}"
}

///|
async test "moon_check advertises expected schema" {
  @async.with_task_group() <| group => {
    let tool = definition(AgentRuntime(group))
    assert_eq(tool.name, "moon_check")
    let JsonSchema(schema) = tool.schema
    let text = schema.stringify()
    assert_true(text.contains("\"path\""))
    assert_true(text.contains("\"paths\""))
    assert_true(text.contains("\"target\""))
  }
}

///|
test "moon_check builds direct moon command arguments" {
  let input = @decode.decode({
    "cwd": "/tmp",
    "paths": ["agent", "README.mbt.md"],
    "target": "native",
    "warn_list": "+unnecessary_annotation",
    "deny_warn": true,
    "fmt": true,
    "explain": true,
  })
  assert_eq(
    command_args(input, watch=false).join("|"),
    "check|--output-json|--diagnostic-limit|10|--target|native|--warn-list|+unnecessary_annotation|--deny-warn|--fmt|--explain|agent|README.mbt.md",
  )
}

///|
test "moon_check builds watch command arguments" {
  let input = @decode.decode({ "target": "native", "path": "agent" })
  assert_eq(
    command_args(input, watch=true).join("|"),
    "check|--watch|--output-json|--diagnostic-limit|10|--target|native|--package-path|agent",
  )
}

///|
test "moon_check parses path and paths together" {
  let input = @decode.decode({
    "path": "agent",
    "paths": ["agent_tool/read", "agent_tool/write"],
  })
  assert_eq(input.paths.join("|"), "agent|agent_tool/read|agent_tool/write")
}

///|
test "moon_check rejects invalid target" {
  let _ = @decode.decode({ "target": "browser" }) catch {
    error => {
      assert_true("\{error}".contains("arguments.target"))
      return
    }
  }
  fail("invalid target parsed")
}

///|
async test "moon_check rejects multiple watch paths" {
  @async.with_task_group() <| group => {
    let result = execute(AgentRuntime(group), {
      "paths": ["agent", "agent_tool"],
    })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("supports at most one package path"))
  }
}

///|
async test "moon_check rejects non-object arguments" {
  @async.with_task_group() <| group => {
    let result = execute(AgentRuntime(group), Json::null())
    guard result is Respond(output) else { fail("expected Respond") }
    assert_eq(output.content, "error: moon_check requires object arguments")
    assert_true(output.is_error)
  }
}

///|
async test "moon_check validates a real fixture project" {
  let project = copy_fixture_project("valid_project")
  let canonical = @fs.realpath(project)
  @async.with_task_group() <| group => {
    let runtime = @agent_tool.AgentRuntime(group)
    let result = execute(runtime, { "cwd": project })
    ignore(
      runtime.stop_moon_check(
        moon_check_key(@decode.decode({ "cwd": project })),
      ),
    )
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    inspect(
      stable_moon_check_output(output.content, project, canonical),
      content=(
        #|cwd=<fixture>
        #|command=moon check --watch --output-json --diagnostic-limit 10
        #|watcher=started
        #|id=moon-check-1
        #|status=running
        #|seq=<seq>
        #|Finished. moon: ran 2 tasks, now up to date
        #|Success, waiting for filesystem changes...
      ),
    )
  }
  @fs.rmdir(project, recursive=true)
}

///|
async test "moon_check reuses a running watcher for the same arguments" {
  let project = copy_fixture_project("valid_project")
  @async.with_task_group() <| group => {
    let runtime = @agent_tool.AgentRuntime(group)
    let args : Json = { "cwd": project }
    let first = execute(runtime, args)
    let second = execute(runtime, args)
    ignore(runtime.stop_moon_check(moon_check_key(@decode.decode(args))))
    guard first is Respond(first_output) else { fail("expected Respond") }
    guard second is Respond(second_output) else { fail("expected Respond") }
    assert_false(first_output.is_error)
    assert_false(second_output.is_error)
    assert_true(first_output.content.contains("watcher=started"))
    assert_true(first_output.content.contains("id=moon-check-1"))
    assert_true(second_output.content.contains("watcher=reused"))
    assert_true(second_output.content.contains("id=moon-check-1"))
    assert_false(second_output.content.contains("id=moon-check-2"))
  }
  @fs.rmdir(project, recursive=true)
}

///|
async test "moon_check reports diagnostics from a broken fixture project" {
  let project = copy_fixture_project("invalid_project")
  let canonical = @fs.realpath(project)
  @async.with_task_group() <| group => {
    let runtime = @agent_tool.AgentRuntime(group)
    let result = execute(runtime, { "cwd": project })
    ignore(
      runtime.stop_moon_check(
        moon_check_key(@decode.decode({ "cwd": project })),
      ),
    )
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    inspect(
      stable_moon_check_output(output.content, project, canonical),
      content=(
        #|cwd=<fixture>
        #|command=moon check --watch --output-json --diagnostic-limit 10
        #|watcher=started
        #|id=moon-check-1
        #|status=running
        #|seq=<seq>
        #|{"$message_type":"diagnostic","level":"error","error_code":4014,"path":"<fixture>/lib.mbt","loc":"3:3-3:15","message":"Expr Type Mismatch\n        has type : String\n        wanted   : Int"}
        #|Failed with 0 warnings, 1 errors.
        #|ERROR Run failed with error error=failed when checking project
        #|failed when checking project
        #|Had errors, waiting for filesystem changes...
      ),
    )
  }
  @fs.rmdir(project, recursive=true)
}

///|
async test "moon_check validates a virtual filesystem package path" {
  let project = @fs.tmpdir(prefix="openseek-moon-check-vfs-")
  @vfs.FileSystem({
    "moon.mod": (
      #|name = "openseek/moon_check_vfs_fixture"
      #|
      #|version = "0.1.0"
      #|
      #|preferred_target = "native"
      #|
    ),
    "math/moon.pkg": (
      #|warnings = "+unnecessary_annotation"
      #|
    ),
    "math/math.mbt": (
      #|///|
      #|pub fn add(left : Int, right : Int) -> Int {
      #|  left + right
      #|}
      #|
    ),
  }).write_to(project)
  let canonical = @fs.realpath(project)
  @async.with_task_group() <| group => {
    let runtime = @agent_tool.AgentRuntime(group)
    let args : Json = { "cwd": project, "path": "math", "target": "native" }
    let result = execute(runtime, args)
    ignore(runtime.stop_moon_check(moon_check_key(@decode.decode(args))))
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    inspect(
      stable_moon_check_output(output.content, project, canonical),
      content=(
        #|cwd=<fixture>
        #|command=moon check --watch --output-json --diagnostic-limit 10 --target native --package-path math
        #|watcher=started
        #|id=moon-check-1
        #|status=running
        #|seq=<seq>
        #|Finished. moon: ran 2 tasks, now up to date
        #|Success, waiting for filesystem changes...
      ),
    )
  }
  @fs.rmdir(project, recursive=true)
}

///|
async fn copy_fixture_project(name : String) -> String {
  let target = @fs.tmpdir(prefix="openseek-moon-check-")
  copy_fixture_file(name, "moon.mod.fixture", target + "/moon.mod")
  copy_fixture_file(name, "moon.pkg.fixture", target + "/moon.pkg")
  copy_fixture_file(name, "lib.mbt.fixture", target + "/lib.mbt")
  target
}

///|
async fn copy_fixture_file(
  fixture : String,
  file : String,
  target : String,
) -> Unit {
  let content = @fs.read_file(
    "agent_tool/moon_check/fixtures/\{fixture}/\{file}",
  ).text()
  @fs.write_file(target, content, create_mode=CreateOrTruncate)
}

///|
fn stable_moon_check_output(
  content : String,
  project : String,
  canonical : String,
) -> String {
  let normalized = content
    .replace_all(old=canonical, new="<fixture>")
    .replace_all(old=project, new="<fixture>")
  let stable_lines : Array[String] = []
  for line in normalized.split("\n") {
    if line.has_prefix("seq=") {
      stable_lines.push("seq=<seq>")
    } else if !line.has_prefix("failed: ") {
      stable_lines.push(line.to_owned())
    }
  }
  stable_lines.join("\n").trim().to_owned()
}
