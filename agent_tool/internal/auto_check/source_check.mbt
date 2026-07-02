///|
/// How many lex/parse errors a revert report surfaces. Lower than
/// `RevertErrorDisplayLimit` because each entry carries its `context` source
/// excerpt, and parse errors cascade — a handful shows the shape of the
/// breakage without dumping pages.
pub const ParseErrorDisplayLimit : Int = 5

///|
/// The `moon check --output-json` `error_code` range for lexer and parser
/// diagnostics (e.g. 3001 "Lexing error", 3002 "Parse error"). Codes at 4000
/// and above are type/resolution errors, which a fresh file or edit may
/// legitimately introduce as a transient state during multi-file work; codes
/// in this range mean the file content itself is malformed.
const ParseErrorCodeMin : Int = 3000

///|
const ParseErrorCodeMax : Int = 3999

///|
/// A source-scoped `moon check --output-json` tally: project-wide error and
/// warning counts, plus lex/parse errors located in one target file. The
/// `parse_errors` entries keep the diagnostic's `context` excerpt (numbered
/// source lines) so a revert report can still show the broken spot after the
/// offending content has been rolled back off disk. `truncated` means the
/// check produced more output than the capture budget, so counts are lower
/// bounds. `failure_output` is `Some` when the check exited non-zero without
/// emitting any diagnostics (e.g. a broken build plan), so feedback derived
/// from the zero counts never reads as a false "ok"; `exit_code` keeps the
/// raw exit so feedback can also avoid "ok" when the run failed for a reason
/// the captured diagnostics don't show (e.g. warnings-as-errors).
pub(all) struct SourceCheck {
  error_count : Int
  warning_count : Int
  parse_error_count : Int
  parse_errors : Array[String]
  first_errors : Array[String]
  truncated : Bool
  exit_code : Int?
  failure_output : String?
} derive(Debug)

///|
/// Run `moon check --output-json` from the MoonBit module containing `path`
/// and tally diagnostics, scoping lex/parse errors to `path` itself. Returns
/// `None` when `path` is not a relevant MoonBit file, is not inside a MoonBit
/// project, or the check could not run — callers keep their write unguarded in
/// every `None` case, matching `append_summary`'s fail-open behavior.
pub async fn check_source(path : String) -> SourceCheck? {
  let cwd = match moon_check_cwd(path) {
    Some(cwd) => cwd
    None => return None
  }
  // Diagnostic paths are absolute in current moon versions; resolving the
  // target lets them match exactly instead of relying on the suffix fallback.
  let target = @fs.realpath(path) catch {
    error if @async.is_being_cancelled() => raise error
    _ => path
  }
  let result = @async.with_timeout_opt(MoonCheckTimeoutMs, () => {
    @shell.collect_shell_output(
      MoonCheckJsonCommand,
      cwd~,
      max_output_chars=MoonCheckJsonMaxOutputChars,
    )
  }) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return None
  }
  match result {
    Some(output) =>
      Some(
        tally_source_check(
          output.text,
          target~,
          truncated=output.output_limit_reached,
          exit_code=output.exit_code,
          check_cwd=cwd,
        ),
      )
    None => None
  }
}

///|
/// Tally `moon check --output-json` output (JSON Lines: one diagnostic object
/// per line) by severity, additionally counting lex/parse errors (codes
/// 3000-3999) whose diagnostic path names `target`. Non-diagnostic lines — a
/// trailing human summary, a blank line — are ignored.
pub fn tally_source_check(
  text : String,
  target~ : String,
  truncated~ : Bool,
  exit_code~ : Int?,
  check_cwd? : String,
) -> SourceCheck {
  let mut error_count = 0
  let mut warning_count = 0
  let mut parse_error_count = 0
  let mut diagnostics_seen = false
  let parse_errors : Array[String] = []
  let first_errors : Array[String] = []
  for raw in text.split("\n") {
    // Cheap pre-filter: only diagnostic lines carry a `level` field, so a
    // blank line or a human summary never reaches the JSON parser.
    if !raw.contains("\"level\"") {
      continue
    }
    let json = @json.parse(raw.to_owned()) catch { _ => continue }
    guard json is Object(fields) else { continue }
    match fields.get("level") {
      Some(String("error")) => {
        diagnostics_seen = true
        error_count += 1
        if first_errors.length() < RevertErrorDisplayLimit {
          first_errors.push(format_diagnostic_line(fields))
        }
        if is_parse_error_code(fields) &&
          diagnostic_targets_file(
            json_string_field(fields, "path"),
            target,
            check_cwd,
          ) {
          parse_error_count += 1
          if parse_errors.length() < ParseErrorDisplayLimit {
            parse_errors.push(format_diagnostic_with_context(fields))
          }
        }
      }
      Some(String("warning")) => {
        diagnostics_seen = true
        warning_count += 1
      }
      _ => ()
    }
  }
  let failure_output = if !diagnostics_seen && exit_code != Some(0) {
    Some(format_moon_check_output_parts(exit_code, text, truncated))
  } else {
    None
  }
  {
    error_count,
    warning_count,
    parse_error_count,
    parse_errors,
    first_errors,
    truncated,
    exit_code,
    failure_output,
  }
}

///|
/// Render the keep-path `moon check` status for a kept write/edit: counts plus
/// the first error one-liners. No `context` excerpts here on purpose — the
/// file is on disk, so the model can read the flagged lines directly; context
/// is reserved for revert reports where the content is gone. Falls back to the
/// raw check output when the run failed without diagnostics, so a broken build
/// plan never reads as "ok".
pub fn source_check_feedback(check : SourceCheck) -> String {
  match check.failure_output {
    Some(raw) => return raw
    None => ()
  }
  if check.error_count == 0 {
    if check.exit_code is Some(0) && !check.truncated {
      return "moon check: ok — 0 errors, \{check.warning_count} warning(s)"
    }
    // No error diagnostics were captured, but the run did not finish cleanly
    // (non-zero exit, e.g. warnings-as-errors, or truncated capture) — never
    // call that "ok".
    let exit_label = match check.exit_code {
      Some(code) => "exit=\{code}"
      None => "exit=cancelled"
    }
    let truncated_label = if check.truncated {
      ", output truncated"
    } else {
      ""
    }
    return "moon check: 0 error(s) captured but the check did not pass (\{exit_label}\{truncated_label}), \{check.warning_count} warning(s)"
  }
  let errors = if check.truncated {
    "≥\{check.error_count}"
  } else {
    "\{check.error_count}"
  }
  let header = "moon check: \{errors} error(s), \{check.warning_count} warning(s)"
  if check.first_errors.is_empty() {
    header
  } else {
    "\{header}\n\{check.first_errors.join("\n")}"
  }
}

///|
/// Whether `path` is a hand-written MoonBit source file (`.mbt` or `.mbt.md`),
/// the file kinds the parse-error revert guard applies to. `.mbti` interface
/// files are excluded on purpose: generated ones are rejected by the manifest
/// guards, and hand-maintained ones are rare and not parsed as source here.
pub fn is_source_path(path : String) -> Bool {
  is_moonbit_source_path(path)
}

///|
fn is_parse_error_code(fields : Map[String, Json]) -> Bool {
  match fields.get("error_code") {
    Some(Number(code, ..)) => {
      let code = code.to_int()
      code >= ParseErrorCodeMin && code <= ParseErrorCodeMax
    }
    _ => false
  }
}

///|
/// Whether a diagnostic's `path` names the target file. Current moon versions
/// emit absolute (resolved) diagnostic paths and the caller resolves the
/// target, so the exact comparison usually decides. When one side is relative
/// (older moon output, or an unresolvable target), it is resolved against
/// `check_cwd` — the module root the check ran from — and compared exactly
/// again. No suffix heuristics: a false positive here deletes or rolls back a
/// clean file, while a false negative only leaves the guard fail-open, so
/// precision wins over recall.
fn diagnostic_targets_file(
  diag_path : String,
  target : String,
  check_cwd : String?,
) -> Bool {
  let diag = normalize_match_path(diag_path)
  let target = normalize_match_path(target)
  if diag == "" || target == "" {
    return false
  }
  if diag == target {
    return true
  }
  match check_cwd {
    Some(cwd) => {
      let cwd = normalize_match_path(cwd)
      resolve_against(cwd, diag) == resolve_against(cwd, target)
    }
    None => false
  }
}

///|
fn resolve_against(cwd : String, path : String) -> String {
  if is_absolute_match_path(path) || cwd == "" || cwd == "." {
    path
  } else if cwd.has_suffix("/") {
    "\{cwd}\{path}"
  } else {
    "\{cwd}/\{path}"
  }
}

///|
fn is_absolute_match_path(path : String) -> Bool {
  path.has_prefix("/") || (path.length() >= 2 && path[1] == ':')
}

///|
fn normalize_match_path(path : String) -> String {
  let path = path.replace_all(old="\\", new="/")
  if path.has_prefix("./") {
    path[2:].to_owned()
  } else {
    path
  }
}

///|
/// Render one diagnostic as `path:loc: message` followed by its indented
/// `context` excerpt (the compiler's numbered source lines). Used for revert
/// reports, where the excerpt is the model's only remaining view of the
/// content that was rolled back.
fn format_diagnostic_with_context(fields : Map[String, Json]) -> String {
  let line = format_diagnostic_line(fields)
  let context = json_string_field(fields, "context")
  if context == "" {
    return line
  }
  let excerpt = [
    for context_line in context.split("\n") if !context_line.is_empty() => {
      "  \{context_line}"
    }
  ]
  "\{line}\n\{excerpt.join("\n")}"
}

///|
test "tally_source_check scopes parse errors to the target file" {
  // Real shapes: absolute diagnostic paths, 3xxx parse codes, context excerpts.
  let text =
    #|{"$message_type":"diagnostic","level":"error","error_code":3002,"path":"/ws/lib/new.mbt","loc":"7:1-7:2","message":"Parse error, unexpected token `}`.","context":"6 |  let y =\n7 |}\n"}
    #|{"$message_type":"diagnostic","level":"error","error_code":3001,"path":"/ws/lib/other.mbt","loc":"3:3-3:4","message":"Lexing error: (unterminated string literal)","context":"3 |  \"oops\n"}
    #|{"$message_type":"diagnostic","level":"error","error_code":4014,"path":"/ws/lib/new.mbt","loc":"9:3-9:5","message":"Expr Type Mismatch","context":"9 |  x\n"}
    #|{"$message_type":"diagnostic","level":"warning","error_code":2,"path":"/ws/lib/new.mbt","loc":"6:7-6:8","message":"Warning (unused_value): Unused variable 'y'","context":"6 |  let y = \n"}
  let check = tally_source_check(
    text,
    target="/ws/lib/new.mbt",
    truncated=false,
    exit_code=Some(1),
  )
  // The 3001 in other.mbt and the 4014 type error never count as parse errors
  // for the target; both still land in the project-wide error tally.
  assert_eq(check.error_count, 3)
  assert_eq(check.warning_count, 1)
  assert_eq(check.parse_error_count, 1)
  assert_true(check.failure_output is None)
  assert_eq(check.parse_errors.length(), 1)
  assert_eq(
    check.parse_errors[0],
    (
      #|/ws/lib/new.mbt:7:1-7:2: Parse error, unexpected token `}`.
      #|  6 |  let y =
      #|  7 |}
    ),
  )
}

///|
test "tally_source_check resolves relative diagnostic paths via the check cwd" {
  let text =
    #|{"$message_type":"diagnostic","level":"error","error_code":3002,"path":"lib/new.mbt","loc":"1:1-1:2","message":"Parse error.","context":""}
  let check = tally_source_check(
    text,
    target="/ws/lib/new.mbt",
    truncated=false,
    exit_code=Some(1),
    check_cwd="/ws",
  )
  assert_eq(check.parse_error_count, 1)
  // A diagnostic without a context excerpt renders as the bare one-liner.
  assert_eq(check.parse_errors[0], "lib/new.mbt:1:1-1:2: Parse error.")
  // A different target under the same cwd must not match.
  let other = tally_source_check(
    text,
    target="/ws/other_lib/wrong_new.mbt",
    truncated=false,
    exit_code=Some(1),
    check_cwd="/ws",
  )
  assert_eq(other.parse_error_count, 0)
  // Without a cwd a relative diagnostic cannot be resolved — fail open (no
  // match) rather than guessing by suffix.
  let no_cwd = tally_source_check(
    text,
    target="/ws/lib/new.mbt",
    truncated=false,
    exit_code=Some(1),
  )
  assert_eq(no_cwd.parse_error_count, 0)
}

///|
test "tally_source_check caps surfaced parse errors but keeps the full count" {
  let lines : Array[String] = []
  for index in 0..<9 {
    lines.push(
      "{\"$message_type\":\"diagnostic\",\"level\":\"error\",\"error_code\":3002,\"path\":\"/ws/a.mbt\",\"loc\":\"\{index}:1-\{index}:2\",\"message\":\"e\{index}\",\"context\":\"\"}",
    )
  }
  let check = tally_source_check(
    lines.join("\n"),
    target="/ws/a.mbt",
    truncated=false,
    exit_code=Some(1),
  )
  assert_eq(check.parse_error_count, 9)
  assert_eq(check.parse_errors.length(), ParseErrorDisplayLimit)
}

///|
test "tally_source_check reports a failed check with no diagnostics" {
  let text =
    #|Error: Failed to calculate build plan
  let check = tally_source_check(
    text,
    target="/ws/a.mbt",
    truncated=false,
    exit_code=Some(255),
  )
  assert_eq(check.error_count, 0)
  assert_eq(check.parse_error_count, 0)
  guard check.failure_output is Some(raw) else {
    fail("expected failure output")
  }
  assert_true(raw.contains("exit=255"))
  assert_true(raw.contains("Failed to calculate build plan"))
  // A clean run with no diagnostics is just ok — no failure output.
  let clean = tally_source_check(
    "Finished. moon: ran 2 tasks, now up to date",
    target="/ws/a.mbt",
    truncated=false,
    exit_code=Some(0),
  )
  assert_true(clean.failure_output is None)
}

///|
test "source_check_feedback renders ok, errors, and failure fallback" {
  let ok : SourceCheck = {
    error_count: 0,
    warning_count: 2,
    parse_error_count: 0,
    parse_errors: [],
    first_errors: [],
    truncated: false,
    exit_code: Some(0),
    failure_output: None,
  }
  assert_eq(
    source_check_feedback(ok),
    "moon check: ok — 0 errors, 2 warning(s)",
  )
  let errors : SourceCheck = {
    error_count: 3,
    warning_count: 0,
    parse_error_count: 0,
    parse_errors: [],
    first_errors: ["a.mbt:1:1-1:2: boom"],
    truncated: true,
    exit_code: Some(1),
    failure_output: None,
  }
  assert_eq(
    source_check_feedback(errors),
    (
      #|moon check: ≥3 error(s), 0 warning(s)
      #|a.mbt:1:1-1:2: boom
    ),
  )
  let failed : SourceCheck = {
    error_count: 0,
    warning_count: 0,
    parse_error_count: 0,
    parse_errors: [],
    first_errors: [],
    truncated: false,
    exit_code: Some(255),
    failure_output: Some("moon check:\nexit=255\nError: broken plan"),
  }
  assert_eq(
    source_check_feedback(failed),
    "moon check:\nexit=255\nError: broken plan",
  )
  // Zero errors captured but a non-zero exit (e.g. warnings-as-errors) or a
  // truncated capture must never render as "ok".
  let unclean : SourceCheck = {
    error_count: 0,
    warning_count: 4,
    parse_error_count: 0,
    parse_errors: [],
    first_errors: [],
    truncated: false,
    exit_code: Some(1),
    failure_output: None,
  }
  assert_eq(
    source_check_feedback(unclean),
    "moon check: 0 error(s) captured but the check did not pass (exit=1), 4 warning(s)",
  )
  let clipped : SourceCheck = {
    error_count: 0,
    warning_count: 0,
    parse_error_count: 0,
    parse_errors: [],
    first_errors: [],
    truncated: true,
    exit_code: Some(0),
    failure_output: None,
  }
  assert_eq(
    source_check_feedback(clipped),
    "moon check: 0 error(s) captured but the check did not pass (exit=0, output truncated), 0 warning(s)",
  )
}

///|
test "diagnostic path matching is exact, resolving relative sides via cwd" {
  assert_true(diagnostic_targets_file("/ws/lib/a.mbt", "/ws/lib/a.mbt", None))
  assert_true(
    diagnostic_targets_file("lib/a.mbt", "/ws/lib/a.mbt", Some("/ws")),
  )
  assert_true(
    diagnostic_targets_file("/ws/lib/a.mbt", "lib/a.mbt", Some("/ws")),
  )
  assert_true(
    diagnostic_targets_file("lib\\a.mbt", "/ws/lib/a.mbt", Some("/ws")),
  )
  assert_true(diagnostic_targets_file("./lib/a.mbt", "lib/a.mbt", None))
  assert_false(
    diagnostic_targets_file("lib/a.mbt", "/ws/lib/b.mbt", Some("/ws")),
  )
  assert_false(diagnostic_targets_file("a.mbt", "/ws/extra_a.mbt", Some("/ws")))
  assert_false(diagnostic_targets_file("", "/ws/a.mbt", None))
  // No suffix guessing: a same-suffix file rooted elsewhere must not match,
  // and a relative diagnostic without a cwd cannot match an absolute target.
  assert_false(
    diagnostic_targets_file(
      "src/lib/a.mbt",
      "/ws/other/src/lib/a.mbt",
      Some("/ws"),
    ),
  )
  assert_false(diagnostic_targets_file("lib/a.mbt", "/ws/lib/a.mbt", None))
}
