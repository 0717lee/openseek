///|
/// "Best-of-N" fleet mode (`--concurrency N`): run the same task in N sibling
/// copies of `--dir` concurrently, each recording its own durable session, then
/// print a summary. The original `--dir` is never written to.
///
/// Naming uses `<base>_run_<i>` (underscores, not a dotted suffix that reads as a
/// file extension) so the run directories are unambiguous and easy to recognize.
async fn run_fleet(matches : @argparse.Matches, concurrency~ : Int) -> Unit {
  // Fleet mode owns session creation and is a one-shot batch, so it conflicts
  // with the server and the single-session/no-session/session-subcommand modes.
  guard !flag(matches, "serve") else {
    fail("--concurrency cannot be combined with --serve")
  }
  guard session_id(matches) is None else {
    fail("--concurrency runs independent sessions; remove --session")
  }
  guard !flag(matches, "no-session") else {
    fail("--concurrency records each run; remove --no-session")
  }
  guard session_command_count(matches) == 0 else {
    fail(
      "--concurrency cannot be combined with --session-list/--session-show/--session-compact-file",
    )
  }
  let task = task_text(matches)
  let api_key = api_key(matches)
  let api_url = api_url(matches)
  let model = @deepseek.Model::parse(value(matches, "model"))
  let max_steps = max_steps(matches)
  let thinking = @deepseek.ThinkingMode::parse(value(matches, "thinking"))
  let dir = trim_trailing_path_separators(
    value(matches, "dir").trim().to_owned(),
  )
  let (run_dirs, source) = resolve_run_dirs(dir, concurrency)
  // Materialize each workspace before running. A present --dir is copied; an
  // absent one yields empty workspaces (build-from-scratch best-of-N), mirroring
  // how a single run creates a missing --dir. Copies are sequential to avoid
  // thrashing the disk with N concurrent deep walks.
  for run_dir in run_dirs {
    match source {
      Some(src) => copy_tree(src, run_dir)
      None => @fs.mkdir(run_dir, recursive=true)
    }
  }
  @xlog.info() <?
    { "event": "fleet_started", "runs": concurrency, "task": task }
  let outcomes : Array[AttemptOutcome?] = Array::make(concurrency, None)
  @async.with_task_group(group => {
    for i in 0..<concurrency {
      let index = i
      let run_dir = run_dirs[i]
      // allow_failure so one crashed attempt never aborts its siblings; each
      // attempt also catches internally and records a failure outcome.
      group.spawn_bg(
        () => {
          outcomes[index] = Some(
            run_one_attempt(
              index,
              run_dir,
              matches,
              model,
              task,
              max_steps~,
              thinking~,
              api_key,
              api_url,
            ),
          )
        },
        allow_failure=true,
      )
    }
  })
  print_fleet_summary(task, outcomes)
  let mut any_ok = false
  for outcome in outcomes {
    if outcome is Some(result) && result.ok {
      any_ok = true
    }
  }
  guard any_ok else { fail("all \{concurrency} run(s) failed") }
}

///|
/// Outcome of one fleet attempt, for the summary. `ok` is true only for a
/// `finished` terminal; everything else (aborted/interrupted/failed/no terminal,
/// or a thrown error) is a non-success.
priv struct AttemptOutcome {
  index : Int
  dir : String
  session : String
  status : String
  detail : String
  ok : Bool
}

///|
/// Resolve the N run-directory paths (siblings of `--dir`) and whether there is a
/// source directory to copy. Returns `source=Some(abs)` when `--dir` exists (copy
/// it), or `None` when it is absent but its parent exists (create empty
/// workspaces). Fails if `--dir` is a file, if its parent is missing, or if a run
/// directory already exists.
async fn resolve_run_dirs(dir : String, n : Int) -> (Array[String], String?) {
  if dir.is_empty() {
    fail("--dir or OPENSEEK_DIR must not be empty")
  }
  let (parent, base, source) = if @fs.exists(dir) {
    if @fs.kind(dir) != Directory {
      fail("--dir is not a directory: \{dir}")
    }
    let abs = @fs.realpath(dir)
    (
      @path.Path(abs).dirname().to_string(),
      @path.Path(abs).basename().to_owned(),
      Some(abs),
    )
  } else {
    let parent_raw = @path.Path(dir).dirname().to_string()
    let parent_raw = if parent_raw == "" { "." } else { parent_raw }
    if !@fs.exists(parent_raw) {
      fail("parent directory for --dir does not exist: \{parent_raw}")
    }
    if @fs.kind(parent_raw) != Directory {
      fail("parent path for --dir is not a directory: \{parent_raw}")
    }
    (@fs.realpath(parent_raw), @path.Path(dir).basename().to_owned(), None)
  }
  if base.is_empty() {
    fail("cannot derive a run-directory name from --dir: \{dir}")
  }
  let run_dirs : Array[String] = []
  for i in 0..<n {
    let run_dir = @workspace_path.resolve(parent, "\{base}_run_\{i + 1}")
    if @fs.exists(run_dir) {
      fail(
        "run directory already exists: \{run_dir} (remove it or use a fresh --dir)",
      )
    }
    run_dirs.push(run_dir)
  }
  (run_dirs, source)
}

///|
/// Run one attempt in its own workspace and session, capturing the terminal as
/// an `AttemptOutcome`. Any thrown error becomes a failure outcome so one bad
/// attempt is reported, not propagated.
async fn run_one_attempt(
  index : Int,
  run_dir : String,
  matches : @argparse.Matches,
  model : @deepseek.Model,
  task : String,
  max_steps~ : Int,
  thinking~ : @deepseek.ThinkingMode,
  api_key : String,
  api_url : String?,
) -> AttemptOutcome {
  // Generated before the try so a failed attempt can still name its (partial)
  // session in the summary for inspection.
  let id = @agent_session.SessionId::generated(
    prefix="cli",
    now_ms=@env.now().reinterpret_as_int64(),
    salt=random_salt(),
  )
  try {
    let root = session_root(matches, workspace_root=run_dir)
    let store = @store.SessionStore(root)
    let session = load_or_new_session(
      store,
      id,
      matches,
      model,
      workspace_root=run_dir,
    )
    let completed = @agent.run_turn_with_append(
      api_key,
      model,
      session,
      task,
      append_item=(session, item) => store.append(session, item),
      max_steps~,
      thinking~,
      api_url?,
      workspace_root=run_dir,
    )
    let (status, detail) = terminal_summary(completed)
    {
      index,
      dir: run_dir,
      session: id.value(),
      status,
      detail,
      ok: status == "finished",
    }
  } catch {
    error =>
      {
        index,
        dir: run_dir,
        session: id.value(),
        status: "error",
        detail: failure_message("\{error}"),
        ok: false,
      }
  }
}

///|
/// The terminal status and message of a finished run, read from its last
/// `Terminal` event. `("(no terminal)", "")` when the run recorded none.
fn terminal_summary(session : @agent_session.Session) -> (String, String) {
  let mut out = ("(no terminal)", "")
  for event in session.events() {
    if event.item() is Terminal(terminal) {
      out = match terminal {
        Finished(answer) => ("finished", answer)
        Aborted(reason) => ("aborted", reason)
        Interrupted(reason) => ("interrupted", reason)
        Failed(message) => ("failed", message)
      }
    }
  }
  out
}

///|
/// Recursively copy `src` into `dst`, keeping hidden files (so `.git` survives)
/// but skipping heavy/derived directories. Files are copied byte-for-byte;
/// symlinks and special files are skipped. `dst` and missing parents are created.
async fn copy_tree(src : String, dst : String) -> Unit {
  @fs.mkdir(dst, recursive=true)
  for name in @fs.readdir(src, include_hidden=true, sort=true) {
    if copy_skip(name) {
      continue
    }
    let s = @workspace_path.resolve(src, name)
    let d = @workspace_path.resolve(dst, name)
    match @fs.kind(s, follow_symlink=false) {
      Directory => copy_tree(s, d)
      Regular =>
        @fs.write_file(d, @fs.read_file(s), create_mode=CreateOrTruncate)
      _ => ()
    }
  }
}

///|
/// Directory names never copied into a trial workspace: build output, vendored
/// dependencies, and prior session logs (each trial records its own).
fn copy_skip(name : String) -> Bool {
  name == "_build" || name == "node_modules" || name == ".openseek"
}

///|
/// Print the fleet summary to stderr (stdout stays the JSONL event stream): a
/// header line plus one row per attempt, and where to view the results.
async fn print_fleet_summary(
  task : String,
  outcomes : Array[AttemptOutcome?],
) -> Unit {
  let total = outcomes.length()
  let mut finished = 0
  for outcome in outcomes {
    if outcome is Some(result) && result.ok {
      finished += 1
    }
  }
  let lines : Array[String] = [
    "",
    "openseek: \{total} run(s) of \"\{one_line_brief(task, 60)}\" — \{finished} finished, \{total - finished} not",
  ]
  for outcome in outcomes {
    match outcome {
      Some(result) =>
        lines.push(
          "  #\{result.index + 1}  \{result.status}  \{result.session}  \{result.dir}  \{one_line_brief(result.detail, 60)}",
        )
      None => lines.push("  (run did not report)")
    }
  }
  lines.push("")
  lines.push(
    "view: openseek viz --dir <parent>   or   openseek --session-show <id>",
  )
  lines.push("")
  @stdio.stderr.write(lines.join("\n")) catch {
    _ => ()
  }
}

///|
/// Collapse to a single trimmed line capped at `max` characters (ellipsis when
/// cut), iterating by character so a cap never splits a surrogate pair.
fn one_line_brief(text : String, max : Int) -> String {
  let one = text.replace_all(old="\n", new=" ").trim().to_owned()
  if one.length() <= max {
    return one
  }
  let kept = StringBuilder()
  let mut count = 0
  for ch in one {
    if count >= max {
      break
    }
    kept.write_char(ch)
    count += 1
  }
  "\{kept.to_string()}…"
}
