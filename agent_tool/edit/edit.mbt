///|
/// Tool definition for `edit`: replaces exact text in `arguments.path`.
///
/// ## Arguments
/// - `path` (string, required): filesystem path to edit.
/// - `old_string` (string, required): exact text to replace. It must be
///   non-empty.
/// - `new_string` (string, required): replacement text. It must differ from
///   `old_string`.
/// - `start_line` (integer, required): 1-based inclusive first line to search.
/// - `end_line` (integer, optional): 1-based inclusive last line to search.
/// - `replace_all=true` is rejected. Use `multi_edit` for multiple explicit
///   line-anchored replacements.
/// - `revert_on_parse_errors` (boolean, optional, default true): before an
///   edit to a `.mbt` file is written, the edited result is parsed standalone
///   (`moonc -stop-after-parsing`); an edit that would introduce new
///   lex/parse errors is rejected and the file is left untouched. Pre-existing
///   parse errors never trigger the gate, and `.mbt.md` is not gated (moonc
///   cannot parse markdown; see parse_gate.mbt).
///
/// ## Result
/// - `Respond(ToolOutput("ok: replaced <n> occurrence(s) at line <line> in <path>"))`
///   on success.
/// - `Respond(ToolOutput("rejected: the edit would introduce ...", is_error=true))`
///   when the parse gate refused an edit whose result does not parse.
/// - `Respond(ToolOutput("error editing <path>: ...", is_error=true))` for
///   filesystem failures, empty/no-op edits, or missing matches.
/// - `Respond(ToolOutput("error: edit requires ...", is_error=true))` for
///   invalid arguments.
pub fn definition(
  workspace_root? : String = ".",
) -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="edit",
    description="Replace the first exact text span at or after arguments.start_line in arguments.path with arguments.new_string. Optional end_line restricts the search to a 1-based inclusive line range. Because start_line anchors the location, old_string can be a small exact span instead of a large context block. To INSERT new code instead of replacing, set old_string to the empty string: new_string is inserted at the start of start_line (use start_line = last line + 1 to append at end of file). An edit that would introduce lex/parse errors into a .mbt file is rejected BEFORE writing and the parse errors are returned — see revert_on_parse_errors. For multiple compiler-feedback fixes in one file, use multi_edit with explicit line-anchored edits.",
    schema=JsonSchema({
      "type": "object",
      "properties": {
        "path": { "type": "string" },
        "old_string": { "type": "string" },
        "new_string": { "type": "string" },
        "start_line": { "type": "integer" },
        "end_line": { "type": "integer" },
        "revert_on_parse_errors": {
          "type": "boolean",
          "description": "Syntax gate, on by default. Before the edit is written to a .mbt file, the edited result is parsed standalone (moonc -stop-after-parsing); an edit that would INTRODUCE new lex/parse errors — measured against the pre-edit content parsed the same way, so pre-existing parse errors are ignored — is REJECTED, the file is left untouched, and the call returns the errors with excerpts of the would-be content. Type errors never trigger the gate (they may be a legitimate transient state), and .mbt.md files are not gated. Set false only to intentionally produce content that does not parse (e.g. a fixture).",
          "examples": [false],
        },
      },
      "required": ["path", "old_string", "new_string", "start_line"],
    }),
    execute=Async(arguments => execute_with_workspace(workspace_root, arguments)),
  )
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
        "error: edit requires \{message}",
        is_error=true,
      )
    }
  }
  let path = @workspace_path.resolve(workspace_root, input.path)
  edit_file(input, path~)
}

///|
async fn edit_file(
  input : @decode.EditInput,
  path~ : String,
) -> @agent_tool.ToolAction {
  // Every failure names the file it tried to edit so the viz can show
  // `→ edit · edit <file> 🚩` on the folded call line.
  let fail_brief = "edit \{@agent_tool.brief_basename(path)}"
  if input.replace_all {
    return @agent_tool.ToolAction::respond(
      "error editing \{path}: replace_all=true is no longer supported; use multi_edit with explicit line-anchored edits",
      is_error=true,
      brief=fail_brief,
    )
  }
  if input.old_string == "" && input.new_string == "" {
    return @agent_tool.ToolAction::respond(
      "error editing \{path}: old_string and new_string are both empty",
      is_error=true,
      brief=fail_brief,
    )
  }
  if input.old_string == input.new_string {
    return @agent_tool.ToolAction::respond(
      "error editing \{path}: old_string and new_string are identical",
      is_error=true,
      brief=fail_brief,
    )
  }
  let content = @fs.read_file(path).text() catch {
    error if @async.is_being_cancelled() => raise error
    error =>
      return @agent_tool.ToolAction::respond(
        "error editing \{path}: error reading file: \{error}",
        is_error=true,
        brief=fail_brief,
      )
  }
  if input.old_string == "" {
    // Insertion: insert new_string at the start of start_line (a zero-width
    // edit); use start_line = last line + 1 to append at end of file.
    let at = line_start_offset(content, input.start_line).clamp(
      min=0,
      max=content.length(),
    )
    let new_content = "\{content.unsafe_substring(start=0, end=at)}\{input.new_string}\{content.unsafe_substring(start=at, end=content.length())}"
    match @manifest_error.write_error(path, new_content) {
      Some(message) =>
        return @agent_tool.ToolAction::respond(
          "error editing \{path}: \{message}",
          is_error=true,
          brief=fail_brief,
        )
      None => ()
    }
    match
      parse_gate_rejection(
        path,
        original_content=content,
        new_content~,
        revert_on_parse_errors=input.revert_on_parse_errors,
      ) {
      Some(rejection) => return rejection
      None => ()
    }
    return try {
      @fs.write_file(path, new_content, create_mode=CreateOrTruncate)
      let summary = "ok: inserted at line \{input.start_line} in \{path}"
      let response = @auto_check.append_summary(path, summary)
      @agent_tool.ToolAction::respond(
        response,
        brief="edited \{@agent_tool.brief_basename(path)}:\{input.start_line} (insert)",
      )
    } catch {
      error if @async.is_being_cancelled() => raise error
      error =>
        @agent_tool.ToolAction::respond(
          "error editing \{path}: error writing file: \{error}",
          is_error=true,
          brief=fail_brief,
        )
    }
  }
  let region = select_edit_region(content, input)
  let parts = region.body
    .split(input.old_string)
    .map(part => part.to_owned())
    .collect()
  if parts.length() <= 1 {
    return @agent_tool.ToolAction::respond(
      "error editing \{path}: old_string not found\{range_detail(input)}",
      is_error=true,
      brief=fail_brief,
    )
  }
  let replacement_count = 1
  let match_start = parts[0].length()
  let match_end = match_start + input.old_string.length()
  let match_line = line_number_at_offset(
    content,
    region.prefix.length() + match_start,
  )
  let new_body = "\{parts[0]}\{input.new_string}\{region.body.unsafe_substring(start=match_end, end=region.body.length())}"
  let new_content = "\{region.prefix}\{new_body}\{region.suffix}"
  match @manifest_error.write_error(path, new_content) {
    Some(message) =>
      return @agent_tool.ToolAction::respond(
        "error editing \{path}: \{message}",
        is_error=true,
        brief=fail_brief,
      )
    None => ()
  }
  match
    parse_gate_rejection(
      path,
      original_content=content,
      new_content~,
      revert_on_parse_errors=input.revert_on_parse_errors,
    ) {
    Some(rejection) => return rejection
    None => ()
  }
  try {
    @fs.write_file(path, new_content, create_mode=CreateOrTruncate)
    let summary = "ok: replaced \{replacement_count} occurrence(s) at line \{match_line} in \{path}"
    let response = @auto_check.append_summary(path, summary)
    @agent_tool.ToolAction::respond(
      response,
      brief="edited \{@agent_tool.brief_basename(path)}:\{match_line} (\{replacement_count}×)",
    )
  } catch {
    error if @async.is_being_cancelled() => raise error
    error =>
      @agent_tool.ToolAction::respond(
        "error editing \{path}: error writing file: \{error}",
        is_error=true,
        brief=fail_brief,
      )
  }
}

///|
/// From this many newly introduced parse errors up, the reject report stops
/// suggesting a corrected re-issue and pushes splitting the change into
/// smaller edits instead: parse errors cascade, so several of them usually
/// mean a large replacement (or a misplaced insertion) broke the file's
/// structure wholesale.
const SmallerEditsHintThreshold : Int = 3

///|
/// Pre-write syntax gate for `.mbt` edits: parse the candidate result in a
/// scratch file (moonc -stop-after-parsing, no project context) and reject
/// the edit — leaving the file untouched — when it would introduce new parse
/// errors. "Introduced" compares parse-error counts against the ORIGINAL
/// content parsed the same way, so a file that already fails to parse can
/// still be edited (including partial fixes). Counts, not diagnostic
/// identities, on purpose: an edit shifts the line numbers of every
/// pre-existing error below it, so identity matching keyed on locations would
/// false-fire constantly; the blind spot (an edit that fixes one parse error
/// while introducing another, keeping the count flat) is accepted. `.mbt.md`
/// is not gated (see the TODO in parse_gate.mbt). Fail-open: when the gate
/// cannot run, the edit proceeds as before the gate existed.
async fn parse_gate_rejection(
  path : String,
  original_content~ : String,
  new_content~ : String,
  revert_on_parse_errors~ : Bool,
) -> @agent_tool.ToolAction? {
  if !revert_on_parse_errors {
    return None
  }
  // Resolve symlinks before deciding whether the gate applies: an edit through
  // a link named `alias.txt` pointing at `lib/a.mbt` must be gated like the
  // `.mbt` file it really writes (the same class `write`'s overwrite guard
  // handles with realpath).
  let target = @fs.realpath(path) catch {
    error if @async.is_being_cancelled() => raise error
    _ => path
  }
  if !@auto_check.is_gateable_path(path) &&
    !@auto_check.is_gateable_path(target) {
    return None
  }
  let gate = @auto_check.content_parse_errors(new_content) catch {
    error if @async.is_being_cancelled() => raise error
    _ => None
  }
  guard gate is Some(gate) && gate.errors.length() > 0 else { return None }
  // The edited result has parse errors; reject only when the edit makes the
  // file WORSE than its original content parsed the same way.
  let before = @auto_check.content_parse_errors(original_content) catch {
    error if @async.is_being_cancelled() => raise error
    _ => None
  }
  // The comparison is only sound against a COMPLETE baseline: a missing one
  // (transient tmpdir/moonc failure) gives no honest "introduced" answer, and
  // a truncated one is a lower bound whose subtraction could over-count the
  // introduced errors and false-reject. Fail open in both cases — the gate
  // must never reject on a comparison it could not actually make. A truncated
  // NEW capture is fine: its count is a lower bound, so exceeding the complete
  // baseline still proves the edit made things worse.
  guard before is Some(before) && !before.truncated else { return None }
  let before_count = before.errors.length()
  let introduced = gate.errors.length() - before_count
  if introduced <= 0 {
    return None
  }
  let bound = if gate.truncated { "≥" } else { "" }
  Some(
    @agent_tool.ToolAction::respond(
      edit_reject_report(path, new_content, gate, introduced~, before_count~),
      is_error=true,
      brief="edit rejected (\{bound}\{introduced} parse error(s))",
    ),
  )
}

///|
/// The rejected-edit report: the file was not modified, the first parse
/// errors with excerpts synthesized from the would-be content, and how to
/// retry — a corrected re-issue for a small slip, smaller pieces when the
/// errors suggest the replacement broke the file's structure.
fn edit_reject_report(
  path : String,
  new_content : String,
  gate : @auto_check.ParseGate,
  introduced~ : Int,
  before_count~ : Int,
) -> String {
  // A truncated capture makes the introduced count a lower bound; never state
  // an exact number the gate does not know.
  let introduced_label = if gate.truncated {
    "at least \{introduced}"
  } else {
    "\{introduced}"
  }
  let head = "rejected: the edit would introduce \{introduced_label} new parse error(s) in \{path}, so the file was NOT modified."
  let pre_existing = if before_count > 0 {
    " (the file already has \{before_count} parse error(s); only counts are compared, so the excerpts below may include pre-existing errors, not only the newly introduced ones)"
  } else {
    ""
  }
  let formatted = @auto_check.format_parse_gate_errors(
    path,
    new_content,
    gate.errors,
  )
  let listed = if formatted.is_empty() {
    ""
  } else {
    "\nfirst \{formatted.length()} parse error(s), excerpted from the WOULD-BE content (not what is on disk):\n\{formatted.join("\n")}"
  }
  let retry = if introduced >= SmallerEditsHintThreshold {
    "\n\{introduced_label} new parse errors usually means the replacement would break the file's structure (an unbalanced brace, a misplaced insertion, or non-MoonBit text). Do not re-issue the same edit: split it into smaller pieces — multi_edit applies several small line-anchored edits in one validated call — and check after each step."
  } else {
    "\nre-issue the edit with a corrected new_string (check delimiters against the excerpt above)."
  }
  let opt_out = "\n(To intentionally produce content that does not parse, e.g. a fixture, pass revert_on_parse_errors=false.)"
  "\{head}\{pre_existing}\{listed}\{retry}\{opt_out}"
}

///|
priv struct EditRegion {
  prefix : String
  body : String
  suffix : String
}

///|
fn select_edit_region(
  content : String,
  input : @decode.EditInput,
) -> EditRegion {
  let start_line = input.start_line
  let start = line_start_offset(content, start_line)
  let end = match input.end_line {
    Some(line) => line_end_offset(content, line)
    None => content.length()
  }
  // `decode` guarantees end_line >= start_line when both are present. These
  // clamps make ranges beyond EOF select an empty suffix without panicking.
  let start = start.clamp(min=0, max=content.length())
  let end = end.clamp(min=start, max=content.length())
  {
    prefix: content.unsafe_substring(start=0, end=start),
    body: content.unsafe_substring(start~, end~),
    suffix: content.unsafe_substring(start=end, end=content.length()),
  }
}

///|
fn line_start_offset(content : String, line : Int) -> Int {
  if line <= 1 {
    0
  } else {
    let len = content.length()
    let mut current_line = 1
    for cursor = 0; cursor < len; cursor = cursor + 1 {
      if content[cursor] == '\n' {
        current_line = current_line + 1
        if current_line == line {
          break cursor + 1
        }
      }
    } nobreak {
      len
    }
  }
}

///|
fn line_end_offset(content : String, line : Int) -> Int {
  let len = content.length()
  let mut current_line = 1
  for cursor = 0; cursor < len; cursor = cursor + 1 {
    if content[cursor] == '\n' {
      if current_line == line {
        break cursor + 1
      }
      current_line = current_line + 1
    }
  } nobreak {
    len
  }
}

///|
fn line_number_at_offset(content : String, offset : Int) -> Int {
  let bounded_offset = offset.clamp(min=0, max=content.length())
  let mut line = 1
  for cursor = 0; cursor < bounded_offset; cursor = cursor + 1 {
    if content[cursor] == '\n' {
      line = line + 1
    }
  }
  line
}

///|
fn range_detail(input : @decode.EditInput) -> String {
  match input.end_line {
    Some(end) => " in line range \{input.start_line}-\{end}"
    None => " from line \{input.start_line}"
  }
}

///|
test "edit_reject_report excerpts the would-be content and asks for a re-issue" {
  let would_be =
    #|///|
    #|pub fn f() -> Int {
    #|  match 42 {
    #|}
  inspect(
    edit_reject_report(
      "lib/a.mbt",
      would_be,
      {
        errors: [
          {
            loc: "4:1-4:2",
            message: "Parse error, unexpected token `}`.",
            context: "",
          },
        ],
        truncated: false,
      },
      introduced=1,
      before_count=0,
    ),
    content=(
      #|rejected: the edit would introduce 1 new parse error(s) in lib/a.mbt, so the file was NOT modified.
      #|first 1 parse error(s), excerpted from the WOULD-BE content (not what is on disk):
      #|lib/a.mbt:4:1-4:2: Parse error, unexpected token `}`.
      #|  3 |  match 42 {
      #|  4 |}
      #|re-issue the edit with a corrected new_string (check delimiters against the excerpt above).
      #|(To intentionally produce content that does not parse, e.g. a fixture, pass revert_on_parse_errors=false.)
    ),
  )
}

///|
test "edit_reject_report pushes smaller edits and names pre-existing errors" {
  let errors = [
    for index in 0..<5 => {
      (
        { loc: "\{index + 1}:1", message: "e\{index}", context: "" } :
        @auto_check.ParseGateError)
    }
  ]
  let report = edit_reject_report(
    "lib/a.mbt",
    "a\nb\nc\nd\ne",
    { errors, truncated: false },
    introduced=4,
    before_count=1,
  )
  assert_true(report.contains("4 new parse errors usually means"))
  assert_true(report.contains("split it into smaller pieces"))
  assert_true(report.contains("already has 1 parse error(s)"))
  assert_false(report.contains("re-issue the edit with a corrected new_string"))
  // A truncated capture reports a lower bound, never an exact count.
  let clipped = edit_reject_report(
    "lib/a.mbt",
    "a",
    { errors: [{ loc: "1:1", message: "e", context: "" }], truncated: true },
    introduced=1,
    before_count=0,
  )
  assert_true(clipped.contains("would introduce at least 1 new parse error(s)"))
}
