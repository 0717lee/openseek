///|
fn drain_test_state() -> State {
  State::new({
    api_key: "k",
    api_url: Some("https://proxy.example/v1/chat/completions"),
    model: V4Pro,
    cwd: ".",
    max_steps: 10,
    thinking: Max,
    session_id: SessionId("test"),
    session_root: ".openseek",
    engine: "openseek",
    engine_mode: Serve,
  })
}

///|
fn start_agent_count(cmds : Array[Cmd]) -> Int {
  for cmd in cmds; count = 0 {
    if cmd is StartAgent(_, ..) {
      continue count + 1
    }
  } nobreak {
    count
  }
}

///|
fn error_item_count(cmds : Array[Cmd]) -> Int {
  for cmd in cmds; count = 0 {
    if cmd is AppendItem(Error(_)) {
      continue count + 1
    }
  } nobreak {
    count
  }
}

///|
fn run_command_count(cmds : Array[Cmd]) -> Int {
  for cmd in cmds; count = 0 {
    if cmd is RunCommand(_, ..) {
      continue count + 1
    }
  } nobreak {
    count
  }
}

///|
fn restart_engine_count(cmds : Array[Cmd]) -> Int {
  for cmd in cmds; count = 0 {
    if cmd is RestartEngine(_) {
      continue count + 1
    }
  } nobreak {
    count
  }
}

///|
fn resume_session_count(cmds : Array[Cmd]) -> Int {
  for cmd in cmds; count = 0 {
    if cmd is ResumeSession(_) {
      continue count + 1
    }
  } nobreak {
    count
  }
}

///|
fn compact_session_count(cmds : Array[Cmd]) -> Int {
  for cmd in cmds; count = 0 {
    if cmd is CompactSession(_) {
      continue count + 1
    }
  } nobreak {
    count
  }
}

///|
fn open_picker_count(cmds : Array[Cmd]) -> Int {
  for cmd in cmds; count = 0 {
    if cmd is (OpenPicker(_) | OpenResumePicker) {
      continue count + 1
    }
  } nobreak {
    count
  }
}

///|
test "engine configuration travels through the environment" {
  let config = drain_test_state().config
  let env = engine_extra_env(config)
  guard env.get("OPENSEEK_SESSION") is Some(session_id) else {
    fail("missing session id env")
  }
  guard env.get("OPENSEEK_SESSION_ROOT") is Some(session_root) else {
    fail("missing session root env")
  }
  guard env.get("OPENSEEK_DIR") is Some(dir) else {
    fail("missing workspace dir env")
  }
  assert_eq(session_id, "test")
  assert_eq(session_root, ".openseek")
  assert_eq(dir, ".")
  assert_true(env.get("OPENSEEK_THINKING") == Some("max"))
  assert_true(
    env.get("OPENSEEK_API_URL") ==
    Some("https://proxy.example/v1/chat/completions"),
  )
}

///|
test "agent engine env overrides inherited session config" {
  let inherited = {
    "OPENSEEK_SESSION": "parent",
    "OPENSEEK_SESSION_ROOT": "/tmp/parent",
    "OPENSEEK_DIR": "/tmp/parent-workspace",
    "OPENSEEK_API_URL": "https://parent.example/chat/completions",
    "PATH": "/bin",
  }
  let env = engine_env(drain_test_state().config, inherited)
  assert_true(env.get("PATH") == Some("/bin"))
  assert_true(env.get("OPENSEEK_SESSION") == Some("test"))
  assert_true(env.get("OPENSEEK_SESSION_ROOT") == Some(".openseek"))
  assert_true(env.get("OPENSEEK_DIR") == Some("."))
  assert_true(
    env.get("OPENSEEK_API_URL") ==
    Some("https://proxy.example/v1/chat/completions"),
  )
  assert_true(inherited.get("OPENSEEK_SESSION") == Some("parent"))
}

///|
test "agent engine env clears inherited api url without override" {
  let config = { ..drain_test_state().config, api_url: None }
  let env = engine_env(config, {
    "OPENSEEK_API_URL": "https://parent.example/chat/completions",
  })
  assert_true(env.get("OPENSEEK_API_URL") == Some(""))
}

///|
test "model slash command opens a picker without a name and updates with one" {
  let state = drain_test_state()
  // Bare /model opens the model picker (the handler's job) rather than erroring
  // or changing anything.
  let bare = update(state, UiInput(SlashCommand(name="model", arguments="")))
  guard bare is [OpenPicker(name~, items~)] else {
    fail("expected bare /model to open the model picker")
  }
  assert_eq(name, "model")
  assert_true(items.length() > 0)
  assert_eq(error_item_count(bare), 0)
  assert_eq(restart_engine_count(bare), 0)
  assert_eq(state.config.model.to_string(), "deepseek-v4-pro")

  let changed = update(
    state,
    UiInput(SlashCommand(name="model", arguments="deepseek-v4-flash")),
  )
  assert_eq(restart_engine_count(changed), 1)
  assert_eq(error_item_count(changed), 0)
  assert_eq(state.config.model.to_string(), "deepseek-v4-flash")
}

///|
test "model slash command rejects invalid or running changes" {
  let state = drain_test_state()
  let invalid = update(
    state,
    UiInput(SlashCommand(name="model", arguments="deepseek-v4-unknown")),
  )
  assert_eq(error_item_count(invalid), 1)
  assert_eq(restart_engine_count(invalid), 0)
  assert_eq(state.config.model.to_string(), "deepseek-v4-pro")

  let _ = update(state, UiInput(Steer(Prompt("work"))))
  let running = update(
    state,
    UiInput(SlashCommand(name="model", arguments="deepseek-v4-flash")),
  )
  assert_eq(error_item_count(running), 1)
  assert_eq(restart_engine_count(running), 0)
  assert_eq(state.config.model.to_string(), "deepseek-v4-pro")
}

///|
test "exit slash command quits" {
  let state = drain_test_state()
  let cmds = update(state, UiInput(SlashCommand(name="exit", arguments="")))
  assert_eq(quit_count(cmds), 1)

  let rejected = update(
    state,
    UiInput(SlashCommand(name="exit", arguments="now")),
  )
  assert_eq(quit_count(rejected), 0)
  assert_eq(error_item_count(rejected), 1)
}

///|
test "resume slash command opens a picker without an id and resumes with one" {
  let state = drain_test_state()
  // Bare /resume opens the session picker (fetched fresh by the loop) rather
  // than erroring; only an explicit id resumes directly.
  let bare = update(state, UiInput(SlashCommand(name="resume", arguments="")))
  guard bare is [OpenResumePicker] else {
    fail("expected bare /resume to open the session picker")
  }
  assert_eq(error_item_count(bare), 0)
  assert_eq(resume_session_count(bare), 0)

  let explicit = update(
    state,
    UiInput(SlashCommand(name="resume", arguments=" demo ")),
  )
  guard explicit is [ResumeSession(id)] else {
    fail("expected explicit-session resume command")
  }
  assert_eq(id.value(), "demo")
}

///|
test "resume slash command rejects running or queued work" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Prompt("work"))))
  let running = update(
    state,
    UiInput(SlashCommand(name="resume", arguments="")),
  )
  assert_eq(error_item_count(running), 1)
  assert_eq(resume_session_count(running), 0)
  // A busy session refuses even the bare (picker) form rather than opening it.
  assert_eq(open_picker_count(running), 0)

  let queued_state = drain_test_state()
  queued_state.queued.push(Prompt("later"))
  let queued_cmds : Array[Cmd] = []
  handle_resume_command(queued_state, "", queued_cmds)
  assert_eq(error_item_count(queued_cmds), 1)
  assert_eq(open_picker_count(queued_cmds), 0)
  assert_eq(resume_session_count(queued_cmds), 0)
}

///|
test "compact slash command starts a compaction run when idle" {
  let state = drain_test_state()
  let cmds = update(state, UiInput(SlashCommand(name="compact", arguments="")))
  assert_eq(compact_session_count(cmds), 1)
  assert_eq(error_item_count(cmds), 0)
  // The run is held busy so a concurrent prompt cannot interleave with the
  // engine's compaction, and so the activity line shows work in progress.
  assert_false(state.run is Idle)
  // The start notice precedes the command, so the compaction is the tail.
  guard cmds is [_, CompactSession(run_id~)] else {
    fail("expected a compaction command")
  }
  assert_true(state.owns_run(run_id))

  // A second compact while the first is still running is refused, not queued.
  let busy = update(state, UiInput(SlashCommand(name="compact", arguments="")))
  assert_eq(compact_session_count(busy), 0)
  assert_eq(error_item_count(busy), 1)

  // The engine's terminal event closes the run and previews the new context.
  let done = update(
    state,
    AgentProgress(run_id~, CompactionFinished("- goal: ship /compact")),
  )
  assert_eq(compact_session_count(done), 0)
  guard done is [AppendItem(Notice(_))] else {
    fail("expected a compaction preview notice")
  }
  assert_true(state.run is Idle)
}

///|
test "a prompt during compaction is rejected locally, not steered" {
  let state = drain_test_state()
  let started = update(
    state,
    UiInput(SlashCommand(name="compact", arguments="")),
  )
  guard started is [_, CompactSession(_)] else {
    fail("expected compaction to start")
  }
  assert_true(state.run_is_compaction)

  // Enter with a prompt must not steer (the engine drops steers during
  // compaction); it is rejected locally so the text is not lost.
  let steered = update(state, UiInput(Steer(Prompt("hello"))))
  assert_eq(error_item_count(steered), 1)
  assert_true(steered.iter().all(cmd => !(cmd is SteerAgent(_))))
  assert_eq(state.pending_steers.length(), 0)

  // Tab queues it instead, to run once compaction lands.
  let _ = update(state, UiInput(Queue(Prompt("hello"))))
  assert_eq(state.queued.length(), 1)

  // When compaction finishes the queued prompt drains and starts.
  let done = update(
    state,
    AgentProgress(run_id=state.run_id, CompactionFinished("summary")),
  )
  assert_false(state.run_is_compaction)
  assert_eq(start_agent_count(done), 1)
}

///|
test "compact slash command rejects arguments and pending work" {
  let with_args = drain_test_state()
  let rejected = update(
    with_args,
    UiInput(SlashCommand(name="compact", arguments="now")),
  )
  assert_eq(error_item_count(rejected), 1)
  assert_eq(compact_session_count(rejected), 0)
  assert_true(with_args.run is Idle)

  let queued_state = drain_test_state()
  queued_state.queued.push(Prompt("later"))
  let queued_cmds : Array[Cmd] = []
  handle_compact_command(queued_state, "", queued_cmds)
  assert_eq(error_item_count(queued_cmds), 1)
  assert_eq(compact_session_count(queued_cmds), 0)
}

///|
test "compact slash command is unavailable on a oneshot engine" {
  let state = drain_test_state()
  state.config = { ..state.config, engine_mode: OneShot }
  let cmds = update(state, UiInput(SlashCommand(name="compact", arguments="")))
  assert_eq(error_item_count(cmds), 1)
  assert_eq(compact_session_count(cmds), 0)
  assert_true(state.run is Idle)
}

///|
test "unknown slash command reports an error" {
  let state = drain_test_state()
  let cmds = update(state, UiInput(SlashCommand(name="unknown", arguments="")))
  assert_eq(error_item_count(cmds), 1)
  assert_true(state.run is Idle)
}

///|
test "a submitted shell command runs locally, not via the agent" {
  let state = drain_test_state()
  // A `!` command submitted while idle drains to a local RunCommand, never to
  // the agent engine.
  let cmds = update(state, UiInput(Steer(Command("ls"))))
  assert_true(state.run is Running(_))
  assert_eq(run_command_count(cmds), 1)
  assert_eq(start_agent_count(cmds), 0)
}

///|
test "queued input drains exactly when the agent is idle" {
  let state = drain_test_state()

  // Submit while idle: starts immediately, nothing left queued.
  let cmds = update(state, UiInput(Steer(Prompt("a"))))
  assert_true(state.run is Running(_))
  assert_eq(state.queued.length(), 0)
  assert_eq(start_agent_count(cmds), 1)

  // Submit while running: queues, no new agent started.
  let cmds = update(state, UiInput(Queue(Prompt("b"))))
  assert_true(state.run is Running(_))
  assert_eq(state.queued.length(), 1)
  assert_eq(start_agent_count(cmds), 0)

  // A non-terminal progress event must not drain the queue.
  let cmds = update(
    state,
    AgentProgress(run_id=state.run_id, AssistantMessage("thinking")),
  )
  assert_true(state.run is Running(_))
  assert_eq(state.queued.length(), 1)
  assert_eq(start_agent_count(cmds), 0)

  // Agent finishes with one queued: drains "b" and starts it.
  let cmds = update(
    state,
    AgentProgress(run_id=state.run_id, AgentFinished("done-a")),
  )
  assert_true(state.run is Running(_))
  assert_eq(state.queued.length(), 0)
  assert_eq(start_agent_count(cmds), 1)

  // Agent finishes with empty queue: stays idle, nothing started.
  let cmds = update(
    state,
    AgentProgress(run_id=state.run_id, AgentFinished("done-b")),
  )
  assert_true(state.run is Idle)
  assert_eq(state.queued.length(), 0)
  assert_eq(start_agent_count(cmds), 0)
}

///|
test "a stale terminal event from a superseded run is ignored" {
  let state = drain_test_state()

  // Run A starts, and a second input B is queued behind it.
  let _ = update(state, UiInput(Steer(Prompt("a"))))
  let run_a = state.run_id
  let _ = update(state, UiInput(Queue(Prompt("b"))))

  // A finishes: the queue drains and B starts as a new run with a fresh id.
  let _ = update(state, AgentProgress(run_id=run_a, AgentFinished("done-a")))
  assert_true(state.run is Running(_))
  let run_b = state.run_id
  assert_true(run_b != run_a)

  // A late terminal from the already-superseded run A (e.g. an `AgentCancelled`
  // that races a natural finish) must be dropped: it neither finishes B nor
  // drains the queue again.
  let cmds = update(state, AgentCancelled(run_id=run_a))
  assert_eq(cmds.length(), 0)
  assert_true(state.run is Running(_))
  assert_eq(state.run_id, run_b)
}

///|
fn quit_count(cmds : Array[Cmd]) -> Int {
  for cmd in cmds; count = 0 {
    if cmd is Quit {
      continue count + 1
    }
  } nobreak {
    count
  }
}

///|
test "Ctrl+C quits when idle and interrupts when a task is running" {
  let state = drain_test_state()

  // Idle: an interrupt quits the TUI rather than reporting a dead end.
  let cmds = update(state, UiInput(Interrupt))
  assert_eq(quit_count(cmds), 1)
  assert_eq(error_item_count(cmds), 0)
  assert_true(state.run is Idle)

  // Running: the same interrupt cancels the task instead of quitting.
  let _ = update(state, UiInput(Steer(Prompt("a"))))
  assert_true(state.run is Running(_))
  let cmds = update(state, UiInput(Interrupt))
  assert_eq(quit_count(cmds), 0)
  assert_true(cmds.iter().any(cmd => cmd is CancelAgent))
  assert_true(state.run is Interrupting(_))

  // A second interrupt escalates from the polite cancel command to killing
  // the engine process.
  let cmds = update(state, UiInput(Interrupt))
  assert_true(cmds.iter().any(cmd => cmd is KillEngine))
  assert_eq(quit_count(cmds), 0)

  // Steering a turn that is being cancelled is refused: the text could
  // outlive the dying turn in the engine's queue and contaminate a later
  // prompt.
  let cmds = update(state, UiInput(Steer(Prompt("late idea"))))
  assert_eq(error_item_count(cmds), 1)
  assert_true(cmds.iter().all(cmd => !(cmd is SteerAgent(_))))
}

///|
test "a tick while idle never starts an agent" {
  let state = drain_test_state()
  let cmds = update(state, Tick)
  assert_true(state.run is Idle)
  assert_eq(start_agent_count(cmds), 0)
}

///|
test "steering a running agent sends a steer command" {
  let state = drain_test_state()

  // Idle Steer submits and starts a task.
  let _ = update(state, UiInput(Steer(Prompt("a"))))
  assert_true(state.run is Running(_))
  assert_eq(state.queued.length(), 0)

  // Steer while running: a steer command for the engine — no queueing, no
  // new run, no error. The transcript echo comes later, from the engine's
  // steer_applied event at the boundary where the model actually saw it.
  let cmds = update(state, UiInput(Steer(Prompt("b"))))
  assert_eq(state.queued.length(), 0)
  assert_eq(start_agent_count(cmds), 0)
  assert_eq(error_item_count(cmds), 0)
  guard cmds is [SteerAgent(text)] else { fail("expected a steer command") }
  assert_eq(text, "b")
  assert_true(state.run is Running(_))

  // A shell command cannot steer a model turn: error, nothing sent.
  let cmds = update(state, UiInput(Steer(Command("ls"))))
  assert_eq(error_item_count(cmds), 1)
  assert_true(cmds.iter().all(cmd => !(cmd is SteerAgent(_))))

  // Queue while running still queues without error.
  let cmds = update(state, UiInput(Queue(Prompt("c"))))
  assert_eq(state.queued.length(), 1)
  assert_eq(error_item_count(cmds), 0)
}

///|
test "oneshot engines reject steering with the legacy notice" {
  let state = State::new({
    api_key: "k",
    api_url: None,
    model: V4Pro,
    cwd: ".",
    max_steps: 10,
    thinking: Max,
    session_id: SessionId("test"),
    session_root: ".openseek",
    engine: "./replayer",
    engine_mode: OneShot,
  })
  let _ = update(state, UiInput(Steer(Prompt("a"))))
  assert_true(state.run is Running(_))
  // No command channel into a one-shot process: steering errors instead of
  // emitting a steer command.
  let cmds = update(state, UiInput(Steer(Prompt("b"))))
  assert_eq(error_item_count(cmds), 1)
  assert_true(cmds.iter().all(cmd => !(cmd is SteerAgent(_))))
  // A oneshot engine dies with its turn — its watcher status must not
  // outlive the run the way serve mode's deliberately does.
  state.watcher_status = "running"
  let _ = update(
    state,
    AgentProgress(run_id=state.run_id, AgentFinished("done")),
  )
  assert_eq(state.watcher_status, "")
}

///|
test "a running shell command is never steered and never kills the engine" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Command("sleep 5"))))
  assert_true(state.run is Running(_))
  assert_true(state.run_is_command)

  // Steering a local command run errors instead of poking the idle engine.
  let cmds = update(state, UiInput(Steer(Prompt("change of plan"))))
  assert_eq(error_item_count(cmds), 1)
  assert_true(cmds.iter().all(cmd => !(cmd is SteerAgent(_))))

  // Interrupt escalation stays on the local task: a second Ctrl-C cancels
  // again rather than killing the bystander engine process.
  let _ = update(state, UiInput(Interrupt))
  assert_true(state.run is Interrupting(_))
  let cmds = update(state, UiInput(Interrupt))
  assert_true(cmds.iter().any(cmd => cmd is CancelAgent))
  assert_true(cmds.iter().all(cmd => !(cmd is KillEngine)))

  // Finishing the command clears the flag.
  let _ = update(
    state,
    CommandResult(run_id=state.run_id, Error("interrupted")),
  )
  assert_false(state.run_is_command)
}

///|
test "a sent steer is acknowledged until the engine settles it" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Prompt("do it"))))
  assert_eq(state.pending_steers.length(), 0)

  // Enter mid-run: acknowledged immediately, before any engine round trip —
  // this is the only feedback between the keypress and the transcript echo.
  let _ = update(state, UiInput(Steer(Prompt("make it rhyme"))))
  assert_eq(state.pending_steers.length(), 1)
  guard pending_steer_segment(state.pending_steers) is [_, _] else {
    fail("expected an activity-line acknowledgment")
  }

  // The engine confirms: acknowledgment clears, transcript echo appends.
  let _ = update(
    state,
    AgentProgress(run_id=state.run_id, SteerApplied("make it rhyme")),
  )
  assert_eq(state.pending_steers.length(), 0)
  assert_eq(pending_steer_segment(state.pending_steers).length(), 0)

  // A dropped steer also clears the acknowledgment (and shows its notice).
  let _ = update(state, UiInput(Steer(Prompt("too late"))))
  assert_eq(state.pending_steers.length(), 1)
  let _ = update(state, SteerDropped("too late"))
  assert_eq(state.pending_steers.length(), 0)

  // A turn ending sweeps anything still unconfirmed.
  let _ = update(state, UiInput(Steer(Prompt("orphaned"))))
  assert_eq(state.pending_steers.length(), 1)
  let _ = update(
    state,
    AgentProgress(run_id=state.run_id, AgentFinished("done")),
  )
  assert_eq(state.pending_steers.length(), 0)
}

///|
test "a trailing drop from a dead turn never steals a fresh acknowledgment" {
  let state = drain_test_state()
  // Turn A is steered, then ends (sweeping its pending entry).
  let _ = update(state, UiInput(Steer(Prompt("task a"))))
  let _ = update(state, UiInput(Steer(Prompt("old steer"))))
  let _ = update(
    state,
    AgentProgress(run_id=state.run_id, AgentFinished("done-a")),
  )
  assert_eq(state.pending_steers.length(), 0)
  // Turn B starts and is steered before A's untagged drop arrives.
  let _ = update(state, UiInput(Steer(Prompt("task b"))))
  let _ = update(state, UiInput(Steer(Prompt("fresh steer"))))
  assert_eq(state.pending_steers.length(), 1)
  // The old turn's wire drop settles nothing of B's — even with identical
  // text, a wire drop's own entries are swept before it is processed.
  let _ = update(state, EngineSteerDropped("old steer"))
  assert_eq(state.pending_steers.length(), 1)
  let _ = update(state, EngineSteerDropped("fresh steer"))
  assert_eq(state.pending_steers.length(), 1)
  assert_eq(state.pending_steers[0], "fresh steer")
}

///|
test "blank steers are neither sent nor acknowledged" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Prompt("task"))))
  let cmds = update(state, UiInput(Steer(Prompt("   "))))
  // The engine would filter it without any settling event, so the TUI must
  // not create an acknowledgment that can never clear.
  assert_eq(state.pending_steers.length(), 0)
  assert_true(cmds.iter().all(cmd => !(cmd is SteerAgent(_))))
}

///|
test "a steer_applied event echoes the input into the transcript" {
  let state = drain_test_state()
  let _ = update(state, UiInput(Steer(Prompt("do it"))))
  let cmds = update(
    state,
    AgentProgress(run_id=state.run_id, SteerApplied("make it rhyme")),
  )
  guard cmds is [AppendItem(Input(Prompt(text)))] else {
    fail("expected the steered input echoed as a transcript item")
  }
  assert_eq(text, "make it rhyme")
  // The run keeps going: a steer is not a terminal event.
  assert_true(state.run is Running(_))
}

///|
test "compact_lines strips CRLF so tool output has no stray carriage returns" {
  inspect(compact_lines("a\r\nb\r\nc", 6).join("|"), content="a|b|c")
  // Truncation still works and the kept lines carry no `\r`.
  inspect(
    compact_lines("a\r\nb\r\nc\r\nd\r\ne", 3).join("|"),
    content="a|... +3 lines|e",
  )
}
