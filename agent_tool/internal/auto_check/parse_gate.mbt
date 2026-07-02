///|
/// Standalone syntax gate for `.mbt` content, built on
/// `moonc compile -stop-after-parsing`: the compiler parses one file with no
/// project context, so candidate content can be validated in a scratch file
/// BEFORE it is written to its destination — a reject leaves no broken file to
/// delete or restore. `-stop-after-parsing` reports only lexer/parser
/// diagnostics (type errors never appear), making this a pure syntax check.
///
/// TODO(.mbt.md): raw moonc lexes markdown files as MoonBit source (the `#`
/// heading and ``` fences themselves become lexing errors), so `.mbt.md`
/// content cannot be gated this way. Gating doc files would need moon's own
/// fenced-block extraction (```moonbit check vs plain fences, nocheck
/// attributes); until then `.mbt.md` writes and edits are not parse-gated.
const MooncParseCommand : String = "moonc compile -no-intermediate-file -stop-after-parsing -error-format json"

///|
const MooncParseTimeoutMs : Int = 10000

///|
const MooncParseMaxOutputChars : Int = 200000

///|
/// The scratch file is always named this and the command runs from the scratch
/// directory, so the command line never embeds a host path that would need
/// platform-specific quoting.
const ParseGateFileName : String = "parse_gate.mbt"

///|
/// One lex/parse diagnostic from the gate. `loc` keeps the compiler's
/// `line:col-line:col` shape; the caller renders excerpts from the content it
/// already holds in memory (moonc's own `context` field is empty).
pub(all) struct ParseGateError {
  loc : String
  message : String
} derive(Debug)

///|
/// Parse `content` as a single standalone `.mbt` file and return its
/// lex/parse errors (empty array = parses cleanly). Returns `None` when the
/// gate could not run — moonc missing, scratch dir unwritable, timeout — so
/// callers fail open, matching the other auto-check guards.
pub async fn content_parse_errors(content : String) -> Array[ParseGateError]? {
  let dir = @fs.tmpdir(prefix="openseek-parse-gate-") catch {
    error if @async.is_being_cancelled() => raise error
    _ => return None
  }
  // Best-effort cleanup on every path; a leaked scratch dir must never turn
  // into a raised error that masks the gate's answer.
  async fn cleanup() {
    @fs.rmdir(dir, recursive=true) catch {
      error if @async.is_being_cancelled() => raise error
      _ => ()
    }
  }
  try {
    @fs.write_file(
      "\{dir}/\{ParseGateFileName}",
      content,
      create_mode=CreateOrTruncate,
    )
    let result = @async.with_timeout_opt(MooncParseTimeoutMs, () => {
      @shell.collect_shell_output(
        "\{MooncParseCommand} \{ParseGateFileName}",
        cwd=dir,
        max_output_chars=MooncParseMaxOutputChars,
      )
    })
    match result {
      Some(output) => decide_parse_gate(output.text, output.exit_code)
      None => None
    }
  } catch {
    error if @async.is_being_cancelled() => {
      cleanup()
      raise error
    }
    _ => {
      cleanup()
      None
    }
  } noraise {
    result => {
      cleanup()
      result
    }
  }
}

///|
/// Interpret one moonc run: parse-error diagnostics found → those errors; a
/// clean exit with none → an empty array; anything else (moonc missing → 127,
/// crash, unparseable output) → `None`, so the caller fails open. A non-zero
/// exit with no captured parse errors is deliberately `None` rather than
/// "clean": the gate must never certify content it did not actually parse.
fn decide_parse_gate(
  text : String,
  exit_code : Int?,
) -> Array[ParseGateError]? {
  let errors : Array[ParseGateError] = []
  for raw in text.split("\n") {
    if !raw.contains("\"level\"") {
      continue
    }
    let json = @json.parse(raw.to_owned()) catch { _ => continue }
    guard json is Object(fields) else { continue }
    if fields.get("level") is Some(String("error")) &&
      is_parse_error_code(fields) {
      errors.push({
        loc: json_string_field(fields, "loc"),
        message: json_string_field(fields, "message"),
      })
    }
  }
  if errors.length() > 0 {
    Some(errors)
  } else if exit_code is Some(0) {
    Some([])
  } else {
    None
  }
}

///|
/// Render up to `ParseErrorDisplayLimit` gate errors as
/// `path:loc: message` lines, each followed by a numbered excerpt of the
/// offending lines synthesized from `content` — the content is not on disk
/// (the write was rejected), so these excerpts are the model's only view of
/// the broken spot.
pub fn format_parse_gate_errors(
  display_path : String,
  content : String,
  errors : Array[ParseGateError],
) -> Array[String] {
  let lines = content.split("\n").map(line => line.to_owned()).collect()
  let shown = if errors.length() < ParseErrorDisplayLimit {
    errors.length()
  } else {
    ParseErrorDisplayLimit
  }
  [
    for error in errors[0:shown] => {
      let header = if error.loc == "" {
        "\{display_path}: \{error.message}"
      } else {
        "\{display_path}:\{error.loc}: \{error.message}"
      }
      let excerpt = excerpt_for_loc(lines, error.loc)
      if excerpt == "" {
        header
      } else {
        "\{header}\n\{excerpt}"
      }
    }
  ]
}

///|
/// Numbered source excerpt for a `line:col-line:col` location: one line of
/// leading context plus the error span (capped), in the compiler's own
/// `N |text` shape indented by two spaces.
fn excerpt_for_loc(lines : Array[String], loc : String) -> String {
  guard loc_line_span(loc) is Some((start_line, end_line)) else { return "" }
  let first = if start_line <= 1 { 1 } else { start_line - 1 }
  if first > lines.length() {
    return ""
  }
  // Cap the span so a single error covering a huge region cannot flood the
  // report; the error line itself always shows.
  let mut last = if end_line > start_line + 3 { start_line + 3 } else { end_line }
  if last > lines.length() {
    last = lines.length()
  }
  if last < first {
    last = first
  }
  let width = "\{last}".length()
  let rendered = [
    for number in first..=last => "  \{pad_line_number(number, width)} |\{lines[number - 1]}"
  ]
  rendered.join("\n")
}

///|
/// The inclusive 1-based `(first, last)` line pair named by a compiler `loc`
/// like `7:1-9:2` (or a bare `7:1`). `None` when the loc is malformed.
fn loc_line_span(loc : String) -> (Int, Int)? {
  let parts = loc.split("-").map(part => part.to_owned()).collect()
  guard parts.length() >= 1 && parts[0] != "" else { return None }
  guard leading_line_number(parts[0]) is Some(start) else { return None }
  let end = if parts.length() >= 2 {
    match leading_line_number(parts[1]) {
      Some(end) => end
      None => start
    }
  } else {
    start
  }
  Some((start, if end < start { start } else { end }))
}

///|
fn leading_line_number(part : String) -> Int? {
  let digits = match part.find(":") {
    Some(cut) => part[:cut].to_owned()
    None => part
  }
  if digits == "" {
    return None
  }
  let mut value = 0
  for ch in digits {
    if ch < '0' || ch > '9' {
      return None
    }
    value = value * 10 + (ch.to_int() - '0'.to_int())
  }
  Some(value)
}

///|
fn pad_line_number(number : Int, width : Int) -> String {
  "\{number}".pad_start(width, ' ')
}

///|
test "decide_parse_gate splits errors, clean, and cannot-run" {
  let broken =
    #|{"$message_type":"diagnostic","level":"error","error_code":3002,"path":"parse_gate.mbt","loc":"5:2-5:2","message":"Parse error, unexpected token `end of file`.","context":""}
  guard decide_parse_gate(broken, Some(2)) is Some(errors) else {
    fail("expected errors")
  }
  assert_eq(errors.length(), 1)
  assert_eq(errors[0].loc, "5:2-5:2")
  // Clean run: exit 0, no diagnostics.
  guard decide_parse_gate("", Some(0)) is Some(clean) else {
    fail("expected clean")
  }
  assert_eq(clean.length(), 0)
  // moonc missing (127) or any failure without parse diagnostics: fail open,
  // never certify unparsed content as clean.
  assert_true(decide_parse_gate("sh: moonc: command not found", Some(127)) is None)
  assert_true(decide_parse_gate("", None) is None)
  // Warnings alone never count as parse errors.
  let warning =
    #|{"$message_type":"diagnostic","level":"warning","error_code":2,"path":"parse_gate.mbt","loc":"1:1-1:2","message":"unused","context":""}
  assert_true(decide_parse_gate(warning, Some(1)) is None)
}

///|
test "format_parse_gate_errors synthesizes numbered excerpts from content" {
  let content =
    #|///|
    #|pub fn f() -> Int {
    #|  let x =
    #|}
  let formatted = format_parse_gate_errors("lib/a.mbt", content, [
    { loc: "4:1-4:2", message: "Parse error, unexpected token `}`." },
  ])
  assert_eq(formatted.length(), 1)
  assert_eq(
    formatted[0],
    (
      #|lib/a.mbt:4:1-4:2: Parse error, unexpected token `}`.
      #|  3 |  let x =
      #|  4 |}
    ),
  )
}

///|
test "format_parse_gate_errors caps at the display limit and handles bad locs" {
  let errors = [
    for index in 0..<9 => ({
      loc: "\{index + 1}:1-\{index + 1}:2",
      message: "e\{index}",
    } : ParseGateError)
  ]
  let formatted = format_parse_gate_errors("a.mbt", "one\ntwo\nthree", errors)
  assert_eq(formatted.length(), ParseErrorDisplayLimit)
  // A loc beyond the content and a malformed loc degrade to the bare header.
  let odd = format_parse_gate_errors("a.mbt", "only", [
    { loc: "9:1-9:2", message: "past the end" },
    { loc: "junk", message: "no loc" },
    { loc: "", message: "empty loc" },
  ])
  assert_eq(odd[0], "a.mbt:9:1-9:2: past the end")
  assert_eq(odd[1], "a.mbt:junk: no loc")
  assert_eq(odd[2], "a.mbt: empty loc")
}

///|
test "loc_line_span reads spans, single points, and rejects junk" {
  assert_true(loc_line_span("7:1-9:2") is Some((7, 9)))
  assert_true(loc_line_span("7:1") is Some((7, 7)))
  assert_true(loc_line_span("7") is Some((7, 7)))
  // A reversed span clamps to the start line rather than going negative.
  assert_true(loc_line_span("9:1-7:2") is Some((9, 9)))
  assert_true(loc_line_span("") is None)
  assert_true(loc_line_span("abc:1") is None)
}

///|
/// Real-moonc round trips: unlike `moon check`, the standalone gate can run
/// inside `moon test` safely (no project build lock is involved).
async test "content_parse_errors gates real content through moonc" {
  guard content_parse_errors("///|\npub fn ok() -> Int {\n  42\n}\n")
    is Some(clean) else {
    fail("expected the gate to run (is moonc on PATH?)")
  }
  assert_eq(clean.length(), 0)
  guard content_parse_errors("///|\npub fn bad() -> Int {\n  let x =\n}\n")
    is Some(errors) else {
    fail("expected the gate to run (is moonc on PATH?)")
  }
  assert_true(errors.length() > 0)
  assert_true(errors[0].message.contains("Parse error"))
}
