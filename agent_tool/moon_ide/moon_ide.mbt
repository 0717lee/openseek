///|
/// Tool definition for `moon_ide`: runs read-only `moon ide` semantic
/// navigation commands directly, optionally in `arguments.cwd`, and returns the
/// real process exit code plus merged stdout/stderr output.
///
/// ## Arguments
/// - `action` (string, required): one of `doc`, `outline`, `peek_def`,
///   `hover`, or `find_references`.
/// - `cwd` (string, optional): working directory. Empty means current process
///   directory.
/// - `query` (string, optional): required for `doc`, `peek_def`, `hover`, and
///   `find_references`.
/// - `path` (string, optional): required for `outline`.
/// - `loc` (string, optional): required for `hover`, optional for `peek_def`
///   and `find_references`; format is `path[:line[:col]]`.
/// - `target` (string, optional): one of MoonBit's `moon ide --target` values.
/// - `no_check` (bool, optional): defaults to false; when true, adds
///   `--no-check`.
/// - `max_output_chars` (number, optional): defaults to 12000 and is capped at
///   50000.
///
/// ## Result
/// - `Respond(ToolOutput("cwd=...\ncommand=...\nexit=<code>\n<output>",
///   is_error=<code != 0>))` when `moon ide` runs.
/// - `Respond(ToolOutput("error running moon_ide: ...", is_error=true))`
///   when launching the process raises.
/// - `Respond(ToolOutput("error: moon_ide requires ...", is_error=true))`
///   for invalid arguments.
pub fn definition() -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="moon_ide",
    description="Run read-only moon ide semantic navigation commands directly and return exit code plus output.",
    schema=JsonSchema({
      "type": "object",
      "properties": {
        "action": {
          "type": "string",
          "enum": ["doc", "outline", "peek_def", "hover", "find_references"],
        },
        "cwd": { "type": "string" },
        "query": { "type": "string" },
        "path": { "type": "string" },
        "loc": { "type": "string" },
        "target": {
          "type": "string",
          "enum": ["wasm", "wasm-gc", "js", "native", "llvm", "all"],
        },
        "no_check": { "type": "boolean" },
        "max_output_chars": { "type": "number" },
      },
      "required": ["action"],
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
        "error: moon_ide requires \{message}",
        is_error=true,
      )
    }
  }
  moon_ide(input) catch {
    error =>
      @agent_tool.ToolAction::respond(
        "error running moon_ide: \{error}",
        is_error=true,
      )
  }
}

///|
fn command_args(input : @decode.MoonIdeInput) -> Array[String] {
  let args : Array[String] = ["ide", command_action(input)]
  if input.no_check {
    args.push("--no-check")
  }
  match input.target {
    Some(target) => {
      args.push("--target")
      args.push(target)
    }
    None => ()
  }
  match input.loc {
    Some(loc) => {
      args.push("--loc")
      args.push(loc)
    }
    None => ()
  }
  match input.action {
    "outline" =>
      match input.path {
        Some(path) => args.push(path)
        None => ()
      }
    _ =>
      match input.query {
        Some(query) => args.push(query)
        None => ()
      }
  }
  args
}

///|
fn command_action(input : @decode.MoonIdeInput) -> String {
  match input.action {
    "peek_def" => "peek-def"
    "find_references" => "find-references"
    other => other
  }
}

///|
async fn moon_ide(input : @decode.MoonIdeInput) -> @agent_tool.ToolAction {
  let args = command_args(input)
  let cwd = match input.cwd {
    Some(cwd) => Some(@fs.realpath(cwd))
    None => None
  }
  let (code, output) = match cwd {
    Some(cwd) => @process.collect_output_merged("moon", args, cwd~)
    None => @process.collect_output_merged("moon", args)
  }
  let cwd_text = match cwd {
    Some(cwd) => cwd
    None => "."
  }
  let body = output.text()
  let capped = cap_text(body, input.max_output_chars)
  let truncation = truncation_header(body, input.max_output_chars)
  @agent_tool.ToolAction::respond(
    "cwd=\{cwd_text}\ncommand=moon \{args.join(" ")}\nexit=\{code}\{truncation}\n\{capped}",
    is_error=code != 0,
  )
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
fn truncation_header(content : String, max_chars : Int) -> String {
  if content.length() <= max_chars {
    ""
  } else {
    "\ntruncated=true\noutput_chars=\{content.length()}\nshown_chars=\{max_chars}"
  }
}

///|
test "moon_ide advertises expected schema" {
  let tool = definition()
  assert_eq(tool.name, "moon_ide")
  let JsonSchema(schema) = tool.schema
  let text = schema.stringify()
  assert_true(text.contains("\"doc\""))
  assert_true(text.contains("\"outline\""))
  assert_true(text.contains("\"peek_def\""))
  assert_true(text.contains("\"hover\""))
  assert_true(text.contains("\"find_references\""))
  assert_true(text.contains("\"max_output_chars\""))
}

///|
test "moon_ide builds direct doc command arguments" {
  let input = @decode.decode({
    "action": "doc",
    "cwd": "/tmp",
    "query": "String::replace_all",
    "no_check": true,
  })
  assert_eq(
    command_args(input).join("|"),
    "ide|doc|--no-check|String::replace_all",
  )
}

///|
test "moon_ide builds loc-aware navigation command arguments" {
  let input = @decode.decode({
    "action": "peek_def",
    "query": "render",
    "loc": "lib.mbt:14:8",
    "target": "native",
  })
  assert_eq(
    command_args(input).join("|"),
    "ide|peek-def|--target|native|--loc|lib.mbt:14:8|render",
  )
}

///|
test "moon_ide parses outline path" {
  let input = @decode.decode({
    "action": "outline",
    "path": "agent_tool/moon_ide",
    "max_output_chars": 42,
  })
  assert_eq(command_args(input).join("|"), "ide|outline|agent_tool/moon_ide")
  assert_eq(input.max_output_chars, 42)
}

///|
test "moon_ide caps oversized output limit" {
  let input = @decode.decode({
    "action": "doc",
    "query": "String",
    "max_output_chars": 999999,
  })
  assert_eq(input.max_output_chars, @decode.hard_max_output_chars)
}

///|
test "moon_ide rejects invalid action" {
  let _ = @decode.decode({ "action": "rename", "query": "old_name" }) catch {
    error => {
      assert_true("\{error}".contains("arguments.action"))
      return
    }
  }
  fail("invalid action parsed")
}

///|
test "moon_ide rejects missing required fields" {
  let _ = @decode.decode({ "action": "hover", "query": "Widget" }) catch {
    error => {
      assert_true("\{error}".contains("arguments.loc"))
      return
    }
  }
  fail("hover without loc parsed")
}

///|
test "moon_ide records truncation metadata" {
  assert_eq(cap_text("abcdef", 3), "abc")
  assert_eq(
    truncation_header("abcdef", 3),
    "\ntruncated=true\noutput_chars=6\nshown_chars=3",
  )
}

///|
async test "moon_ide rejects non-object arguments" {
  let result = execute(Json::null())
  guard result is Respond(output) else { fail("expected Respond") }
  assert_eq(output.content, "error: moon_ide requires object arguments")
  assert_true(output.is_error)
}

///|
#cfg(platform="windows")
async test "moon_ide normalizes fixture paths on Windows" {
  let project = copy_fixture_project("simple_project")
  let canonical = @fs.realpath(project)
  let stable = stable_moon_ide_output(
    "cwd=\{project}\npath=\{canonical}\\lib.mbt",
    project,
    canonical,
  )
  @fs.rmdir(project, recursive=true)
  assert_true(stable.contains("cwd=<fixture>"))
  assert_true(stable.contains("path=<fixture>/lib.mbt"))
}

///|
async test "moon_ide looks up fixture documentation" {
  let project = copy_fixture_project("simple_project")
  let canonical = @fs.realpath(project)
  let result = execute({
    "cwd": project,
    "action": "doc",
    "query": "render",
    "max_output_chars": 2000,
  })
  @fs.rmdir(project, recursive=true)
  guard result is Respond(output) else { fail("expected Respond") }
  let stable = stable_moon_ide_output(output.content, project, canonical).trim()
  if output.is_error {
    fail("moon_ide failed:\n\{stable}")
  }
  assert_true(stable.contains("cwd=<fixture>"))
  assert_true(stable.contains("command=moon ide doc render"))
  assert_true(stable.contains("pub fn render(Widget) -> String"))
}

///|
async test "moon_ide outlines a real fixture package" {
  let project = copy_fixture_project("simple_project")
  let canonical = @fs.realpath(project)
  let result = execute({ "cwd": project, "action": "outline", "path": "." })
  @fs.rmdir(project, recursive=true)
  guard result is Respond(output) else { fail("expected Respond") }
  let stable = stable_moon_ide_output(output.content, project, canonical)
  if output.is_error {
    fail("moon_ide failed:\n\{stable}")
  }
  inspect(
    stable.trim(),
    content=(
      #|cwd=<fixture>
      #|command=moon ide outline .
      #|exit=0
      #|lib.mbt:
      #| L02 | pub struct Widget {
      #|       ...
      #| L07 | pub fn Widget::new(name : String) -> Widget {
      #|       ...
      #| L12 | pub fn Widget::label(self : Widget) -> String {
      #|       ...
      #| L17 | pub fn render(widget : Widget) -> String {
      #|       ...
    ),
  )
}

///|
async test "moon_ide peeks a definition in a real fixture package" {
  let project = copy_fixture_project("simple_project")
  let canonical = @fs.realpath(project)
  let result = execute({
    "cwd": project,
    "action": "peek_def",
    "query": "render",
    "loc": "lib.mbt",
  })
  @fs.rmdir(project, recursive=true)
  guard result is Respond(output) else { fail("expected Respond") }
  let stable = stable_moon_ide_output(output.content, project, canonical)
  if output.is_error {
    fail("moon_ide failed:\n\{stable}")
  }
  assert_true(stable.contains("cwd=<fixture>"))
  assert_true(stable.contains("command=moon ide peek-def --loc lib.mbt render"))
  assert_true(stable.contains("pub fn render(widget : Widget) -> String"))
}

///|
async test "moon_ide hovers a token in a real fixture package" {
  let project = copy_fixture_project("simple_project")
  let canonical = @fs.realpath(project)
  let result = execute({
    "cwd": project,
    "action": "hover",
    "query": "Widget",
    "loc": "lib.mbt:17:24",
  })
  @fs.rmdir(project, recursive=true)
  guard result is Respond(output) else { fail("expected Respond") }
  let stable = stable_moon_ide_output(output.content, project, canonical)
  if output.is_error {
    fail("moon_ide failed:\n\{stable}")
  }
  assert_true(stable.contains("cwd=<fixture>"))
  assert_true(
    stable.contains("command=moon ide hover --loc lib.mbt:17:24 Widget"),
  )
  assert_true(stable.contains("struct Widget"))
}

///|
async test "moon_ide finds references in a real fixture package" {
  let project = copy_fixture_project("simple_project")
  let canonical = @fs.realpath(project)
  let result = execute({
    "cwd": project,
    "action": "find_references",
    "query": "Widget::label",
    "loc": "lib.mbt",
  })
  @fs.rmdir(project, recursive=true)
  guard result is Respond(output) else { fail("expected Respond") }
  let stable = stable_moon_ide_output(output.content, project, canonical)
  if output.is_error {
    fail("moon_ide failed:\n\{stable}")
  }
  assert_true(stable.contains("cwd=<fixture>"))
  assert_true(
    stable.contains(
      "command=moon ide find-references --loc lib.mbt Widget::label",
    ),
  )
  assert_true(stable.contains("Found "))
  assert_true(stable.contains("widget.label()"))
}

///|
async test "moon_ide outlines a virtual filesystem multi-file package" {
  let project = workspace_tmpdir(prefix="openseek-moon-ide-vfs-")
  @vfs.FileSystem({
    "moon.mod": (
      #|name = "openseek/moon_ide_vfs_fixture"
      #|
      #|version = "0.1.0"
      #|
    ),
    "moon.pkg": (
      #|warnings = "+unnecessary_annotation"
      #|
    ),
    "model.mbt": (
      #|///|
      #|pub struct User {
      #|  name : String
      #|} derive(Debug, Eq)
      #|
      #|///|
      #|pub fn User::new(name : String) -> User {
      #|  { name }
      #|}
      #|
      #|///|
      #|pub fn User::label(self : User) -> String {
      #|  "user:" + self.name
      #|}
      #|
    ),
    "render.mbt": (
      #|///|
      #|pub fn render_user(user : User) -> String {
      #|  user.label()
      #|}
      #|
      #|///|
      #|pub fn sample() -> String {
      #|  render_user(User::new("ada"))
      #|}
      #|
    ),
  }).write_to(project)
  let canonical = @fs.realpath(project)
  let result = execute({
    "cwd": project,
    "action": "outline",
    "path": ".",
    "max_output_chars": 4000,
  })
  @fs.rmdir(project, recursive=true)
  guard result is Respond(output) else { fail("expected Respond") }
  let stable = stable_moon_ide_output(output.content, project, canonical)
  if output.is_error {
    fail("moon_ide failed:\n\{stable}")
  }
  inspect(
    stable.trim(),
    content=(
      #|cwd=<fixture>
      #|command=moon ide outline .
      #|exit=0
      #|render.mbt:
      #| L2 | pub fn render_user(user : User) -> String {
      #|      ...
      #| L7 | pub fn sample() -> String {
      #|      ...
      #|
      #|model.mbt:
      #| L02 | pub struct User {
      #|       ...
      #| L07 | pub fn User::new(name : String) -> User {
      #|       ...
      #| L12 | pub fn User::label(self : User) -> String {
      #|       ...
    ),
  )
}

///|
async fn copy_fixture_project(name : String) -> String {
  let target = workspace_tmpdir(prefix="openseek-moon-ide-")
  let target_path : @path.Path = target
  copy_fixture_file(
    name,
    "moon.mod.fixture",
    target_path.join("moon.mod").normalize().to_string(),
  )
  copy_fixture_file(
    name,
    "moon.pkg.fixture",
    target_path.join("moon.pkg").normalize().to_string(),
  )
  copy_fixture_file(
    name,
    "lib.mbt.fixture",
    target_path.join("lib.mbt").normalize().to_string(),
  )
  target
}

///|
async fn workspace_tmpdir(prefix~ : String) -> String {
  let parent_dir = "_build/openseek-moon-ide-tmp"
  @fs.mkdir(parent_dir, recursive=true) catch {
    error =>
      if @fs.exists(parent_dir) && @fs.kind(parent_dir) == Directory {
        ()
      } else {
        raise error
      }
  }
  let scratch = @fs.tmpdir(prefix~)
  let scratch_path : @path.Path = scratch
  let name = scratch_path.basename().to_owned()
  @fs.rmdir(scratch, recursive=true)
  let parent = @fs.realpath(parent_dir)
  let parent_path : @path.Path = parent
  let target = parent_path.join(name).normalize().to_string()
  @fs.mkdir(target)
  target
}

///|
async fn copy_fixture_file(
  fixture : String,
  file : String,
  target : String,
) -> Unit {
  let content = @fs.read_file("agent_tool/moon_ide/fixtures/\{fixture}/\{file}").text()
  @fs.write_file(target, content, create_mode=CreateOrTruncate)
}

///|
fn stable_moon_ide_output(
  content : String,
  project : String,
  canonical : String,
) -> String {
  @test_output.redact_fixture_root(content, root=project, canonical~)
}
