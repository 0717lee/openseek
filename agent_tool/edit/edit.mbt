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
/// - `revert_on_parse_errors` (boolean, optional, default true): after an edit
///   to a `.mbt`/`.mbt.md` file, `moon check` runs; if the edit introduced
///   lex/parse errors (codes 3000-3999) into the file, it is restored to its
///   pre-edit content and the errors are returned. Pre-existing parse errors
///   never trigger the revert.
///
/// ## Result
/// - `Respond(ToolOutput("ok: replaced <n> occurrence(s) at line <line> in <path>"))`
///   on success.
/// - `Respond(ToolOutput("reverted: the edit introduced ...", is_error=true))`
///   when the parse-error guard rolled the file back.
/// - `Respond(ToolOutput("error editing <path>: ...", is_error=true))` for
///   filesystem failures, empty/no-op edits, or missing matches.
/// - `Respond(ToolOutput("error: edit requires ...", is_error=true))` for
///   invalid arguments.
pub fn definition(
  workspace_root? : String = ".",
) -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="edit",
    description="Replace the first exact text span at or after arguments.start_line in arguments.path with arguments.new_string. Optional end_line restricts the search to a 1-based inclusive line range. Because start_line anchors the location, old_string can be a small exact span instead of a large context block. To INSERT new code instead of replacing, set old_string to the empty string: new_string is inserted at the start of start_line (use start_line = last line + 1 to append at end of file). An edit that introduces lex/parse errors into a .mbt/.mbt.md file is auto-rolled-back and the parse errors are returned — see revert_on_parse_errors. For multiple compiler-feedback fixes in one file, use multi_edit with explicit line-anchored edits.",
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
          "description": "Auto-revert safety net, on by default. After the edit is written to a .mbt/.mbt.md file, `moon check` runs; if the edit INTRODUCED lex/parse errors (error codes 3000-3999) into the file — measured against the pre-edit content, so pre-existing parse errors are ignored — the file is restored to its pre-edit content and the call returns the parse errors with source context. Type errors (4xxx) never trigger the revert; they may be a legitimate transient state. Set false only to intentionally produce content that does not parse (e.g. a fixture).",
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
    return try {
      @fs.write_file(path, new_content, create_mode=CreateOrTruncate)
      let summary = "ok: inserted at line \{input.start_line} in \{path}"
      edited_response(
        path,
        original_content=content,
        new_content~,
        summary,
        ok_brief="edited \{@agent_tool.brief_basename(path)}:\{input.start_line} (insert)",
        fail_brief~,
        revert_on_parse_errors=input.revert_on_parse_errors,
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
  try {
    @fs.write_file(path, new_content, create_mode=CreateOrTruncate)
    let summary = "ok: replaced \{replacement_count} occurrence(s) at line \{match_line} in \{path}"
    edited_response(
      path,
      original_content=content,
      new_content~,
      summary,
      ok_brief="edited \{@agent_tool.brief_basename(path)}:\{match_line} (\{replacement_count}×)",
      fail_brief~,
      revert_on_parse_errors=input.revert_on_parse_errors,
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
/// From this many newly introduced parse errors up, the revert report stops
/// suggesting a corrected re-issue and pushes splitting the change into
/// smaller edits instead: parse errors cascade, so several of them usually
/// mean a large replacement (or a misplaced insertion) broke the file's
/// structure wholesale.
const SmallerEditsHintThreshold : Int = 3

///|
/// The common tail of a successful edit write: for MoonBit source files with
/// the guard enabled, run the parse-error revert guard; otherwise append the
/// plain `moon check` feedback exactly as before the guard existed.
async fn edited_response(
  path : String,
  original_content~ : String,
  new_content~ : String,
  summary : String,
  ok_brief~ : String,
  fail_brief~ : String,
  revert_on_parse_errors~ : Bool,
) -> @agent_tool.ToolAction {
  if revert_on_parse_errors && @auto_check.is_source_path(path) {
    return parse_guarded_edit_response(
      path,
      original_content~,
      new_content~,
      summary,
      ok_brief~,
      fail_brief~,
    )
  }
  let response = @auto_check.append_summary(path, summary)
  @agent_tool.ToolAction::respond(response, brief=ok_brief)
}

///|
/// Post-edit guard for MoonBit source files: run `moon check` and, when the
/// file now has lex/parse errors, decide whether this edit introduced them.
/// The baseline is measured lazily — only when parse errors are present — by
/// restoring the pre-edit content and re-checking, so the common clean edit
/// pays for a single check. Introduced errors roll the file back and fail the
/// call with the errors and their source context; pre-existing ones re-apply
/// the edit and report honestly. Fail-open: when the check cannot run, the
/// edit is kept exactly as written.
async fn parse_guarded_edit_response(
  path : String,
  original_content~ : String,
  new_content~ : String,
  summary : String,
  ok_brief~ : String,
  fail_brief~ : String,
) -> @agent_tool.ToolAction {
  let after = check_source_or_none(path)
  guard after is Some(after) else {
    return @agent_tool.ToolAction::respond(summary, brief=ok_brief)
  }
  if after.parse_error_count == 0 {
    return @agent_tool.ToolAction::respond(
      "\{summary}\n\{@auto_check.source_check_feedback(after)}",
      brief=ok_brief,
    )
  }
  // Suspicious: the edited file has parse errors. Measure the pre-edit
  // baseline by restoring the original and re-checking, so the guard fires on
  // errors this edit INTRODUCED, not on ones that were already there.
  if !write_or_false(path, original_content) {
    // The restore write itself failed; the edit is on disk and rolling back is
    // not possible. Keep it, but flag the parse errors loudly.
    return @agent_tool.ToolAction::respond(
      "\{summary}\n\{@auto_check.source_check_feedback(after)}\nWARNING: the file now has \{after.parse_error_count} parse error(s) and could not be rolled back — fix it with further edits.",
      is_error=true,
      brief=fail_brief,
    )
  }
  // From here the PRE-EDIT content is on disk. If the call is cancelled during
  // the baseline check, put the edit back before propagating: a cancelled call
  // must not silently vanish an already-written edit (matching the tools'
  // cancel-after-write behavior elsewhere). The re-apply is best-effort — under
  // cancellation the write itself may refuse to run.
  try {
    let before = check_source_or_none(path)
    let before_parse = match before {
      Some(before) => before.parse_error_count
      None => 0
    }
    // Counts, not diagnostic identities, on purpose: an edit shifts the line
    // numbers of every pre-existing error below it, so identity matching keyed
    // on locations would false-fire constantly. The blind spot (an edit that
    // fixes one parse error while introducing another, keeping the count flat)
    // is kept, and the response below reports the surviving errors either way.
    let introduced = after.parse_error_count - before_parse
    if introduced > 0 {
      // Real breakage. Stay reverted (the original is already back on disk).
      return @agent_tool.ToolAction::respond(
        edit_revert_report(path, after, introduced~),
        is_error=true,
        brief="edit reverted (\{introduced} parse error(s))",
      )
    }
    // False alarm: as many parse errors were already present. Re-apply and keep.
    if !write_or_false(path, new_content) {
      return @agent_tool.ToolAction::respond(
        "error editing \{path}: the edit was validated but could not be re-applied after baseline measurement; the file holds its pre-edit content",
        is_error=true,
        brief=fail_brief,
      )
    }
    @agent_tool.ToolAction::respond(
      "\{summary}\n\{@auto_check.source_check_feedback(after)}\nnote: \{after.parse_error_count} parse error(s) were already present before this edit (the edit did not add to the count), so the edit was kept.",
      brief=ok_brief,
    )
  } catch {
    error => {
      let _ = write_or_false(path, new_content) catch { _ => false }
      raise error
    }
  }
}

///|
/// The reverted-edit report: what was rolled back, the first parse errors with
/// their source excerpts (from the as-edited content, which is no longer on
/// disk), and how to retry — a corrected re-issue for a small slip, smaller
/// pieces when the errors suggest the replacement broke the file's structure.
fn edit_revert_report(
  path : String,
  after : @auto_check.SourceCheck,
  introduced~ : Int,
) -> String {
  let head = "reverted: the edit introduced \{introduced} new parse error(s) in \{path}, so the file was restored to its pre-edit content."
  let shown = after.parse_errors.length()
  let errors = if shown == 0 {
    ""
  } else {
    "\nfirst \{shown} parse error(s), excerpted from the rolled-back content:\n\{after.parse_errors.join("\n")}"
  }
  let retry = if introduced >= SmallerEditsHintThreshold {
    "\n\{introduced} new parse errors usually means the replacement broke the file's structure (an unbalanced brace, a misplaced insertion, or non-MoonBit text). Do not re-issue the same edit: split it into smaller pieces — multi_edit applies several small line-anchored edits in one validated call — and check after each step."
  } else {
    "\nre-issue the edit with a corrected new_string (check delimiters against the excerpt above)."
  }
  let opt_out = "\n(To intentionally keep content that does not parse, e.g. a fixture, pass revert_on_parse_errors=false.)"
  "\{head}\{errors}\{retry}\{opt_out}"
}

///|
/// `@auto_check.check_source`, with cancellation propagated and any other
/// failure mapped to `None` (fail open — keep the edit unguarded).
async fn check_source_or_none(path : String) -> @auto_check.SourceCheck? {
  @auto_check.check_source(path) catch {
    error if @async.is_being_cancelled() => raise error
    _ => None
  }
}

///|
/// Best-effort write for the guard's restore/re-apply steps — a rollback must
/// not raise midway, so a failure is reported through the response text
/// instead.
async fn write_or_false(path : String, content : String) -> Bool {
  @fs.write_file(path, content, create_mode=CreateOrTruncate) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return false
  }
  true
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
test "edit_revert_report excerpts the rolled-back content and asks for a re-issue" {
  let after : @auto_check.SourceCheck = {
    error_count: 1,
    warning_count: 0,
    parse_error_count: 1,
    parse_errors: [
      "lib/a.mbt:7:1-7:2: Parse error, unexpected token `}`.\n  6 |  let y =\n  7 |}",
    ],
    first_errors: ["lib/a.mbt:7:1-7:2: Parse error, unexpected token `}`."],
    truncated: false,
    exit_code: Some(1),
    failure_output: None,
  }
  inspect(
    edit_revert_report("lib/a.mbt", after, introduced=1),
    content=(
      #|reverted: the edit introduced 1 new parse error(s) in lib/a.mbt, so the file was restored to its pre-edit content.
      #|first 1 parse error(s), excerpted from the rolled-back content:
      #|lib/a.mbt:7:1-7:2: Parse error, unexpected token `}`.
      #|  6 |  let y =
      #|  7 |}
      #|re-issue the edit with a corrected new_string (check delimiters against the excerpt above).
      #|(To intentionally keep content that does not parse, e.g. a fixture, pass revert_on_parse_errors=false.)
    ),
  )
}

///|
test "edit_revert_report pushes smaller edits when parse errors cascade" {
  let after : @auto_check.SourceCheck = {
    error_count: 5,
    warning_count: 0,
    parse_error_count: 5,
    parse_errors: ["lib/a.mbt:1:1-1:2: Parse error."],
    first_errors: [],
    truncated: false,
    exit_code: Some(1),
    failure_output: None,
  }
  let report = edit_revert_report("lib/a.mbt", after, introduced=4)
  assert_true(report.contains("4 new parse errors usually means"))
  assert_true(report.contains("split it into smaller pieces"))
  assert_false(report.contains("re-issue the edit with a corrected new_string"))
}
