///|
/// Keep only the trailing `max_chars` characters of `content`. Char-based
/// rather than byte-based so multi-byte sequences aren't split.
fn retain_output_tail(content : String, max_chars : Int) -> String {
  if content.char_length() <= max_chars {
    content
  } else {
    let keep_from = content.char_length() - max_chars
    match content.offset_of_nth_char(keep_from) {
      Some(offset) => "\{content[offset:]}"
      None => content
    }
  }
}

///|
/// Return the part of `content` after the most recent
/// `Success/Had errors, waiting for filesystem changes...` marker. Keeps the
/// snapshot focused on the latest watcher pass instead of accumulating every
/// prior run. If the marker is on the last line (so the trailing slice would
/// be empty), the original `content` is returned unchanged — that gives the
/// caller something to display while the next run is still spooling up.
fn latest_run_segment(content : String) -> String {
  let success = "Success, waiting for filesystem changes..."
  let errors = "Had errors, waiting for filesystem changes..."
  let mut start = 0
  let mut offset = 0
  for line in content.split("\n") {
    offset += line.length() + 1
    if line.contains(success) || line.contains(errors) {
      start = offset
    }
  }
  let segment = content[start:]
  if segment == "" {
    content
  } else {
    "\{segment}"
  }
}

///|
fn moon_check_run_complete(content : String) -> Bool {
  content.contains("Success, waiting for filesystem changes...") ||
  content.contains("Had errors, waiting for filesystem changes...")
}

///|
/// Detect the moon-itself-crashed banner (panic / accidental crash). Distinct
/// from MoonBit compile errors, which leave the watcher running.
fn moon_check_output_is_crash(output : String) -> Bool {
  output.contains("`moon` has accidentally crashed.") ||
  output.contains("panicked at")
}

///|
fn ensure_trailing_newline(output : String) -> String {
  if output == "" || output.has_suffix("\n") {
    output
  } else {
    "\{output}\n"
  }
}

///|
/// Reduce a `moon` panic banner into a few lines the agent can act on:
/// exit code, crash flag, the `panicked at ...` line, the underlying detail,
/// and the restart budget. The full upstream "Please report it at ..." block
/// is dropped to keep the context window clean across restarts.
fn compact_moon_check_exit_output(
  output : String,
  exit_code : Int,
  restart_attempt~ : Int,
  restart_limit~ : Int,
) -> String {
  let lines : Array[String] = []
  lines.push("[moon_check watcher exited]")
  lines.push("exit=\{exit_code}")
  if moon_check_output_is_crash(output) {
    lines.push("moon_crash=true")
  }
  match first_line_containing(output, "panicked at") {
    Some(line) => lines.push("panic=\{line}")
    None => ()
  }
  match first_line_containing(output, "called `") {
    Some(line) => lines.push("detail=\{line}")
    None => ()
  }
  if restart_attempt <= restart_limit {
    lines.push("restart=attempt \{restart_attempt}/\{restart_limit}")
  } else {
    lines.push("restart=limit reached \{restart_limit}/\{restart_limit}")
  }
  lines.join("\n")
}

///|
fn first_line_containing(content : String, needle : String) -> String? {
  for line in content.split("\n") {
    if line.contains(needle) {
      return Some("\{line.trim()}")
    }
  }
  None
}

///|
/// `\nexit=<code>` when the watcher recorded an exit code, else empty. Shared
/// by `moon_check_response` formatting helpers.
fn MoonCheckSnapshot::exit_suffix(self : MoonCheckSnapshot) -> String {
  match self.exit_code {
    Some(code) => "\nexit=\{code}"
    None => ""
  }
}

///|
/// `\nrestart_count=...\nrestart_limit=...` (plus an optional
/// `\nrestart_reason=...`) once a restart has happened or a reason is pending,
/// else empty. Shared by `moon_check_response` formatting helpers.
fn MoonCheckSnapshot::restart_suffix(self : MoonCheckSnapshot) -> String {
  if self.restart_count > 0 || self.restart_reason is Some(_) {
    let reason = match self.restart_reason {
      Some(reason) => "\nrestart_reason=\{reason}"
      None => ""
    }
    "\nrestart_count=\{self.restart_count}\nrestart_limit=\{self.restart_limit}\{reason}"
  } else {
    ""
  }
}

///|
/// The captured output on its own line, or the `(no output yet)` placeholder.
/// Shared by `moon_check_response` formatting helpers.
fn MoonCheckSnapshot::output_suffix(self : MoonCheckSnapshot) -> String {
  if self.output == "" {
    "\n(no output yet)"
  } else {
    "\n\{self.output}"
  }
}

///|
/// Format the `ToolAction` body returned to the agent. `watcher` is one of
/// `"started"`, `"reused"`, or `"restarted"`. Includes the watcher id, status,
/// seq, optional exit/truncation/restart metadata, then the captured output.
fn moon_check_response(
  watcher : String,
  snapshot : MoonCheckSnapshot,
) -> String {
  let truncated = if snapshot.output_truncated {
    "\ntruncated=true\nmax_output_chars=\{snapshot.max_output_chars}"
  } else {
    ""
  }
  "cwd=\{snapshot.cwd.unwrap_or(".")}\ncommand=\{snapshot.command}\nwatcher=\{watcher}\nid=\{snapshot.id}\nstatus=\{moon_check_status_label(snapshot.status)}\nseq=\{snapshot.seq}\{snapshot.exit_suffix()}\{truncated}\{snapshot.restart_suffix()}\{snapshot.output_suffix()}"
}

///|
fn moon_check_status_label(status : WatcherStatus) -> String {
  match status {
    Running => "running"
    Stopped => "stopped"
  }
}

///|
/// Heuristic for the `is_error` flag on the tool response. A snapshot is an
/// error when the watcher exited non-zero, or when the latest output contains
/// any of moon's error markers (`Had errors`, JSON `"level":"error"`,
/// `ERROR Run failed`, `Failed with N errors.`, or the project-level
/// `Error: failed when checking project`).
fn moon_check_snapshot_is_error(snapshot : MoonCheckSnapshot) -> Bool {
  match snapshot.exit_code {
    Some(code) if code != 0 => true
    _ =>
      snapshot.output.contains("Had errors, waiting for filesystem changes...") ||
      snapshot.output.contains("\"level\":\"error\"") ||
      snapshot.output.contains("ERROR Run failed") ||
      (
        snapshot.output.contains("Failed with") &&
        snapshot.output.contains("errors.")
      ) ||
      snapshot.output.contains("Error: failed when checking project")
  }
}

///|
test "moon_check compacts moon watcher crash output" {
  let summary = compact_moon_check_exit_output(
    (
      #|thread 'notify-rs kqueue loop' panicked at /Users/runner/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/kqueue-1.1.1/src/lib.rs:661:86:
      #|called `Option::unwrap()` on a `None` value
      #|`moon` has accidentally crashed.
      #|Please report it at:
      #|    https://github.com/moonbitlang/moon/issues/new?template=bug_report.md
      #|
    ),
    101,
    restart_attempt=2,
    restart_limit=3,
  )
  inspect(
    summary,
    content=(
      #|[moon_check watcher exited]
      #|exit=101
      #|moon_crash=true
      #|panic=thread 'notify-rs kqueue loop' panicked at /Users/runner/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/kqueue-1.1.1/src/lib.rs:661:86:
      #|detail=called `Option::unwrap()` on a `None` value
      #|restart=attempt 2/3
    ),
  )
  assert_false(summary.contains("Please report it at"))
  assert_false(summary.contains("github.com/moonbitlang/moon/issues"))
}
