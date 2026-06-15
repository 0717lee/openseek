///|
fn cli_command() -> @argparse.Command {
  Command(
    "openseek-tui",
    about="OpenSeek terminal UI.",
    options=[
      OptionArg(
        "api-key",
        long="api-key",
        env="DEEPSEEK",
        required=true,
        about="DeepSeek API key.",
      ),
      OptionArg(
        "model",
        long="model",
        env="DEEPSEEK_MODEL",
        default_values=[@deepseek.V4Pro.to_string()],
        about="DeepSeek model: deepseek-v4-flash or deepseek-v4-pro.",
      ),
      OptionArg(
        "api-url",
        long="api-url",
        env="OPENSEEK_API_URL",
        default_values=[""],
        about="DeepSeek-compatible chat completions endpoint.",
      ),
      OptionArg(
        "max-steps",
        long="max-steps",
        env="OPENSEEK_MAX_STEPS",
        default_values=["1000"],
        about="Maximum number of agent loop steps before stopping.",
      ),
      OptionArg(
        "thinking",
        long="thinking",
        env="OPENSEEK_THINKING",
        default_values=["max"],
        about="DeepSeek thinking mode: no, high, or max.",
      ),
      OptionArg(
        "engine",
        long="engine",
        env="OPENSEEK_ENGINE",
        default_values=["openseek"],
        about="Agent engine binary to spawn; reads its JSONL event stream from stdout.",
      ),
      OptionArg(
        "engine-mode",
        long="engine-mode",
        env="OPENSEEK_ENGINE_MODE",
        default_values=["serve"],
        about="Engine protocol: serve (one persistent, steerable process) or oneshot (spawn per prompt, for replay engines).",
      ),
      OptionArg(
        "session",
        long="session",
        env="OPENSEEK_SESSION",
        about="Create or resume this durable session id.",
      ),
      OptionArg(
        "session-root",
        long="session-root",
        env="OPENSEEK_SESSION_ROOT",
        about="Directory containing durable OpenSeek sessions; bypasses the workspace store.",
      ),
    ],
    flags=[
      FlagArg(
        "continue",
        long="continue",
        about="Resume this workspace's most recently active session.",
      ),
      FlagArg(
        "workspace-list",
        long="workspace-list",
        about="List known workspaces, most recently opened first, then exit.",
      ),
    ],
    positionals=[
      PositionArg(
        "task",
        num_args=ValueRange(lower=0),
        about="Optional initial task description.",
      ),
    ],
  )
}

///|
fn flag(matches : @argparse.Matches, name : String) -> Bool {
  match matches.flags.get(name) {
    Some(value) => value
    None => false
  }
}

///|
/// Whether `--continue` asked to resume the latest session. Rejects the
/// combination with an explicit `--session`: the flags give two different
/// answers to "which conversation", and silently preferring either would
/// surprise whoever typed the other.
fn continue_requested(matches : @argparse.Matches) -> Bool raise {
  let continue_flag = flag(matches, "continue")
  if continue_flag && session_id(matches) is Some(_) {
    fail(
      "--continue resumes the latest session; it cannot be combined with --session",
    )
  }
  continue_flag
}

///|
/// Swap in the most recently active durable session for `--continue`. With an
/// empty store the generated fresh session stands: there is nothing to
/// continue, and starting a new conversation beats refusing to launch.
async fn with_latest_session(config : AppConfig) -> AppConfig {
  if @store.SessionStore(config.session_root).latest() is Some(id) {
    { ..config, session_id: id }
  } else {
    config
  }
}

///|
/// The user's home directory: `HOME`, or `USERPROFILE` where `HOME` is unset
/// (Windows).
fn home_dir() -> String? {
  if @env.get_env_var("HOME") is Some(home) && !home.trim().is_empty() {
    Some(home)
  } else {
    @env.get_env_var("USERPROFILE")
  }
}

///|
/// Whether `dir` is `root` itself or a subdirectory of it. A plain prefix is
/// not enough: `/work/project2` starts with `/work/project` without being
/// inside it, so the prefix must end exactly at a separator.
fn within_directory(dir : String, root : String) -> Bool {
  dir == root ||
  (
    dir.has_prefix(root) &&
    dir.view(start_offset=root.length()) is ['/' | '\\', ..]
  )
}

///|
/// Re-root a resumed conversation in its recorded working directory. The
/// recorded directory is a refinement *within* the workspace: a session
/// recorded in a subdirectory resumes there, but one pointing outside
/// `config.cwd` is ignored — sessions travel with the project, so when a
/// project is copied or moved (with the old path still existing), or a
/// session was written into this store from elsewhere via `--session-root`,
/// resuming must run in the workspace being opened, not in the unrelated
/// directory the header remembers. Sessions persisted before directories
/// were recorded — or whose directory has since vanished — also keep
/// `config.cwd`, the workspace path (or the launch directory when
/// `--session-root` bypasses the workspace store).
async fn with_session_cwd(config : AppConfig) -> AppConfig {
  // A missing or unreadable session keeps the configured directory rather
  // than failing the launch: `append_session_history` inspects the same
  // session right after the UI starts and reports its errors in the
  // transcript, so swallowing here hides nothing.
  let stored = @store.SessionStore(config.session_root).cwd(config.session_id) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return config
  }
  if stored is Some(cwd) {
    let workspace = @fs.realpath(config.cwd) catch {
      error if @async.is_being_cancelled() => raise error
      _ => return config
    }
    let cwd = @fs.realpath(cwd) catch {
      error if @async.is_being_cancelled() => raise error
      _ => return config
    }
    let kind = @fs.kind(cwd) catch {
      error if @async.is_being_cancelled() => raise error
      _ => return config
    }
    if within_directory(cwd, workspace) && kind == Directory {
      { ..config, cwd, }
    } else {
      config
    }
  } else {
    config
  }
}

///|
fn value(matches : @argparse.Matches, name : String) -> String raise {
  match matches.values.get(name) {
    Some([value]) => value
    Some(values) if values.length() > 0 => values[0]
    _ => fail("missing parsed argument: \{name}")
  }
}

///|
fn values(matches : @argparse.Matches, name : String) -> Array[String] {
  match matches.values.get(name) {
    Some(values) => values
    None => []
  }
}

///|
fn parse_positive_int(input : String, label : String) -> Int raise {
  let parsed = @string.parse_int(input) catch {
    _ => fail("\{label} must be a positive integer, got: \{input}")
  }
  guard parsed > 0 else {
    fail("\{label} must be a positive integer, got: \{input}")
  }
  parsed
}

///|
fn api_url(matches : @argparse.Matches) -> String? raise {
  let url = value(matches, "api-url").trim().to_owned()
  if url.is_empty() {
    None
  } else {
    Some(url)
  }
}

///|
fn session_id(matches : @argparse.Matches) -> @agent_session.SessionId? {
  let session = match values(matches, "session") {
    [session, ..] => session.trim().to_owned()
    [] => ""
  }
  if session.is_empty() {
    None
  } else {
    Some(SessionId(session))
  }
}

///|
/// The explicit `--session-root`, or `None` to use the workspace store.
fn explicit_session_root(matches : @argparse.Matches) -> String? raise {
  guard values(matches, "session-root") is [root, ..] else { return None }
  let root = root.trim().to_owned()
  if root.is_empty() {
    fail("--session-root or OPENSEEK_SESSION_ROOT must not be empty")
  }
  Some(root)
}

///|
/// The OpenSeek home indexing known workspaces: `OPENSEEK_HOME`, else
/// `.openseek` under the home directory.
fn openseek_home() -> String raise {
  if @env.get_env_var("OPENSEEK_HOME") is Some(home) && !home.trim().is_empty() {
    return home
  }
  guard home_dir() is Some(home) else {
    fail(
      "cannot locate the OpenSeek home: set OPENSEEK_HOME, HOME, or USERPROFILE",
    )
  }
  home + "/.openseek"
}

///|
fn launch_cwd() -> String {
  match @env.current_dir() {
    Some(cwd) => cwd
    None => "."
  }
}

///|
/// Resolve where this launch stores sessions and build the launch config.
/// The launch directory is the workspace, `code .` style: its sessions live
/// in `./.openseek` (canonicalized to an absolute root), and opening it
/// indexes the workspace under `home` for `--workspace-list`. An explicit
/// `--session-root` bypasses the workspace layer — the given store is used
/// as-is and nothing is indexed — with relative roots pinned to the launch
/// directory.
async fn launch_config(
  matches : @argparse.Matches,
  home~ : String,
) -> AppConfig {
  let cwd = launch_cwd()
  if explicit_session_root(matches) is Some(root) {
    parse_config(matches, cwd~, session_root=absolute_session_root(root, cwd))
  } else {
    let workspace = @workspace.WorkspaceHome(home).open(
      cwd,
      now_unix=@env.now().reinterpret_as_int64() / 1000,
    )
    parse_config(
      matches,
      cwd=workspace.path(),
      session_root=workspace.store_root(),
    )
  }
}

///|
/// Whether `path` names a fixed location on any supported platform: a POSIX
/// root, a UNC `\\server` path, a Windows rooted `\dir`, or a drive-qualified
/// `C:/` / `C:\` path. Deliberately broader than `@path.Path::is_absolute`,
/// whose win32 semantics call a drive-relative `/tmp` not absolute — a root
/// the user wrote as rooted must pass through verbatim on every platform,
/// never be re-anchored under the launch directory.
fn is_rooted_path(path : String) -> Bool {
  path.has_prefix("/") ||
  path.has_prefix("\\") ||
  path is [_, ':', '/' | '\\', ..]
}

///|
/// Pin a relative session root to the launch directory. The engine is
/// spawned in the conversation's directory, which `with_session_cwd` may
/// re-root away from the launch directory; a relative `--session-root`
/// passed along as-is would then resolve inside that other directory —
/// a different store entirely — and the next turn would silently start a
/// same-named session there instead of continuing this one.
fn absolute_session_root(root : String, cwd : String) -> String {
  if is_rooted_path(root) {
    root
  } else {
    @path.Path(cwd).join(Path(root)).0
  }
}

///|
/// Pin a relative engine path to the launch directory. The engine is spawned
/// in the conversation's directory, which `with_session_cwd` may re-root away
/// from where the TUI was launched; a relative `--engine ./fake-engine`
/// resolved there would exec a different file than the one the user pointed
/// at — and than the one `engine_launchable` probed. A bare name is left
/// alone: it is a PATH lookup, and the probe runs in the same directory as
/// the spawn, so even a pathological relative `PATH` entry resolves both
/// the same way.
fn absolute_engine(engine : String, cwd : String) -> String {
  if engine.contains("/") || engine.contains("\\") {
    absolute_session_root(engine, cwd)
  } else {
    engine
  }
}

///|
/// Session id for a TUI launch that did not pick one.
///
/// Conversation continuity is the TUI's default. The engine runs once per
/// prompt, so context only carries between prompts through the durable session
/// store — without a session, telling the assistant something and asking about
/// it in the next prompt would hit a fresh one-shot that never saw the first
/// message. The stamp format lives in `SessionId::generated`, shared with the
/// engine CLI's default recording.
fn generated_session_id(now_ms : Int64) -> @agent_session.SessionId {
  @agent_session.SessionId::generated(prefix="tui", now_ms~)
}

///|
fn parse_config(
  matches : @argparse.Matches,
  cwd~ : String,
  session_root~ : String,
) -> AppConfig raise {
  {
    api_key: value(matches, "api-key"),
    api_url: api_url(matches),
    model: @deepseek.Model::parse(value(matches, "model")),
    cwd,
    max_steps: parse_positive_int(value(matches, "max-steps"), "--max-steps"),
    // Parsed eagerly so a typo fails at launch with a CLI error instead of
    // inside the first turn's engine run.
    thinking: @deepseek.ThinkingMode::parse(value(matches, "thinking")),
    session_id: match session_id(matches) {
      Some(id) => id
      None => generated_session_id(@env.now().reinterpret_as_int64())
    },
    session_root,
    engine: absolute_engine(value(matches, "engine"), cwd),
    engine_mode: EngineMode::parse(value(matches, "engine-mode")),
  }
}

///|
fn initial_task(matches : @argparse.Matches) -> String? {
  let task = values(matches, "task").join(" ").trim().to_owned()
  if task.is_empty() {
    None
  } else {
    Some(task)
  }
}

///|
async fn run_tui(config : AppConfig, initial : String?) -> Unit {
  @ui.with_ui(config=@ui.Config::new(composer_max_rows=4), ui => {
    run_app(config, initial, ui)
  })
}

///|
async fn run_app(config : AppConfig, initial : String?, ui : @ui.Ui) -> Unit {
  let state = State::new(config)
  let messages = @async.Queue(kind=Unbounded)
  append_session_history(state.config, ui)
  // Name the session so the conversation is resumable later with
  // `--session <id>` — for generated ids this line is the only place the user
  // ever sees one.
  ui.append_item(
    Response("OpenSeek TUI ready · session \{config.session_id.value()}"),
  )
  refresh_ui(ui, state)
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true) <| () => { read_ui_events(ui, messages) }
    group.spawn_bg(no_wait=true) <| () => { tick_ui(messages) }
    match initial {
      Some(task) => messages.put(UiInput(Steer(Prompt(task))))
      None => ()
    }
    run_message_loop(state, ui, group, messages)
  })
}

///|
/// Whether the engine is usable enough to launch. The agent engine is spawned
/// fresh per task (and only once the user submits one), so a missing, non-
/// executable, or non-`openseek`-like engine would otherwise surface deep inside
/// the running UI. We probe it once at startup with `<engine> --help`, which is
/// part of the engine contract: like `openseek`, any `--engine` replacement must
/// accept `--help` as a side-effect-free no-op that exits 0 — it makes no API
/// call, and its output is captured so it never reaches the terminal. The engine
/// is usable only if that probe spawns and exits 0; `ENOENT`/`EACCES` (not found
/// / not executable) or a non-zero exit both mean it is not. Any other failure
/// is unexpected and re-raised rather than mislabeled as a bad engine.
///
/// The probe runs in `cwd~` — the conversation's directory, the same one the
/// real engine is spawned in — so the two resolve the executable identically
/// even when a relative `PATH` entry (`.`, `bin`, an empty segment) makes a
/// bare engine name cwd-dependent.
async fn engine_launchable(engine : String, cwd~ : String) -> Bool {
  try {
    let (code, _) = @process.collect_output_merged(
      engine,
      ["--help"],
      inherit_env=true,
      cwd~,
    )
    code == 0
  } catch {
    @os_error.OSError(_) as err if err.is_ENOENT() || err.is_EACCES() => false
    err => raise err
  }
}

///|
fn format_utc_minute(seconds : Int64) -> String {
  fn pad2(value : Int) -> String {
    if value < 10 {
      "0\{value}"
    } else {
      "\{value}"
    }
  }

  let time = @time.unix(seconds) catch { _ => return "-" }
  "\{time.year()}-\{pad2(time.month())}-\{pad2(time.day())} \{pad2(time.hour())}:\{pad2(time.minute())}"
}

///|
/// `--workspace-list`: one workspace per row, tab-separated path and
/// last-opened stamp (UTC, minute precision), most recently opened first —
/// the same scriptable shape as the engine's `--session-list`.
///
/// Listing contacts no API, yet still sits behind the parser's required
/// `--api-key` — deliberately. Exempting it would take a second, permissive
/// parse pass or hand-rolled key validation that duplicates the argparse
/// error text pinned in the cram suite, and every real TUI launch needs the
/// key anyway: one uniform parse contract is worth more than sparing a
/// listing-only invocation one environment variable.
async fn print_workspace_listings(home~ : String) -> Unit {
  for listing in @workspace.WorkspaceHome(home).listings() {
    println(
      "\{listing.path()}\t\{format_utc_minute(listing.last_opened_unix())}",
    )
  }
}

///|
async fn main {
  let matches = cli_command().parse(env=@env.get_env_vars())
  if flag(matches, "workspace-list") {
    print_workspace_listings(home=openseek_home())
    return
  }
  let mut config = launch_config(matches, home=openseek_home())
  if continue_requested(matches) {
    config = with_latest_session(config)
  }
  config = with_session_cwd(config)
  // Fail before the terminal UI takes over the screen if the engine is unusable,
  // rather than dropping the user into a UI that dies on the first task.
  if !engine_launchable(config.engine, cwd=config.cwd) {
    println(
      "error: engine '\{config.engine}' is not usable: it must be on PATH, executable, and accept `--help` (exit 0) the way openseek does.",
    )
    println(
      "Pass --engine <path>, set OPENSEEK_ENGINE, or install the openseek binary.",
    )
    @sys.exit(1)
  }
  run_tui(config, initial_task(matches))
}

///|
test "cli accepts no initial task" {
  let parsed = cli_command().parse(argv=[], env={ "DEEPSEEK": "test-key" })
  assert_true(initial_task(parsed) is None)
  let config = parse_config(parsed, cwd="/launch", session_root="/store")
  assert_eq(config.api_key, "test-key")
  assert_true(config.api_url is None)
  assert_eq(config.max_steps, 1000)
  assert_eq(config.engine, "openseek")
  // No --session still converses in a session: a generated per-launch id, so
  // consecutive prompts share context instead of running amnesiac one-shots.
  assert_true(config.session_id.value().has_prefix("tui-"))
  // No --session-root: the launch directory is the workspace, like `code .`.
  assert_true(explicit_session_root(parsed) is None)
}

///|
test "explicit --session-root bypasses the workspace store" {
  let parsed = cli_command().parse(argv=["--session-root", "/abs/store"], env={
    "DEEPSEEK": "test-key",
  })
  assert_true(explicit_session_root(parsed) is Some("/abs/store"))
}

///|
test "relative session roots pin to the launch directory" {
  let pinned = absolute_session_root(".openseek", "/launch")
  assert_true(pinned.has_prefix("/launch"))
  assert_true(pinned.has_suffix(".openseek"))
  // Rooted roots pass through verbatim on every platform.
  assert_eq(absolute_session_root("/abs/store", "/launch"), "/abs/store")
  assert_eq(absolute_session_root("C:\\store", "/launch"), "C:\\store")
  assert_eq(absolute_session_root("C:/store", "/launch"), "C:/store")
  assert_eq(
    absolute_session_root("\\\\server\\share", "/launch"),
    "\\\\server\\share",
  )
}

///|
test "cli parses api url" {
  let parsed = cli_command().parse(argv=[], env={
    "DEEPSEEK": "test-key",
    "OPENSEEK_API_URL": " https://proxy.example/v1/chat/completions ",
  })
  guard parse_config(parsed, cwd="/launch", session_root="/store").api_url
    is Some(url) else {
    fail("expected api url")
  }
  assert_eq(url, "https://proxy.example/v1/chat/completions")
}

///|
test "generated session ids are timestamped and directory-safe" {
  assert_eq(generated_session_id(0).value(), "tui-19700101-000000-000")
  assert_eq(generated_session_id(86_399_999).value(), "tui-19700101-235959-999")
  // 2026-06-10T03:14:07.089Z
  assert_eq(
    generated_session_id(1_781_061_247_089).value(),
    "tui-20260610-031407-089",
  )
}

///|
test "cli parses and validates thinking controls" {
  let parsed = cli_command().parse(argv=["--thinking", "high"], env={
    "DEEPSEEK": "test-key",
  })
  let config = parse_config(parsed, cwd="/launch", session_root="/store")
  assert_true(config.thinking is High)
  let bad = cli_command().parse(argv=["--thinking", "sometimes"], env={
    "DEEPSEEK": "test-key",
  })
  let _ = parse_config(bad, cwd="/launch", session_root="/store") catch {
    error => {
      assert_true("\{error}".contains("unknown thinking mode"))
      return
    }
  }
  fail("invalid thinking mode accepted")
}

///|
test "cli accepts initial task and max steps" {
  let parsed = cli_command().parse(
    argv=["--max-steps", "5", "inspect", "project"],
    env={ "DEEPSEEK": "test-key" },
  )
  assert_true(initial_task(parsed) == Some("inspect project"))
  assert_eq(
    parse_config(parsed, cwd="/launch", session_root="/store").max_steps,
    5,
  )
}

///|
test "cli rejects unknown option before initial task" {
  let _ = cli_command().parse(argv=["--xxy", "he"], env={
    "DEEPSEEK": "test-key",
  }) catch {
    error => {
      assert_true("\{error}".contains("unexpected argument '--xxy' found"))
      return
    }
  }
  fail("unknown option accepted as initial task")
}

///|
test "cli accepts hyphen-leading initial task after option delimiter" {
  let parsed = cli_command().parse(argv=["--", "--xxy", "he"], env={
    "DEEPSEEK": "test-key",
  })
  assert_true(initial_task(parsed) == Some("--xxy he"))
}

///|
test "cli accepts session configuration" {
  let parsed = cli_command().parse(
    argv=["--session", "demo", "--session-root", "/tmp/openseek-sessions"],
    env={ "DEEPSEEK": "test-key" },
  )
  guard explicit_session_root(parsed) is Some(root) else {
    fail("expected an explicit root")
  }
  let config = parse_config(
    parsed,
    cwd="/launch",
    session_root=absolute_session_root(root, "/launch"),
  )
  assert_eq(config.session_id.value(), "demo")
  assert_eq(config.session_root, "/tmp/openseek-sessions")
}

///|
test "cli rejects an empty explicit session root" {
  let parsed = cli_command().parse(
    argv=["--session", "demo", "--session-root", ""],
    env={ "DEEPSEEK": "test-key" },
  )
  let _ = explicit_session_root(parsed) catch {
    error => {
      assert_true("\{error}".contains("--session-root"))
      return
    }
  }
  fail("empty session root accepted")
}

///|
test "cli accepts --continue and rejects combining it with --session" {
  let parsed = cli_command().parse(argv=["--continue"], env={
    "DEEPSEEK": "test-key",
  })
  assert_true(continue_requested(parsed))
  let conflicted = cli_command().parse(
    argv=["--continue", "--session", "demo"],
    env={ "DEEPSEEK": "test-key" },
  )
  let _ = continue_requested(conflicted) catch {
    error => {
      assert_true("\{error}".contains("cannot be combined with --session"))
      return
    }
  }
  fail("--continue with --session accepted")
}

///|
test "cli overrides the engine binary" {
  let parsed = cli_command().parse(argv=["--engine", "./fake-engine"], env={
    "DEEPSEEK": "test-key",
  })
  // Pinned to the launch directory, so spawning in the conversation's
  // directory still execs the binary the user pointed at.
  let engine = parse_config(parsed, cwd="/launch", session_root="/store").engine
  assert_true(is_rooted_path(engine))
  assert_true(engine.has_prefix("/launch"))
  assert_true(engine.has_suffix("fake-engine"))
}

///|
test "within_directory accepts the root and its subdirectories only" {
  assert_true(within_directory("/work/project", "/work/project"))
  assert_true(within_directory("/work/project/sub/dir", "/work/project"))
  assert_true(within_directory("C:\\proj\\sub", "C:\\proj"))
  // A sibling sharing the prefix is not inside.
  assert_false(within_directory("/work/project2", "/work/project"))
  assert_false(within_directory("/elsewhere", "/work/project"))
}

///|
test "relative engine paths pin to the launch directory, bare names stay" {
  // A bare name is a PATH lookup and passes through untouched.
  assert_eq(absolute_engine("openseek", "/launch"), "openseek")
  // Rooted paths pass through verbatim.
  assert_eq(absolute_engine("/abs/engine", "/launch"), "/abs/engine")
  assert_eq(absolute_engine("C:\\engine.exe", "/launch"), "C:\\engine.exe")
  // Separator-bearing relative paths are anchored to the launch directory.
  let pinned = absolute_engine("./fake-engine", "/launch")
  assert_true(pinned.has_prefix("/launch"))
  assert_true(pinned.has_suffix("fake-engine"))
}

///|
async test "engine_launchable rejects a binary that cannot be exec'd" {
  assert_false(engine_launchable("openseek-not-a-real-binary-xyz", cwd="."))
}

///|
async test "engine_launchable accepts an engine whose --help exits 0" {
  // `moon` stands in for an engine that honors the `--help` no-op the probe
  // requires: `moon --help` exits 0 and, unlike `true`, `moon` is on PATH on
  // every platform the tests run on (including Windows native), so this stays
  // cross-platform.
  assert_true(engine_launchable("moon", cwd="."))
}
