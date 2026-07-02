///|
/// Tool definition for `write`: creates a new file at `arguments.path` with
/// `arguments.content`, or overwrites an existing non-source file. Overwriting
/// an existing `.mbt`/`.mbt.md` source file is rejected (use `edit`/`multi_edit`,
/// which also insert). Missing parent directories are created (so `dir/moon.pkg`
/// works without a separate mkdir).
///
/// ## Arguments
/// - `path` (string, required): filesystem path to write.
/// - `content` (string, required): text to write. The file is truncated
///   before writing.
/// - `revert_on_parse_errors` (boolean, optional, default true): after a new
///   `.mbt`/`.mbt.md` file is written, `moon check` runs; if the new file
///   itself has lex/parse errors (codes 3000-3999) it is deleted and the
///   errors are returned. Set false only to intentionally create a file that
///   does not parse (e.g. a test fixture).
///
/// ## Result
/// - `Respond(ToolOutput("ok: wrote <n> chars to <path>"))` when a new file is
///   created; the message gains ` (overwrote existing file)` when the path
///   already existed, so the model can tell it clobbered prior content.
/// - `Respond(ToolOutput("reverted: wrote <path> ...", is_error=true))` when
///   the parse-error guard deleted a new source file that did not parse.
/// - `Respond(ToolOutput("error writing <path>: <error>", is_error=true))`
///   if the write fails.
/// - `Respond(ToolOutput("error: write requires ...", is_error=true))` for
///   invalid arguments.
pub fn definition(
  workspace_root? : String = ".",
) -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="write",
    description="Create a new file at arguments.path with arguments.content (missing parent directories are created), or overwrite an existing non-source file. Overwriting an existing .mbt/.mbt.md source file is rejected: use edit or multi_edit to change existing source (an empty old_string inserts new code). A new .mbt/.mbt.md file that fails to lex/parse is auto-deleted (reverted) and the parse errors are returned — see revert_on_parse_errors. Do not use write to route shell-generated rewrites back into source files. Do not create Markdown or README files unless the user explicitly asks for them.",
    schema=JsonSchema({
      "type": "object",
      "properties": {
        "path": { "type": "string" },
        "content": { "type": "string" },
        "revert_on_parse_errors": {
          "type": "boolean",
          "description": "Auto-revert safety net, on by default. After a new .mbt/.mbt.md file is written, `moon check` runs; if the new file itself has lex/parse errors (error codes 3000-3999) it is DELETED and the call returns the parse errors with source context — a file that does not parse is never a valid intermediate state, and write cannot overwrite existing source, so deleting re-opens the natural retry (re-issue write with corrected content). Type errors (4xxx) never trigger the revert; they may be a legitimate transient state during multi-file work. Set false only to intentionally create a file that does not parse (e.g. a test fixture).",
          "examples": [false],
        },
      },
      "required": ["path", "content"],
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
        "error: write requires \{message}",
        is_error=true,
      )
    }
  }
  let path = @workspace_path.resolve(workspace_root, input.path)
  write_file(input, path~)
}

///|
async fn write_file(
  input : @decode.WriteInput,
  path~ : String,
) -> @agent_tool.ToolAction {
  try {
    match manifest_write_error(path, input.content) {
      Some(message) =>
        return @agent_tool.ToolAction::respond(
          "error writing \{path}: \{message}",
          is_error=true,
          brief="write \{@agent_tool.brief_basename(path)}",
        )
      None => ()
    }
    // Guard the last unguarded source-write path: `write` is not sandboxed (it
    // is an in-process file write, unlike `shell`), so overwriting an existing
    // `.mbt`/`.mbt.md` file here would bypass the line-anchored edit discipline
    // and risk silently dropping content. Existing source must change through
    // `edit`/`multi_edit` (which also insert). Creating a NEW source file, or
    // writing non-source files, is still allowed.
    // Resolve symlinks before treating a path as a safe non-source overwrite: a
    // link named `x.txt` pointing at `lib.mbt` would otherwise slip past the
    // suffix check and truncate the source through CreateOrTruncate below.
    if @fs.exists(path) {
      let target = @fs.realpath(path) catch {
        error if @async.is_being_cancelled() => raise error
        _ => path
      }
      if is_mbt_source(path) || is_mbt_source(target) {
        return @agent_tool.ToolAction::respond(
          "error writing \{path}: existing source file — use edit or multi_edit to change it (an empty old_string inserts new code); write is for creating new files",
          is_error=true,
          brief="write \{@agent_tool.brief_basename(path)}",
        )
      }
    }
    create_parent_dirs(path)
    // Probe before writing so the result can tell the model whether it created a
    // new file or clobbered an existing one — a wholesale `write` over content it
    // never read is a common way to lose work. A non-ENOENT `exists` error (e.g.
    // ENOTDIR) falls through to the write below and the `catch` reports it.
    let existed = @fs.exists(path)
    @fs.write_file(path, input.content, create_mode=CreateOrTruncate)
    let chars = input.content.length()
    let summary = if existed {
      "ok: wrote \{chars} chars to \{path} (overwrote existing file)"
    } else {
      "ok: wrote \{chars} chars to \{path}"
    }
    let ok_brief = @agent_tool.brief_line(
      if existed {
        "overwrote \{input.path}"
      } else {
        "wrote \{chars} chars to \{input.path}"
      },
    )
    // A source path reaching this point is always a NEW file (the overwrite
    // guard above rejects existing source), so any parse error inside it was
    // introduced by this write — no pre-write baseline is needed.
    if input.revert_on_parse_errors && is_mbt_source(path) {
      return parse_guarded_response(path, summary, ok_brief~)
    }
    let content = @auto_check.append_summary(path, summary)
    @agent_tool.ToolAction::respond(content, brief=ok_brief)
  } catch {
    error if @async.is_being_cancelled() => raise error
    error =>
      @agent_tool.ToolAction::respond(
        "error writing \{path}: \{error}",
        is_error=true,
        brief="write \{@agent_tool.brief_basename(path)}",
      )
  }
}

///|
/// From this many parse errors up, the revert report stops suggesting a plain
/// re-issue and pushes writing the file in smaller parts instead: parse errors
/// cascade, so several of them usually mean the content is malformed wholesale
/// (truncated generation, stray markdown fences, non-MoonBit text), and a
/// smaller skeleton that parses is the reliable way back.
const SmallerPartsHintThreshold : Int = 3

///|
/// Post-write guard for a NEW MoonBit source file: run `moon check` and, when
/// the file itself has lex/parse errors, delete it and return the errors with
/// their source context. A non-parsing file is never a valid intermediate
/// state, and `write` refuses to overwrite existing source — keeping the
/// broken file would force the model to repair garbage through line-anchored
/// edits, while deleting re-opens the natural retry: re-issue `write` with
/// corrected content. Fail-open: when the check cannot run (not a MoonBit
/// project, timeout), the file is kept exactly as written.
async fn parse_guarded_response(
  path : String,
  summary : String,
  ok_brief~ : String,
) -> @agent_tool.ToolAction {
  let check = @auto_check.check_source(path) catch {
    error if @async.is_being_cancelled() => raise error
    _ => None
  }
  guard check is Some(check) else {
    return @agent_tool.ToolAction::respond(summary, brief=ok_brief)
  }
  if check.parse_error_count == 0 {
    return @agent_tool.ToolAction::respond(
      "\{summary}\n\{@auto_check.source_check_feedback(check)}",
      brief=ok_brief,
    )
  }
  let removed = try {
    @fs.remove(path)
    true
  } catch {
    error if @async.is_being_cancelled() => raise error
    _ => false
  }
  @agent_tool.ToolAction::respond(
    write_revert_report(path, check, removed~),
    is_error=true,
    brief="write reverted (\{check.parse_error_count} parse error(s))",
  )
}

///|
/// The reverted-write report: what was deleted, the first parse errors with
/// their source excerpts (the model's only remaining view of the content), and
/// how to retry — a plain re-issue for a small slip, smaller incremental
/// writes when the errors suggest wholesale malformed content.
fn write_revert_report(
  path : String,
  check : @auto_check.SourceCheck,
  removed~ : Bool,
) -> String {
  let count = check.parse_error_count
  let head = "reverted: wrote \{path} but the new file has \{count} parse error(s), so it was deleted (nothing is on disk)."
  let shown = check.parse_errors.length()
  let errors = if shown == 0 {
    ""
  } else {
    "\nfirst \{shown} parse error(s), with the deleted content excerpted:\n\{check.parse_errors.join("\n")}"
  }
  let removed_note = if removed {
    ""
  } else {
    "\nWARNING: could not delete \{path} — the broken content is still on disk; inspect it manually."
  }
  let retry = if count >= SmallerPartsHintThreshold {
    "\n\{count} parse errors usually means the content is malformed wholesale (truncated or not valid MoonBit). Do not re-issue the same content: write a smaller file first — a minimal skeleton that parses — then grow it in small pieces with edit (an empty old_string inserts), checking after each step."
  } else {
    "\nre-issue write with the corrected full content."
  }
  let opt_out = "\n(To intentionally create a file that does not parse, e.g. a test fixture, pass revert_on_parse_errors=false.)"
  "\{head}\{errors}\{removed_note}\{retry}\{opt_out}"
}

///|
/// Whether `path` is a hand-written MoonBit source file (`.mbt` or `.mbt.md`).
/// `.mbti` interface files are excluded on purpose: generated ones are rejected
/// by the manifest guard, and hand-maintained ones are rare and editable.
fn is_mbt_source(path : String) -> Bool {
  path.has_suffix(".mbt") || path.has_suffix(".mbt.md")
}

///|
/// Create the parent directory of `path` (recursively) when it is missing, so a
/// write to `dir/moon.pkg` works without a separate `mkdir`. The path is already
/// resolved under the workspace root, so this stays inside the workspace. A
/// mkdir failure propagates to the caller's `error writing` path rather than
/// being swallowed — the write would fail anyway, so the real cause is useful.
async fn create_parent_dirs(path : String) -> Unit {
  let parent = parent_dir(path)
  if parent != "" && !@fs.exists(parent) {
    @fs.mkdir(parent, recursive=true)
  }
}

///|
/// The directory portion of `path` (before the last `/` or `\`), or `""` when
/// the path has no directory component or is at the filesystem root.
fn parent_dir(path : String) -> String {
  let cut = match (path.rev_find("/"), path.rev_find("\\")) {
    (Some(a), Some(b)) => if a > b { a } else { b }
    (Some(a), None) => a
    (None, Some(b)) => b
    (None, None) => -1
  }
  if cut <= 0 {
    ""
  } else {
    path[:cut].to_owned()
  }
}

///|
async fn manifest_write_error(path : String, content : String) -> String? {
  let trimmed = content.trim()
  if @manifest_path.is_generated_mbti_path(path) {
    return Some(
      "*.generated.mbti files are generated; run moon info instead of editing them",
    )
  }
  if @manifest_path.is_moon_mod_json_path(path) && !@fs.exists(path) {
    return Some(
      "moon.mod.json is legacy; create moon.mod for new MoonBit projects",
    )
  }
  if @manifest_path.is_moon_mod_path(path) {
    if trimmed == "" {
      return Some("moon.mod must not be empty")
    }
    if trimmed.has_prefix("{") || trimmed.contains("\"name\"") {
      return Some("moon.mod uses current text syntax, not JSON")
    }
    if !trimmed.contains("name =") {
      return Some("moon.mod should include a module `name = ...` entry")
    }
  }
  if @manifest_path.is_moon_pkg_path(path) {
    // This is normal when we create a moon.pkg dummy file
    // another mistake is AI is trying to write 
    // # as a comment
    // if trimmed.length() < 8 {    
    //   return Some("moon.pkg content is suspiciously small")
    // }
    if trimmed.has_prefix("#") {
      return Some("moon.pkg use // for comment syntax, not #")
    }
    if trimmed.has_prefix("{") {
      return Some("moon.pkg uses current text syntax, not JSON")
    }
  }
  None
}

///|
async test "write creates missing parent directories" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/pkg/sub/moon.pkg"
    let result = execute({ "path": path, "content": "import {}\n" })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_eq(output.content, "ok: wrote 10 chars to \{path}")
    assert_eq(@fs.read_file(path).text(), "import {}\n")
  })
}

///|
test "parent_dir returns the directory portion" {
  assert_eq(parent_dir("/a/b/c.txt"), "/a/b")
  assert_eq(parent_dir("a/b.txt"), "a")
  assert_eq(parent_dir("file.txt"), "")
  assert_eq(parent_dir("C:\\ws\\x.txt"), "C:\\ws")
}

///|
async test "write creates a file with the given content" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/test.txt"
    let result = execute({ "path": path, "content": "hello write" })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_eq(output.content, "ok: wrote 11 chars to \{path}")
    assert_false(output.is_error)
    let read_back = @fs.read_file(path).text()
    assert_eq(read_back, "hello write")
  })
}

///|
async test "write resolves relative paths under the workspace root" {
  @vfs.with_tmpdir(prefix="openseek-write-workspace-", dir => {
    let tool = definition(workspace_root=dir)
    let result = match tool.execute {
      Async(execute) => execute({ "path": "note.txt", "content": "workspace" })
      Sync(_) => fail("write tool should be async")
    }
    guard result is Respond(output) else { fail("expected Respond") }
    let path = "\{dir}/note.txt"
    assert_false(output.is_error)
    assert_eq(output.content, "ok: wrote 9 chars to \{path}")
    assert_eq(@fs.read_file(path).text(), "workspace")
  })
}

///|
async test "write manifest guards accept Windows path separators" {
  guard manifest_write_error("C:\\workspace\\pkg.generated.mbti", "package x")
    is Some(generated_mbti) else {
    fail("expected generated mbti guard")
  }
  assert_true(generated_mbti.contains("run moon info"))
  guard manifest_write_error("C:\\workspace\\moon.mod", "{\"name\":\"bad\"}")
    is Some(moon_mod) else {
    fail("expected moon.mod guard")
  }
  assert_eq(moon_mod, "moon.mod uses current text syntax, not JSON")
  // guard manifest_write_error("C:\\workspace\\moon.pkg", "x") is Some(moon_pkg) else {
  //   fail("expected moon.pkg guard")
  // }
  // assert_eq(moon_pkg, "moon.pkg content is suspiciously small")
  guard manifest_write_error("C:\\workspace\\moon.mod.json", "{}")
    is Some(moon_mod_json) else {
    fail("expected moon.mod.json guard")
  }
  assert_eq(
    moon_mod_json, "moon.mod.json is legacy; create moon.mod for new MoonBit projects",
  )
}

///|
async test "write truncates existing files" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/truncate.txt"
    @fs.write_file(path, "long original content", create_mode=CreateOrTruncate)
    let result = execute({ "path": path, "content": "short" })
    guard result is Respond(output) else { fail("expected Respond") }
    // The path already existed, so the result flags the overwrite.
    assert_eq(
      output.content,
      "ok: wrote 5 chars to \{path} (overwrote existing file)",
    )
    assert_false(output.is_error)
    let read_back = @fs.read_file(path).text()
    assert_eq(read_back, "short")
  })
}

///|
async test "write reports whether it created or overwrote a file" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/note.txt"
    // First write to a fresh path: a plain "created" result, no overwrite note.
    let created = execute({ "path": path, "content": "v1" })
    guard created is Respond(first) else { fail("expected Respond") }
    assert_eq(first.content, "ok: wrote 2 chars to \{path}")
    // Writing again clobbers the existing file, which the result now calls out.
    let overwritten = execute({ "path": path, "content": "v2!" })
    guard overwritten is Respond(second) else { fail("expected Respond") }
    assert_eq(
      second.content,
      "ok: wrote 3 chars to \{path} (overwrote existing file)",
    )
  })
}

///|
async test "write accepts empty content" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/empty.txt"
    @fs.write_file(path, "previous", create_mode=CreateOrTruncate)
    let result = execute({ "path": path, "content": "" })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_eq(
      output.content,
      "ok: wrote 0 chars to \{path} (overwrote existing file)",
    )
    assert_false(output.is_error)
    let read_back = @fs.read_file(path).text()
    assert_eq(read_back, "")
  })
}

///|
async test "write rejects new legacy moon.mod.json" {
  @vfs.with_tmpdir(prefix="openseek-write-manifest-", dir => {
    let path = "\{dir}/moon.mod.json"
    let result = execute({ "path": path, "content": "{\"name\":\"legacy\"}" })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("moon.mod.json is legacy"))
  })
}

///|
async test "write rejects json style moon.mod" {
  @vfs.with_tmpdir(prefix="openseek-write-manifest-", dir => {
    let path = "\{dir}/moon.mod"
    let result = execute({ "path": path, "content": "{\"name\":\"bad\"}" })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("moon.mod uses current text syntax"))
  })
}

///|
async test "write rejects generated mbti files" {
  @vfs.with_tmpdir(prefix="openseek-write-manifest-", dir => {
    let path = "\{dir}/pkg.generated.mbti"
    @fs.write_file(path, "old interface", create_mode=CreateOrTruncate)
    let result = execute({ "path": path, "content": "new interface" })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("run moon info"))
    assert_eq(@fs.read_file(path).text(), "old interface")
  })
}

///|
async test "write rejects overwriting an existing .mbt source file" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/lib.mbt"
    @fs.write_file(
      path,
      "pub fn f() -> Int { 1 }\n",
      create_mode=CreateOrTruncate,
    )
    let result = execute({
      "path": path,
      "content": "pub fn f() -> Int { 2 }\n",
    })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("use edit or multi_edit"))
    // unchanged on disk
    assert_eq(@fs.read_file(path).text(), "pub fn f() -> Int { 1 }\n")
  })
}

///|
async test "write still creates a NEW .mbt source file" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/new.mbt"
    let result = execute({
      "path": path,
      "content": "pub fn g() -> Int { 0 }\n",
    })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_eq(@fs.read_file(path).text(), "pub fn g() -> Int { 0 }\n")
  })
}

///|
async test "write rejects overwriting an existing .mbt.md doc file" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/doc.mbt.md"
    @fs.write_file(path, "# old\n", create_mode=CreateOrTruncate)
    let result = execute({ "path": path, "content": "# new\n" })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("use edit or multi_edit"))
  })
}

///|
async test "write rejects overwriting source through a symlink" {
  @vfs.with_tmpdir(dir => {
    let src = "\{dir}/lib.mbt"
    @fs.write_file(
      src,
      "pub fn f() -> Int { 1 }\n",
      create_mode=CreateOrTruncate,
    )
    // link.txt -> lib.mbt: the .txt name must not let the write slip past the
    // guard and truncate the real source.
    let link = "\{dir}/link.txt"
    @fs.symlink(target="lib.mbt", link)
    let result = execute({ "path": link, "content": "clobbered\n" })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("use edit or multi_edit"))
    assert_eq(@fs.read_file(src).text(), "pub fn f() -> Int { 1 }\n")
  })
}

///|
async test "write rejects suspiciously tiny moon.pkg" {
  @vfs.with_tmpdir(prefix="openseek-write-manifest-", dir => {
    let path = "\{dir}/moon.pkg"
    let result = execute({ "path": path, "content": "x" })
    guard result is Respond(output) else { fail("expected Respond") }
    debug_inspect(
      output.is_error,
      content=(
        #|false
      ),
    )
  })
}

///|
test "write_revert_report excerpts the deleted content and asks for a re-issue" {
  let check : @auto_check.SourceCheck = {
    error_count: 1,
    warning_count: 0,
    parse_error_count: 1,
    parse_errors: [
      "lib/a.mbt:7:1-7:2: Parse error, unexpected token `}`.\n  6 |  let y =\n  7 |}",
    ],
    first_errors: ["lib/a.mbt:7:1-7:2: Parse error, unexpected token `}`."],
    truncated: false,
    failure_output: None,
  }
  inspect(
    write_revert_report("lib/a.mbt", check, removed=true),
    content=(
      #|reverted: wrote lib/a.mbt but the new file has 1 parse error(s), so it was deleted (nothing is on disk).
      #|first 1 parse error(s), with the deleted content excerpted:
      #|lib/a.mbt:7:1-7:2: Parse error, unexpected token `}`.
      #|  6 |  let y =
      #|  7 |}
      #|re-issue write with the corrected full content.
      #|(To intentionally create a file that does not parse, e.g. a test fixture, pass revert_on_parse_errors=false.)
    ),
  )
}

///|
test "write_revert_report pushes smaller parts when parse errors cascade" {
  let check : @auto_check.SourceCheck = {
    error_count: 4,
    warning_count: 1,
    parse_error_count: 4,
    parse_errors: ["lib/a.mbt:1:1-1:2: Parse error."],
    first_errors: [],
    truncated: false,
    failure_output: None,
  }
  let report = write_revert_report("lib/a.mbt", check, removed=false)
  assert_true(report.contains("4 parse errors usually means"))
  assert_true(report.contains("write a smaller file first"))
  assert_true(report.contains("WARNING: could not delete lib/a.mbt"))
  assert_false(
    report.contains("re-issue write with the corrected full content"),
  )
}

///|
async test "write surfaces filesystem errors" {
  @vfs.with_tmpdir(dir => {
    // A parent component that is a regular file cannot be created or written
    // through, so the write fails (missing parent *directories* are created).
    @fs.write_file("\{dir}/afile", "x", create_mode=CreateOrTruncate)
    let result = execute({ "path": "\{dir}/afile/child.txt", "content": "x" })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.content.contains("error writing"))
    assert_true(output.is_error)
  })
}

///|
async test "write rejects missing content" {
  @vfs.with_tmpdir(dir => {
    let result = execute({ "path": "\{dir}/noop.txt" })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_eq(output.content, "error: write requires arguments.content")
    assert_true(output.is_error)
  })
}

///|
async test "write rejects missing path" {
  let result = execute({ "content": "stuff" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_eq(output.content, "error: write requires arguments.path")
  assert_true(output.is_error)
}

///|
async test "write rejects non-object arguments" {
  let result = execute(Json::null())
  guard result is Respond(output) else { fail("expected Respond") }
  assert_eq(output.content, "error: write requires object arguments")
  assert_true(output.is_error)
}
