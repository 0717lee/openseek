///|
/// Verdict of one behavioral probe run against a trial's workspace, with the
/// `reason` it failed ("ok" when it passed).
pub struct ProbeResult {
  passed : Bool
  reason : String
}

///|
/// Validation verdict for one trial's finished workspace.
pub struct ValidationResult {
  passed : Bool
  reason : String
  moon_check : Bool
  moon_test : Bool
  file_probe : Bool
  stdin_probe : Bool
  duplicate_probe : Bool
}

///|
/// Everything recorded about one analyzed prompt-task trial.
pub struct TrialResult {
  index : Int
  prompt_label : String
  success : Bool
  reason : String
  workspace : String
  log_path : String
  session_id : String
  events_path : String
  exit_code : Int
  steps : Int
  tool_results : Int
  tool_errors : Int
  shell_uses : Int
  shell_failures : Int
  runtime_notices : Int
  finished : Bool
  finish_message : String
  terminal_status : String
  terminal_message : String
  validation : ValidationResult
  parse_errors : Int
  partial_tail : Bool
  moon_check_uses : Int
  moon_test_uses : Int
  moon_run_e_mentions : Int
  moon_run_c_mentions : Int
  bad_run_e_mentions : Int
  from_str_mentions : Int
  parse_int_mentions : Int
  argparse_mentions : Int
  old_argparse_mentions : Int
  c_ffi_mentions : Int
  env_args_mentions : Int
  result_style_mentions : Int
  try_mentions : Int
  warnings : String
}

///|
/// One prompt-task eval analysis report.
pub struct EvalReport {
  model : String
  prompt_label : String
  task_file : String
  runs : Int
  concurrency : Int
  min_successes : Int
  successes : Int
  out_dir : String
  results : Array[TrialResult]
}

///|
priv struct SessionMetrics {
  finished : Bool
  finish_message : String
  steps : Int
  tool_results : Int
  tool_errors : Int
  shell_uses : Int
  shell_failures : Int
  runtime_notices : Int
  terminal_status : String
  terminal_message : String
  text : String
}

///|
/// Analyze an existing prompt-task run directory.
pub async fn analyze_run(out_dir : String) -> EvalReport {
  analyze_manifest(@manifest.read_manifest(out_dir))
}

///|
/// Analyze a prompt-task run manifest and write report artifacts.
pub async fn analyze_manifest(manifest : @manifest.RunManifest) -> EvalReport {
  let results : Array[TrialResult] = []
  for trial in manifest.trials {
    results.push(analyze_trial(manifest, trial))
  }
  let report : EvalReport = {
    model: manifest.model,
    prompt_label: manifest.prompt_label,
    task_file: manifest.task_file,
    runs: manifest.runs,
    concurrency: manifest.concurrency,
    min_successes: manifest.min_successes,
    successes: count_successes(results),
    out_dir: manifest.out_dir,
    results,
  }
  write_report_files(report)
  report
}

///|
async fn analyze_trial(
  manifest : @manifest.RunManifest,
  trial : @manifest.TrialArtifact,
) -> TrialResult {
  let events_missing = !@fs.exists(trial.events_path)
  let events_text = if events_missing {
    ""
  } else {
    @fs.read_file(trial.events_path).text()
  }
  let parsed = @session_log.parse_events(events_text)
  let session = @session_log.session_from_parse(
    parsed,
    id=trial.session_id,
    system_prompt="",
  )
  let session_summary = summarize_session(session)
  let validation = validate_toml_workspace(trial.workspace)
  let reasons : Array[String] = []
  if trial.exit_code != 0 {
    reasons.push("agent process exited \{trial.exit_code}")
  }
  if events_missing {
    reasons.push("events log missing")
  }
  if parsed.errors.length() > 0 {
    reasons.push("events decode errors \{parsed.errors.length()}")
  }
  if !session_summary.finished && session_summary.terminal_status != "" {
    reasons.push(
      "agent terminal " +
      session_summary.terminal_status +
      ": " +
      session_summary.terminal_message,
    )
  } else if !session_summary.finished {
    reasons.push("finish marker missing")
  }
  if !validation.passed {
    reasons.push(validation.reason)
  }
  let warnings : Array[String] = []
  if parsed.partial_tail {
    warnings.push("trailing partial event ignored")
  }
  if session_summary.shell_uses > 0 {
    warnings.push("shell output observed \{session_summary.shell_uses} time(s)")
  }
  let success = reasons.length() == 0
  let text = session_summary.text
  {
    index: trial.index,
    prompt_label: manifest.prompt_label,
    success,
    reason: if success {
      "ok"
    } else {
      reasons.join("; ")
    },
    workspace: trial.workspace,
    log_path: trial.log_path,
    session_id: trial.session_id,
    events_path: trial.events_path,
    exit_code: trial.exit_code,
    steps: session_summary.steps,
    tool_results: session_summary.tool_results,
    tool_errors: session_summary.tool_errors,
    shell_uses: session_summary.shell_uses,
    shell_failures: session_summary.shell_failures,
    runtime_notices: session_summary.runtime_notices,
    finished: session_summary.finished,
    finish_message: session_summary.finish_message,
    terminal_status: session_summary.terminal_status,
    terminal_message: session_summary.terminal_message,
    validation,
    parse_errors: parsed.errors.length(),
    partial_tail: parsed.partial_tail,
    moon_check_uses: count_occurrences(text, "moon check"),
    moon_test_uses: count_occurrences(text, "moon test"),
    moon_run_e_mentions: count_lines_containing_all(text, ["moon run", " -e"]),
    moon_run_c_mentions: count_lines_containing_all(text, ["moon run", " -c"]),
    bad_run_e_mentions: count_occurrences(
      text, "a value is required for `-e <SCRIPT>`",
    ),
    from_str_mentions: count_occurrences(text, "@string.from_str"),
    parse_int_mentions: count_occurrences(text, "@string.parse_int"),
    argparse_mentions: count_occurrences(text, "@argparse.parse") +
    count_occurrences(text, ".parse("),
    old_argparse_mentions: count_occurrences(text, "@argparse.command") +
    count_occurrences(text, "@argparse.flag") +
    count_occurrences(text, "@argparse.argument") +
    count_occurrences(text, ".is_present") +
    count_occurrences(text, ".value("),
    c_ffi_mentions: count_occurrences(text, "extern \"c\"") +
    count_occurrences(text, "native-stub"),
    env_args_mentions: count_occurrences(text, "@env.args"),
    result_style_mentions: count_occurrences(text, "Result[") +
    count_occurrences(text, "Ok(") +
    count_occurrences(text, "Err("),
    try_mentions: count_occurrences(text, "try?") +
    count_occurrences(text, "try!"),
    warnings: if warnings.length() == 0 {
      ""
    } else {
      warnings.join("; ")
    },
  }
}

///|
fn summarize_session(session : @agent_session.Session) -> SessionMetrics {
  let text = StringBuilder::new()
  let mut finished = false
  let mut finish_message = ""
  let mut steps = 0
  let mut tool_results = 0
  let mut tool_errors = 0
  let mut shell_uses = 0
  let mut shell_failures = 0
  let mut runtime_notices = 0
  let mut terminal_status = ""
  let mut terminal_message = ""
  for event in session.events() {
    append_item_text(text, event.item())
    match event.item() {
      Assistant(_) => steps += 1
      Tool(result) => {
        tool_results += 1
        if result.tool_name() == "shell" {
          shell_uses += 1
          if shell_result_failed(result.content()) {
            shell_failures += 1
          }
        }
        if result.is_error() {
          tool_errors += 1
        }
      }
      Runtime(_) => runtime_notices += 1
      Terminal(Finished(message)) => {
        finished = true
        finish_message = message
        terminal_status = "finished"
        terminal_message = message
      }
      Terminal(Aborted(message)) => {
        terminal_status = "aborted"
        terminal_message = message
      }
      Terminal(Interrupted(message)) => {
        terminal_status = "interrupted"
        terminal_message = message
      }
      Terminal(Failed(message)) => {
        terminal_status = "failed"
        terminal_message = message
      }
      _ => ()
    }
  }
  {
    finished,
    finish_message,
    steps,
    tool_results,
    tool_errors,
    shell_uses,
    shell_failures,
    runtime_notices,
    terminal_status,
    terminal_message,
    text: text.to_string(),
  }
}

///|
fn shell_result_failed(content : String) -> Bool {
  for piece in content.split("\n") {
    let line = piece.to_owned().trim().to_owned()
    if line.has_prefix("exit=") && line != "exit=0" {
      return true
    }
  }
  false
}

///|
fn append_item_text(
  out : StringBuilder,
  item : @agent_session.SessionItem,
) -> Unit {
  match item {
    User(message) => write_line(out, message.content())
    Assistant(message) => {
      if message.reasoning_content() is Some(reasoning) {
        write_line(out, reasoning)
      }
      write_line(out, message.content())
      for call in message.tool_calls() {
        write_line(out, call.name)
        write_line(out, call.arguments)
      }
    }
    Tool(result) => {
      write_line(out, result.tool_name())
      write_line(out, result.content())
    }
    Runtime(notice) => write_line(out, notice.content())
    Summary(summary) => write_line(out, summary.content())
    Terminal(terminal) =>
      match terminal {
        Finished(message)
        | Aborted(message)
        | Interrupted(message)
        | Failed(message) => write_line(out, message)
      }
  }
}

///|
fn write_line(out : StringBuilder, value : String) -> Unit {
  out.write_string(value)
  out.write_char('\n')
}

///|
async fn validate_toml_workspace(workspace : String) -> ValidationResult {
  if !@fs.exists(workspace) || @fs.kind(workspace) != Directory {
    return {
      passed: false,
      reason: "workspace missing: \{workspace}",
      moon_check: false,
      moon_test: false,
      file_probe: false,
      stdin_probe: false,
      duplicate_probe: false,
    }
  }
  let readiness = toml_workspace_readiness(workspace)
  if !readiness.passed {
    return {
      passed: false,
      reason: readiness.reason,
      moon_check: false,
      moon_test: false,
      file_probe: false,
      stdin_probe: false,
      duplicate_probe: false,
    }
  }
  let check = run_command(workspace, ["moon", "check", "--target", "native"])
  let test_probe = run_command(workspace, ["moon", "test", "--target", "native"])
  let file_probe = run_file_probe(workspace)
  let stdin_probe = run_stdin_probe(workspace)
  let duplicate_probe = run_duplicate_probe(workspace)
  let failures : Array[String] = []
  if !check.passed {
    failures.push("moon check: " + check.reason)
  }
  if !test_probe.passed {
    failures.push("moon test: " + test_probe.reason)
  }
  if !file_probe.passed {
    failures.push("file probe: " + file_probe.reason)
  }
  if !stdin_probe.passed {
    failures.push("stdin probe: " + stdin_probe.reason)
  }
  if !duplicate_probe.passed {
    failures.push("duplicate probe: " + duplicate_probe.reason)
  }
  {
    passed: failures.length() == 0,
    reason: if failures.length() == 0 {
      "ok"
    } else {
      failures.join("; ")
    },
    moon_check: check.passed,
    moon_test: test_probe.passed,
    file_probe: file_probe.passed,
    stdin_probe: stdin_probe.passed,
    duplicate_probe: duplicate_probe.passed,
  }
}

///|
async fn toml_workspace_readiness(workspace : String) -> ProbeResult {
  if !@fs.exists(workspace + "/moon.mod") {
    return { passed: false, reason: "moon.mod missing" }
  }
  if !@fs.exists(workspace + "/cmd/tomljson/moon.pkg") {
    return {
      passed: false,
      reason: "expected CLI package missing: cmd/tomljson/moon.pkg",
    }
  }
  { passed: true, reason: "ok" }
}

///|
async fn run_command(
  workspace : String,
  command : Array[String],
) -> ProbeResult {
  let args = [ for i in 1..<command.length() => command[i] ]
  let (code, output) = @process.collect_output_merged(
    command[0],
    args,
    cwd=workspace,
  )
  if code == 0 {
    { passed: true, reason: "ok" }
  } else {
    { passed: false, reason: "exit \{code}: " + summarize(output.text()) }
  }
}

///|
async fn run_file_probe(workspace : String) -> ProbeResult {
  let path = workspace + "/.openseek-file-probe.toml"
  @fs.write_file(
    path,
    (
      #|[owner]
      #|name = "Alice"
      #|age = 30
      #|[database]
      #|host = "localhost"
      #|ports = [8000, 8001]
      #|
    ),
    create_mode=CreateOrTruncate,
  )
  let (code, stdout, stderr) = @process.collect_output(
    "moon",
    ["run", "--target", "native", "cmd/tomljson", "--", path],
    cwd=workspace,
  )
  json_stdout_probe(code, stdout.text(), stderr.text())
}

///|
async fn run_stdin_probe(workspace : String) -> ProbeResult {
  let path = workspace + "/.openseek-stdin-probe.toml"
  @fs.write_file(path, "a.b.c = 42\nx.y = true\n", create_mode=CreateOrTruncate)
  let (code, stdout, stderr) = @process.collect_output(
    "moon",
    ["run", "--target", "native", "cmd/tomljson", "--", "--stdin"],
    stdin=@process.redirect_from_file(path),
    cwd=workspace,
  )
  json_stdout_probe(code, stdout.text(), stderr.text())
}

///|
async fn run_duplicate_probe(workspace : String) -> ProbeResult {
  let path = workspace + "/.openseek-duplicate-probe.toml"
  @fs.write_file(path, "key = 1\nkey = 2\n", create_mode=CreateOrTruncate)
  let (code, stdout, stderr) = @process.collect_output(
    "moon",
    ["run", "--target", "native", "cmd/tomljson", "--", "--stdin"],
    stdin=@process.redirect_from_file(path),
    cwd=workspace,
  )
  let combined = stdout.text() + stderr.text()
  if combined.contains("RUNTIME ERROR") || combined.contains("panic") {
    return { passed: false, reason: "debug/panic output leaked" }
  }
  if !combined.contains("duplicate") && !combined.contains("Duplicate") {
    return {
      passed: false,
      reason: "missing duplicate-key message, exit \{code}: " +
      summarize(combined),
    }
  }
  { passed: true, reason: "ok" }
}

///|
fn json_stdout_probe(
  code : Int,
  stdout : String,
  stderr : String,
) -> ProbeResult {
  if code != 0 {
    return {
      passed: false,
      reason: "exit \{code}: " + summarize(stdout + stderr),
    }
  }
  let trimmed = stdout.trim().to_owned()
  let _ = @json.parse(trimmed) catch {
    error =>
      return {
        passed: false,
        reason: "stdout is not JSON: \{error}; stdout=" + summarize(stdout),
      }
  }
  { passed: true, reason: "ok" }
}

///|
fn count_successes(results : Array[TrialResult]) -> Int {
  let mut count = 0
  for result in results {
    if result.success {
      count += 1
    }
  }
  count
}

///|
fn count_occurrences(content : String, needle : String) -> Int {
  if needle == "" {
    return 0
  }
  let pieces = content.split(needle).collect()
  pieces.length() - 1
}

///|
fn count_lines_containing_all(content : String, needles : Array[String]) -> Int {
  let mut count = 0
  for piece in content.split("\n") {
    let line = piece.to_owned()
    let mut matched = true
    for needle in needles {
      if !line.contains(needle) {
        matched = false
      }
    }
    if matched {
      count += 1
    }
  }
  count
}

///|
fn summarize(text : String) -> String {
  let one_line = text
    .replace_all(old="\r\n", new="\n")
    .replace_all(old="\n", new=" ")
    .trim()
    .to_owned()
  if one_line.length() <= 240 {
    one_line
  } else {
    one_line.sub(start=0, end=240).to_owned() + "..."
  }
}

///|
fn padded_index(value : Int) -> String {
  if value < 10 {
    "0" + value.to_string()
  } else {
    value.to_string()
  }
}
