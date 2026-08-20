// Shared fixtures for this package's whitebox tests: the ambient-env
// serialization lock, env save/restore helpers, fake toolchain seeds, the
// record writers that stand in for an engine, and the per-area test
// configs. Test-only - nothing here ships.

///|
/// Serializes every test that reads or writes the two process-global
/// variables deciding where a conversation lives: `OPENSEEK_SESSION_ROOT`
/// (the registry, and the global store records migrate out of) and `HOME`
/// (where the default workspace lands, and so where a run works). Both are
/// process-wide, so a test that moves either is not isolated from a test that
/// merely reads it — and a test that starts a run reads `HOME`, whether or not
/// it mentions it.
///
/// Holding this lock is also how a test gets a disposable `HOME`, so the
/// default workspace it attaches lands in its own temporary tree instead of
/// the developer's real one.
///
/// Other ambient variables the tests touch — `OPENSEEK_DIR`,
/// `OPENSEEK_API_URL` — need no lock: the host always writes them explicitly
/// into a child's environment, so nothing reads the ambient value except the
/// test that set it.
let ambient_env_test_lock : @async.Mutex = Mutex()

///|
fn restore_session_root_env(previous : String?) -> Unit {
  if previous is Some(value) {
    @sys.set_env_var("OPENSEEK_SESSION_ROOT", value)
  } else {
    @sys.unset_env_var("OPENSEEK_SESSION_ROOT")
  }
}

///|
#cfg(not(platform="windows"))
fn restore_home_env(previous : String?) -> Unit {
  if previous is Some(value) {
    @sys.set_env_var("HOME", value)
  } else {
    @sys.unset_env_var("HOME")
  }
}

///|
/// A ServeEngine handle for tests, with every bookkeeping field at its spawn
/// default. Adding a field to ServeEngine updates this one site instead of
/// every test that needs a handle.
fn test_serve_engine(
  session : String,
  writer : @process.WriteToProcess,
  process : @process.Process,
  sink : EventSink,
  phase~ : EnginePhase,
  session_root? : @pathx.Absolute,
  follower? : SessionFollower,
  condemned? : Bool = false,
) -> ServeEngine {
  {
    session_key: session,
    session_root,
    spec_key: "test",
    writer,
    commands: Queue(kind=Unbounded),
    process,
    sink,
    follower,
    consumer: None,
    phase,
    pending_failure: None,
    condemned,
    steer_runs: SteerRunTracker::new(),
  }
}

///|
async fn prepare_fake_moonbit_seed(
  seed : @pathx.Path,
  version~ : String,
) -> Unit {
  write_fake_executable(seed.join("bin/moon"))
  write_fake_executable(seed.join("bin/moonc"))
  write_fake_file(seed.join("lib/core/moon.mod"))
  @fs.write_file(
    seed.join(".openseek-moonbit-seed-version").to_string(),
    version,
    create_mode=CreateOrTruncate,
  )
}

///|
async fn prepare_fake_bundled_moonbit_home(
  moon_home : @pathx.Path,
  version~ : String,
) -> Unit {
  prepare_fake_moonbit_seed(moon_home, version~)
  @fs.write_file(
    moon_home.join(".openseek-moonbit-bundle-version").to_string(),
    "version=\{version}",
    create_mode=CreateOrTruncate,
  )
  write_fake_file(
    moon_home.join("lib/core/_build/native/release/bundle/prelude/prelude.mi"),
  )
  write_fake_file(
    moon_home.join("lib/core/_build/wasm-gc/release/bundle/prelude/prelude.mi"),
  )
}

///|
async fn write_fake_file(path : @pathx.Path) -> Unit {
  @fsx.ensure_dir(path.dirname())
  @fs.write_file(path.to_string(), "", create_mode=CreateOrTruncate)
}

///|
/// The resolver only assembles a toolchain around a regular executable `moon`,
/// and initialization executes `moonc`, so both fakes must carry the bit.
async fn write_fake_executable(path : @pathx.Path) -> Unit {
  @fsx.ensure_dir(path.dirname())
  @fs.write_file(
    path.to_string(),
    "",
    create_mode=CreateOrTruncate,
    permission=0o755,
  )
}

///|
fn pump_test_config(session : String) -> RunConfig {
  {
    task: "test",
    api_key: "test",
    api_url: None,
    model: "test",
    max_steps: 1,
    engine: "unused",
    cwd: None,
    session,
    session_root: Some(@pathx.Path("/tmp/openseek-pump-test").resolve()),
  }
}

///|
/// One durable event line, as the store writes them.
#cfg(not(platform="windows"))
fn session_user_event(sequence : Int, content : String) -> String {
  "{\"sequence\":\{sequence},\"item\":{\"kind\":\"user\",\"payload\":{\"content\":\"\{content}\"}}}"
}

///|
/// Stand in for the engine: write `session`'s record under `root` in the
/// store's own form, a header line followed by one line per event.
#cfg(not(platform="windows"))
async fn write_session_record(
  root : @pathx.Absolute,
  session : String,
  events : Array[String],
) -> Unit {
  let path = @session_record.record_path(root, session)
  @fsx.ensure_dir(path.dirname())
  let text = StringBuilder()
  text <+ "{\"version\":1,\"id\":\"\{session}\",\"system_prompt\":\"\"}\n"
  for event in events {
    text.write_string(event)
    text <+ "\n"
  }
  @fs.write_file(
    path.to_string(),
    text.to_string(),
    create_mode=CreateOrTruncate,
  )
}

///|
/// A record no reader can make sense of: present, so this is not an absent
/// record, but headed by a line that is not a header.
#cfg(not(platform="windows"))
async fn write_damaged_record(root : @pathx.Absolute, session : String) -> Unit {
  let path = @session_record.record_path(root, session)
  @fsx.ensure_dir(path.dirname())
  @fs.write_file(
    path.to_string(),
    "{\"not\":\"a header\"}\n",
    create_mode=CreateOrTruncate,
  )
}

///|
/// A config for a follower with no engine behind it. Every test below hands
/// `engine` a path that is never created, let alone spawned: a follower reads
/// the record itself, and the path only fills the field a run config has.
#cfg(not(platform="windows"))
fn follower_test_config(
  engine : String,
  session : String,
  root : @pathx.Absolute,
) -> RunConfig {
  {
    task: "test",
    api_key: "test",
    api_url: None,
    model: "test",
    max_steps: 1,
    engine,
    cwd: None,
    session,
    session_root: Some(root),
  }
}

///|
fn follower_state_fixture(session : String) -> SessionFollower {
  let root : @pathx.Absolute = @pathx.Path("/tmp/follower-state-fixture").resolve()
  {
    session,
    root,
    inbox: Queue(kind=Blocking(3)),
    load_requests: Queue(kind=Blocking(1)),
    kick_pending: false,
    load_pending: false,
    stopping: false,
    retired: false,
    stop_generation: 0,
    completed_stop_generation: 0,
    completed_stop_error: None,
    stop_observers: 0,
    watermark: 0,
    tail: Tail(root, session),
  }
}

///|
#cfg(not(platform="windows"))
fn restore_openseek_dir(previous : String?) -> Unit {
  if previous is Some(value) {
    @sys.set_env_var("OPENSEEK_DIR", value)
  } else {
    @sys.unset_env_var("OPENSEEK_DIR")
  }
}

///|
#cfg(not(platform="windows"))
fn has_finished_run(events : Array[EngineEvent], run_id : String) -> Bool {
  for event in events {
    if event is Finished(payload) && payload.run_id == run_id {
      return true
    }
  }
  false
}

///|
/// The shell a fake engine runs to commit one durable Terminal before it
/// echoes the matching `agent_finished` — the real engine's append-then-emit
/// order, and what the follower's durable close needs to settle the run. A
/// fixture that only echoes the stream event leaves its run open forever.
///
/// The child reads its own store location and identity from the environment
/// the host gave it, so this needs no paths baked in. The next sequence is
/// the record's line count: the header occupies line one, so the first turn
/// commits sequence 1 and each later one advances.
#cfg(not(platform="windows"))
fn commit_terminal_sh() -> String {
  // `\{newline}` is the two characters a shell `printf` format needs, not an
  // actual line break.
  let newline = "\\n"
  let script =
    $|record="$OPENSEEK_SESSION_ROOT/sessions/$OPENSEEK_SESSION/openseek_session-$OPENSEEK_SESSION.jsonl"
    $|mkdir -p "$OPENSEEK_SESSION_ROOT/sessions/$OPENSEEK_SESSION"
    $|if [ ! -f "$record" ]; then
    $|  printf '{"version":1,"id":"%s","system_prompt":""}\{newline}' "$OPENSEEK_SESSION" > "$record"
    $|fi
    $|printf '{"sequence":%s,"item":{"kind":"terminal","payload":{"kind":"finished","message":"ok"}}}\{newline}' "$(grep -c '' "$record")" >> "$record"
    $|
  script
}

///|
/// A workspace fixture for the run tests: `<root>/ws` attached as the only
/// registered workspace, with the registry itself under `<root>/global`.
/// Every run belongs to a workspace now, so a test that starts one registers
/// a real directory rather than relying on the removed scratch fallback.
/// Returns the path to send as the start payload's workspace hint.
async fn attach_run_workspace(root : @pathx.Path) -> String {
  let workspace = root.join("ws")
  @fsx.ensure_dir(workspace)
  let global = root.join("global")
  @fsx.ensure_dir(global)
  @fs.write_file(
    global.join("workspaces.json").to_string(),
    ({ "workspaces": [workspace.to_string()] } : Json).stringify(),
    create_mode=CreateOrTruncate,
  )
  workspace.to_string()
}

///|
async fn with_settings_dir(
  body : async (@pathx.Path, EngineManager) -> Unit,
) -> Unit {
  // The status payload reads the DEEPSEEK fallback from the process
  // environment; hold it steady so the expectations here cannot depend on
  // the developer's shell. That variable is process-global while async tests
  // run concurrently, so the package's ambient-environment lock has to cover
  // the whole fixture: unsetting it here is worthless if a sibling test sets
  // its own key while a body is mid-assertion. Callers must therefore not
  // hold the lock themselves — it is not reentrant — and should do their own
  // ambient-environment work inside `body` instead.
  ambient_env_test_lock.acquire()
  defer ambient_env_test_lock.release()
  let previous_key = @sys.get_env_var("DEEPSEEK")
  @sys.unset_env_var("DEEPSEEK")
  defer (if previous_key is Some(value) { @sys.set_env_var("DEEPSEEK", value) })
  let dir : @pathx.Path = Path(@fs.tmpdir(prefix="openseek-settings-"))
  defer (@fs.rmdir(dir.to_string(), recursive=true) catch { _ => () })
  body(dir, new_engine_manager("openseek", runtime_dir=dir))
}
