///|
/// Tool definition for `read`: returns text from `arguments.path`, optionally
/// restricted to a line range and capped to avoid flooding the agent context.
/// When several known independent files are needed, prefer batching several
/// single-file `read` tool calls in one assistant response.
///
/// ## Arguments
/// - `path` (string): filesystem path to read. Required. Directories are not
///   supported; use `ls` or `tree` first, then read specific files.
/// - `start_line` (number, optional): 1-based first line to return. Defaults
///   to 1. Single-file calls only.
/// - `max_lines` (number, optional): maximum number of lines to return.
///   Single-file calls only.
/// - `max_output_chars` (number, optional): maximum rendered content chars
///   for the whole call, including line-number gutters when present. Defaults
///   to 12000 and is capped at 50000.
///
/// ## Result
/// - `Respond(ToolOutput(<file contents>))` on success for uncapped whole-file
///   single reads.
/// - `Respond(ToolOutput(<metadata header + numbered content>))` for ranged
///   reads or capped reads.
/// - `Respond(ToolOutput("error reading <path>: <error>", is_error=true))`
///   if a single-file read fails (missing file, permission denied, invalid
///   UTF-8, directory path, etc.).
/// - `Respond(ToolOutput("error: read requires ...", is_error=true))` for
///   invalid arguments.
pub fn definition(
  workspace_root? : String = ".",
) -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="read",
    description="Read arguments.path as text. For several known independent files, batch separate read tool calls in one assistant response when possible. Do not use read for directories: inspect them with `ls` or `tree`, then read specific files. Supports optional start_line, max_lines, and max_output_chars for focused single-file reads. Headered outputs include right-aligned line numbers.",
    schema=JsonSchema({
      "type": "object",
      "required": ["path"],
      "properties": {
        "path": {
          "type": "string",
          "description": "Text file path to read. Directories are not supported; use `ls` or `tree` first, then read specific files.",
        },
        "start_line": { "type": "number" },
        "max_lines": { "type": "number" },
        "max_output_chars": { "type": "number" },
      },
    }),
    execute=Async(arguments => execute_with_workspace(workspace_root, arguments)),
  )
}

///|
async fn execute(arguments : Json) -> @agent_tool.ToolAction {
  execute_with_workspace(".", arguments)
}

///|
async fn execute_with_workspace(
  workspace_root : String,
  arguments : Json,
) -> @agent_tool.ToolAction {
  let input = @decode.decode(arguments) catch {
    error => {
      let message = @tool_error.failure_message("\{error}")
      return @agent_tool.ToolAction::respond(
        "error: read requires \{message}",
        is_error=true,
      )
    }
  }
  read_file(input, path=@workspace_path.resolve(workspace_root, input.path))
}

///|
priv struct ReadSelection {
  content : String
  start_line : Int
  total_lines : Int
  shown_lines : Int
  line_limited : Bool
}

///|
priv struct RenderedSelection {
  content : String
  end_line : Int
  shown_lines : Int
  shown_chars : Int
  truncated : Bool
}

///|
async fn read_file(
  input : @decode.ReadInput,
  path~ : String,
) -> @agent_tool.ToolAction {
  match directory_read_error(path) {
    Some(message) =>
      return @agent_tool.ToolAction::respond(message, is_error=true)
    None => ()
  }
  let content = @fs.read_file(path).text() catch {
    error =>
      return @agent_tool.ToolAction::respond(
        "error reading \{path}: \{error}",
        is_error=true,
        brief="read \{@agent_tool.brief_basename(path)}",
      )
  }
  let selection = select_lines(content, input.start_line, input.max_lines)
  let include_header = input.start_line != 1 ||
    input.max_lines is Some(_) ||
    selection.content.char_length() > input.max_output_chars
  if include_header {
    let rendered = render_numbered_content(selection, input.max_output_chars)
    let output = "\{read_header(path, content, selection, rendered)}\{rendered.content}"
    @agent_tool.ToolAction::respond(
      output,
      is_error=rendered.truncated,
      brief="read \{@agent_tool.brief_basename(path)}",
    )
  } else {
    @agent_tool.ToolAction::respond(
      selection.content,
      brief="read \{@agent_tool.brief_basename(path)}",
    )
  }
}

///|
fn select_lines(
  content : String,
  start_line : Int,
  max_lines : Int?,
) -> ReadSelection {
  let lines = [ for line in content.split("\n") => line.to_owned() ]
  let total_lines = lines.length()
  // Clamp both bounds into [0, total_lines] so the slice below is always
  // ascending and in range — a start past the last line selects nothing.
  let start_index = (start_line - 1).clamp(min=0, max=total_lines)
  let end_exclusive = match max_lines {
    // Clamp the count BEFORE adding: a huge max_lines (e.g. Int max) must
    // not overflow past start_index (Codex review). Such a request now
    // returns the remaining lines, where the old post-add clamp overflowed
    // negative and accidentally selected nothing.
    Some(count) =>
      start_index + count.clamp(min=0, max=total_lines - start_index)
    None => total_lines
  }
  let selected = lines[start_index:end_exclusive].to_owned()
  let shown_lines = selected.length()
  let line_limited = match max_lines {
    Some(_) => end_exclusive < total_lines
    None => false
  }
  {
    content: selected.join("\n"),
    start_line,
    total_lines,
    shown_lines,
    line_limited,
  }
}

///|
async fn directory_read_error(path : String) -> String? {
  match (@fs.kind(path, follow_symlink=true) catch { _ => return None }) {
    Directory =>
      Some(
        "error reading \{path}: path is a directory; use the shell tool with `ls` or `tree` to inspect directories, then read specific files.",
      )
    _ => None
  }
}

///|
fn char_prefix(content : String, max_chars : Int) -> String {
  if max_chars <= 0 {
    ""
  } else if content.char_length() <= max_chars {
    content
  } else {
    StringView::from_iter(content.iter().take(max_chars)).to_owned()
  }
}

///|
fn render_numbered_content(
  selection : ReadSelection,
  max_chars : Int,
) -> RenderedSelection {
  if selection.shown_lines == 0 {
    return {
      content: "",
      end_line: selection.start_line - 1,
      shown_lines: 0,
      shown_chars: 0,
      truncated: false,
    }
  }
  if max_chars <= 0 {
    return {
      content: "",
      end_line: selection.start_line - 1,
      shown_lines: 0,
      shown_chars: 0,
      truncated: true,
    }
  }
  let lines = [ for line in selection.content.split("\n") => line.to_owned() ]
  let last_line = selection.start_line + lines.length() - 1
  let width = "\{last_line}".length()
  let numbered : Array[String] = []
  let mut remaining = max_chars
  let mut truncated = false
  for index in 0..<lines.length() {
    let separator_chars = if numbered.length() == 0 { 0 } else { 1 }
    let line_number = "\{selection.start_line + index}".pad_start(width, ' ')
    let prefix = "\{line_number}| "
    let prefix_budget = separator_chars + prefix.char_length()
    if remaining < prefix_budget {
      truncated = true
      break
    }
    let available = remaining - prefix_budget
    let line = lines[index]
    let line_chars = line.char_length()
    if line_chars <= available {
      numbered.push("\{prefix}\{line}")
      remaining = remaining - prefix_budget - line_chars
    } else {
      numbered.push("\{prefix}\{char_prefix(line, available)}")
      remaining = 0
      truncated = true
      break
    }
  }
  if numbered.length() < lines.length() {
    truncated = true
  }
  let content = numbered.join("\n")
  let shown_lines = numbered.length()
  let end_line = if shown_lines == 0 {
    selection.start_line - 1
  } else {
    selection.start_line + shown_lines - 1
  }
  {
    content,
    end_line,
    shown_lines,
    shown_chars: content.char_length(),
    truncated,
  }
}

///|
fn read_header(
  path : String,
  original : String,
  selection : ReadSelection,
  rendered : RenderedSelection,
) -> String {
  [
    "path=\{path}",
    "start_line=\{selection.start_line}",
    "end_line=\{rendered.end_line}",
    "total_lines=\{selection.total_lines}",
    "shown_lines=\{rendered.shown_lines}",
    "file_chars=\{original.char_length()}",
    "selected_chars=\{selection.content.char_length()}",
    "shown_chars=\{rendered.shown_chars}",
    "line_limited=\{selection.line_limited}",
    "truncated=\{rendered.truncated}",
    "line_format=right-aligned-number| text",
    "---",
    "",
  ].join("\n")
}

///|
async test "read returns file contents" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/test.txt"
    @fs.write_file(path, "hello read", create_mode=CreateOrTruncate)
    let result = execute({ "path": path })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_eq(output.content, "hello read")
    assert_false(output.is_error)
  })
}

///|
async test "read resolves relative paths under the workspace root" {
  @vfs.with_tmpdir(prefix="openseek-read-workspace-", dir => {
    @fs.write_file(
      "\{dir}/note.txt",
      "workspace read",
      create_mode=CreateOrTruncate,
    )
    let tool = definition(workspace_root=dir)
    let result = match tool.execute {
      Async(execute) => execute({ "path": "note.txt" })
      Sync(_) => fail("read tool should be async")
    }
    guard result is Respond(output) else { fail("expected Respond") }
    assert_eq(output.content, "workspace read")
    assert_false(output.is_error)
  })
}

///|
async test "read returns empty string for an empty file" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/empty.txt"
    @fs.write_file(path, "", create_mode=CreateOrTruncate)
    let result = execute({ "path": path })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_eq(output.content, "")
    assert_false(output.is_error)
  })
}

///|
async test "read preserves multiline content" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/multiline.txt"
    let content = "line one\nline two\nline three\n"
    @fs.write_file(path, content, create_mode=CreateOrTruncate)
    let result = execute({ "path": path })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_eq(output.content, content)
    assert_false(output.is_error)
  })
}

///|
async test "read returns a requested line range with metadata" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/range.txt"
    let content = "line one\nline two\nline three\nline four"
    @fs.write_file(path, content, create_mode=CreateOrTruncate)
    let result = execute({ "path": path, "start_line": 2, "max_lines": 2 })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    // The path is a temp dir, so assert the whole block dynamically rather
    // than snapshotting it with `inspect`.
    assert_eq(
      output.content,
      [
        "path=\{path}",
        "start_line=2",
        "end_line=3",
        "total_lines=4",
        "shown_lines=2",
        "file_chars=38",
        "selected_chars=19",
        "shown_chars=25",
        "line_limited=true",
        "truncated=false",
        "line_format=right-aligned-number| text",
        "---",
        "2| line two",
        "3| line three",
      ].join("\n"),
    )
  })
}

///|
async test "read caps oversized output and marks it as an error" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/capped.txt"
    @fs.write_file(path, "abcdef", create_mode=CreateOrTruncate)
    let result = execute({ "path": path, "max_output_chars": 3 })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_eq(
      output.content,
      [
        "path=\{path}",
        "start_line=1",
        "end_line=1",
        "total_lines=1",
        "shown_lines=1",
        "file_chars=6",
        "selected_chars=6",
        "shown_chars=3",
        "line_limited=false",
        "truncated=true",
        "line_format=right-aligned-number| text",
        "---",
        "1| ",
      ].join("\n"),
    )
  })
}

///|
async test "read caps after adding line number gutters" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/many-lines.txt"
    let content = [ for _ in 0..<80 => "x" ].join("\n")
    @fs.write_file(path, content, create_mode=CreateOrTruncate)
    let result = execute({ "path": path, "max_output_chars": 20 })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("shown_chars=17"))
    assert_true(output.content.contains("truncated=true"))
    assert_true(output.content.contains(" 1| x\n 2| x\n 3| x"))
    assert_false(output.content.contains(" 4| x"))
  })
}

///|
async test "read caps unicode content on character boundaries" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/unicode.txt"
    @fs.write_file(path, "😀Z", create_mode=CreateOrTruncate)
    let result = execute({ "path": path, "max_lines": 1, "max_output_chars": 4 })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("shown_chars=4"))
    assert_true(output.content.contains("1| 😀"))
    assert_false(output.content.contains("Z"))
  })
}

///|
async test "line number gutters align to the widest displayed number" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/aligned.txt"
    let content = [ for index in 1..<=111 => "line \{index}" ].join("\n")
    @fs.write_file(path, content, create_mode=CreateOrTruncate)
    let result = execute({ "path": path, "start_line": 9, "max_lines": 103 })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_true(output.content.contains("  9| line 9"))
    assert_true(output.content.contains(" 99| line 99"))
    assert_true(output.content.contains("100| line 100"))
    assert_true(output.content.contains("111| line 111"))
  })
}

///|
test "read description encourages batched reads and directory inspection" {
  let tool = definition()
  assert_true(tool.description.contains("batch separate read tool calls"))
  assert_true(tool.description.contains("Do not use read for directories"))
  let JsonSchema(schema) = tool.schema
  let schema_text = schema.stringify()
  assert_true(schema_text.contains("\"path\""))
  assert_false(schema_text.contains("\"paths\""))
  assert_true(schema_text.contains("\"required\""))
  assert_true(schema_text.contains("Directories are not supported"))
}

///|
test "read parses and caps optional limits" {
  let input = @decode.decode({
    "path": "file.mbt",
    "start_line": 3,
    "max_lines": 4,
    "max_output_chars": 999999,
  })
  assert_eq(input.path, "file.mbt")
  assert_eq(input.start_line, 3)
  guard input.max_lines is Some(max_lines) else { fail("missing max_lines") }
  assert_eq(max_lines, 4)
  assert_eq(input.max_output_chars, @decode.hard_max_output_chars)
}

///|
async test "read rejects paths array and explains batching" {
  let result = execute({ "paths": ["a.mbt", "b.mbt"] })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("arguments.paths is not supported"))
  assert_true(output.content.contains("batch separate read calls"))
}

///|
async test "read surfaces filesystem errors" {
  @vfs.with_tmpdir(dir => {
    let result = execute({ "path": "\{dir}/does-not-exist" })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.content.contains("error reading"))
    assert_true(output.is_error)
  })
}

///|
async test "read reports directories with an actionable hint" {
  @vfs.with_tmpdir(dir => {
    let result = execute({ "path": dir })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("path is a directory"))
    assert_true(output.content.contains("`ls` or `tree`"))
  })
}

///|
async test "read rejects missing path" {
  let result = execute({})
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.content.contains("error: read requires"))
  assert_true(output.content.contains("arguments.path"))
  assert_true(output.is_error)
}

///|
async test "read rejects invalid limits" {
  @vfs.with_tmpdir(dir => {
    let result = execute({ "path": "\{dir}/test.txt", "max_lines": 0 })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.content.contains("error: read requires"))
    assert_true(
      output.content.contains("arguments.max_lines to be a positive number"),
    )
    assert_true(output.is_error)
  })
}

///|
async test "read rejects non-object arguments" {
  let result = execute(Json::null())
  guard result is Respond(output) else { fail("expected Respond") }
  assert_eq(output.content, "error: read requires object arguments")
  assert_true(output.is_error)
}

///|
async test "a huge max_lines returns the remaining lines without overflow" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/huge-max.txt"
    @fs.write_file(path, "a\nb\nc", create_mode=CreateOrTruncate)
    let result = execute({
      "path": path,
      "start_line": 2,
      "max_lines": 2147483647,
    })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_true(output.content.contains("2| b\n3| c"))
    assert_true(output.content.contains("shown_lines=2"))
  })
}
