///|
test "recorded terminal outcomes follow the durable-log contracts" {
  guard recorded_terminal_outcome(Terminal(Finished("done")))
    is Some({ status: Finished, answer: Some("done"), error: None }) else {
    fail("expected a plain finish")
  }
  guard recorded_terminal_outcome(
      Terminal(Finished("[context ceiling] checkpointed")),
    )
    is Some({ status: ContextYield, .. }) else {
    fail("expected the answer prefix to spell a context yield")
  }
  guard recorded_terminal_outcome(Terminal(Failed("max steps exhausted")))
    is Some({ status: MaxStepsExhausted, .. }) else {
    fail("expected the exact message to spell a max-steps stop")
  }
  guard recorded_terminal_outcome(Terminal(Failed("boom")))
    is Some({ status: Failed, error: Some("boom"), .. }) else {
    fail("expected a plain failure")
  }
  guard recorded_terminal_outcome(Terminal(Interrupted("cancelled")))
    is Some({ status: Cancelled, error: Some("cancelled"), .. }) else {
    fail("expected an interruption to close as cancelled")
  }
  guard recorded_terminal_outcome(
      UnknownTerminal({ "kind": "terminal", "payload": { "kind": "novel" } }),
    )
    is Some({ status: Failed, answer: None, error: None }) else {
    fail("expected an unknown terminal to close as failed")
  }
  assert_true(
    recorded_terminal_outcome(
      Summary({ content: "s", from_sequence: 1, to_sequence: 2 }),
    )
    is None,
  )
}

///|
test "session_max_sequence is the snapshot's watermark" {
  let session : @protocol.SessionDocument = {
    version: None,
    id: Some("s"),
    system_prompt: None,
    events: Some([
      {
        sequence: 5,
        ts: None,
        item: User({ content: "five", submission_id: None }),
      },
      {
        sequence: 9,
        ts: None,
        item: User({ content: "nine", submission_id: None }),
      },
      {
        sequence: 7,
        ts: None,
        item: User({ content: "seven", submission_id: None }),
      },
    ]),
  }
  inspect(session_max_sequence(session), content="9")
  inspect(session_max_sequence({ ..session, events: Some([]) }), content="0")
}

///|
/// The follower is the run's single closer: a durable Terminal read past
/// the watermark closes the open run immediately — real status, exact
/// sequence, no grace — and the engine stays alive for its next turn.
#cfg(not(platform="windows"))
async test "a durable terminal closes its open run" {
  let dir = @fs.tmpdir(prefix="openseek-durable-close-")
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  let manager = new_engine_manager("/bin/sh")
  let emitted : Array[EngineEvent] = []
  let sink = EventSink(fn(event) { emitted.push(event) })
  @async.with_task_group(group => {
    let (child_stdin, writer) = @process.write_to_process()
    let process = @process.spawn(
      group,
      "/bin/sh",
      ["-c", "sleep 30"],
      stdin=child_stdin,
      no_wait=true,
    )
    let engine = test_serve_engine(
      "s-close",
      writer,
      process,
      sink,
      phase=Running(
        run_id="r-close",
        cancel_requested=false,
        compact_queued=false,
      ),
      session_root=root,
    )
    let sessions : Map[String, SessionSlot] = Map([])
    let slot = slot_for(sessions, "s-close")
    slot.engine = Some(engine)
    manager.pump = Serving(sessions~)
    let follower = follower_state_fixture("s-close")
    fn terminal_event(
      sequence : Int,
      terminal : @protocol.SessionTerminal,
    ) -> @protocol.SessionEvent {
      { sequence, ts: None, item: Terminal(terminal) }
    }

    // A terminal closes the open run immediately: real status, the record's
    // answer, the exact sequence — and the engine stays live for reuse.
    // `ts: None` on every event doubles as proof that attribution never
    // consults the record clock.
    follower.close_run_from_terminal(
      sink,
      manager,
      terminal_event(42, Finished("all done")),
    )
    assert_true(engine.phase is Idle(last_run=Some("r-close")))
    assert_false(engine.condemned)
    assert_true(slot.live() is Some(_))
    guard emitted is [Finished(finish)] else {
      fail("expected exactly one finished event")
    }
    assert_eq(finish.run_id, "r-close")
    assert_eq(finish.status, "finished")
    assert_eq(finish.answer, Some("all done"))
    emitted.clear()

    // With the phase already closed, replaying the same commit is inert.
    follower.close_run_from_terminal(
      sink,
      manager,
      terminal_event(42, Finished("all done")),
    )
    assert_true(emitted.is_empty())

    // A cancel is recorded as Interrupted, and closes with the same
    // Error+Finished pair the stream path used to publish.
    engine.phase = Running(
      run_id="r-close-2",
      cancel_requested=true,
      compact_queued=false,
    )
    follower.close_run_from_terminal(
      sink,
      manager,
      terminal_event(44, Interrupted("cancelled")),
    )
    guard emitted is [Error(error), Finished(cancel_finish)] else {
      fail("expected an error and a finished event")
    }
    assert_eq(error.message, Some("cancelled"))
    assert_eq(cancel_finish.status, "cancelled")
    emitted.clear()

    // A close with a compaction queued behind the turn lands in Compacting,
    // exactly as the stream close did, so nothing slips in ahead of it.
    engine.phase = Running(
      run_id="r-close-3",
      cancel_requested=false,
      compact_queued=true,
    )
    follower.close_run_from_terminal(
      sink,
      manager,
      terminal_event(46, Finished("done")),
    )
    assert_true(engine.phase is Compacting(last_run=Some("r-close-3")))
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
/// The baseline refuses to guess. With an existing record it cannot read,
/// the spawn fails loudly with the cause instead of starting at watermark 0
/// — which would replay the whole history into the durable close on the
/// first successful scan. An absent record is the legitimate first-turn
/// case and baselines at 0.
#cfg(not(platform="windows"))
async test "an unreadable existing record refuses the spawn baseline" {
  let dir = @fs.tmpdir(prefix="openseek-follower-baseline-")
  let engine = dir + "/engine.sh"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  let manager = new_engine_manager(engine)
  let sink = EventSink(fn(_) { () })
  @async.with_task_group(group => {
    // No record file: absence is proof, so the follower installs at the
    // proven-empty watermark and the first turn can run.
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, "s-baseline", root),
      ),
    )
    guard manager.followers.get("s-baseline") is Some(follower) else {
      fail("expected a follower for the record-less first turn")
    }
    assert_eq(follower.watermark, 0)
    discard_follower_startup(manager, follower)

    // A record that exists and cannot be read refuses the spawn instead,
    // and leaves no follower installed.
    write_damaged_record(root, "s-baseline")
    let detail = try {
      ignore(
        ensure_follower(
          sink~,
          group~,
          manager~,
          config=follower_test_config(engine, "s-baseline", root),
        ),
      )
      "no error"
    } catch {
      EngineError(detail) => detail
      error if @async.is_being_cancelled() => raise error
      error => "\{error}"
    }
    assert_true(detail.contains("failed to baseline the session record"))
    assert_true(manager.followers.get("s-baseline") is None)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "failed final scan keeps the follower active and propagates" {
  let dir = @fs.tmpdir(prefix="openseek-follower-stop-")
  let engine = dir + "/engine.sh"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  // The record must be readable while the follower baselines — a spawn over
  // one that is not is refused outright. Damaging it afterwards is the case
  // this test is about: a record that goes bad under a live follower.
  write_session_record(root, "s-fail", [])
  let manager = new_engine_manager(engine)
  let sink = EventSink(fn(_) { () })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, "s-fail", root),
      ),
    )
    guard manager.followers.get("s-fail") is Some(follower) else {
      fail("expected follower")
    }
    write_damaged_record(root, "s-fail")
    let detail = try {
      stop_follower(manager, "s-fail", writer_exited=true)
      "no error"
    } catch {
      EngineError(detail) => detail
      error if @async.is_being_cancelled() => raise error
      error => "\{error}"
    }
    assert_true(detail.contains("session record"))
    assert_true(
      manager.followers.get("s-fail") is Some(current) &&
      physical_equal(current, follower),
    )
    assert_false(follower.stopping)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
/// A first prompt cancelled before the engine created its record leaves a
/// session with nothing to drain. Once the caller has proved the writer is
/// gone, that absence is a successful drain rather than a failure to retry
/// forever.
#cfg(not(platform="windows"))
async test "an absent record retires as an empty drain" {
  let dir = @fs.tmpdir(prefix="openseek-follower-durable-absent-")
  let engine = dir + "/engine.sh"
  let session = "s-durable-absent"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  // No record at all: the writer was cancelled before creating one.
  let manager = new_engine_manager(engine)
  let sink = EventSink(fn(_) { () })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, session, root),
      ),
    )
    guard manager.followers.get(session) is Some(follower) else {
      fail("expected follower")
    }
    stop_follower(manager, session, writer_exited=true)
    assert_true(follower.retired)
    assert_true(manager.followers.get(session) is None)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "the drain that finally succeeds broadcasts what it could not read" {
  let dir = @fs.tmpdir(prefix="openseek-follower-durable-tail-")
  let engine = dir + "/engine.sh"
  let session = "s-durable-tail"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  write_session_record(root, session, [])
  let manager = new_engine_manager(engine)
  let emitted : Array[EngineEvent] = []
  let sink = EventSink(fn(event) { emitted.push(event) })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, session, root),
      ),
    )
    guard manager.followers.get(session) is Some(_) else {
      fail("expected follower")
    }
    write_damaged_record(root, session)
    stop_follower(manager, session, writer_exited=true) catch {
      EngineError(detail) => assert_true(detail.contains("session record"))
      error if @async.is_being_cancelled() => raise error
      error => raise error
    }

    // The writer's last commit is only readable on the retry, so the drain
    // that succeeds is also the one that broadcasts it.
    write_session_record(root, session, [session_user_event(1, "done")])
    stop_follower(manager, session, writer_exited=true)
    let relevant : Array[EngineEvent] = []
    for event in emitted {
      if event is SessionCommit(payload) && payload.session == session {
        relevant.push(event)
      }
    }
    guard relevant is [SessionCommit({ sequence: 1, session_root, .. })] else {
      fail("expected exactly one rooted commit")
    }
    assert_eq(session_root, root.resource_path())
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
/// A child that dies mid-turn but committed its Terminal first is settled
/// by the retirement's final drain with the record's real outcome; the
/// synthetic Failed is reserved for a death that left no Terminal.
#cfg(not(platform="windows"))
async test "EOF retirement closes a committed turn with its real outcome" {
  let dir = @fs.tmpdir(prefix="openseek-eof-durable-close-")
  let session = "s-eof-close"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  write_session_record(root, session, [])
  let manager = new_engine_manager(dir + "/engine.sh")
  let emitted : Array[EngineEvent] = []
  let sink = EventSink(fn(event) { emitted.push(event) })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(dir + "/engine.sh", session, root),
      ),
    )
    guard manager.followers.get(session) is Some(follower) else {
      fail("expected follower")
    }
    let (child_stdin, writer) = @process.write_to_process()
    let (reader, child_stdout) = @process.read_from_process()
    let process = @process.spawn(
      group,
      "/bin/sh",
      ["-c", "exit 0"],
      stdin=child_stdin,
      stdout=child_stdout,
      no_wait=true,
    )
    let engine = test_serve_engine(
      session,
      writer,
      process,
      sink,
      phase=Running(
        run_id="r-eof",
        cancel_requested=false,
        compact_queued=false,
      ),
      session_root=root,
      follower~,
    )
    let sessions : Map[String, SessionSlot] = Map([])
    let slot = slot_for(sessions, session)
    slot.engine = Some(engine)
    manager.pump = Serving(sessions~)
    // The turn committed its Terminal before the child died — the order a
    // real engine appends in — so the final drain finds it.
    write_session_record(root, session, [
      "{\"sequence\":7,\"item\":{\"kind\":\"terminal\",\"payload\":{\"kind\":\"interrupted\",\"message\":\"cancelled\"}}}",
    ])
    let stderr_task = group.spawn(no_wait=true, () => "")
    engine.run(manager, reader, stderr_task)

    // The final drain found the Terminal: the run settled with the record's
    // own outcome and sequence, and no synthetic failure was fabricated.
    assert_true(engine.phase is Idle(last_run=Some("r-eof")))
    assert_true(slot.engine is None)
    let mut cancelled = 0
    for event in emitted {
      if event is Finished(payload) {
        assert_eq(payload.run_id, "r-eof")
        assert_eq(payload.status, "cancelled")
        cancelled += 1
      }
    }
    assert_eq(cancelled, 1)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "abrupt EOF leaves a failed drain for a later caller to retry" {
  let dir = @fs.tmpdir(prefix="openseek-follower-abrupt-eof-")
  let engine_path = dir + "/engine.sh"
  let session = "s-abrupt-eof"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  write_session_record(root, session, [])
  let manager = new_engine_manager(engine_path)
  let emitted : Array[EngineEvent] = []
  let sink = EventSink(fn(event) { emitted.push(event) })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine_path, session, root),
      ),
    )
    guard manager.followers.get(session) is Some(follower) else {
      fail("expected follower")
    }
    let (child_stdin, writer) = @process.write_to_process()
    let (reader, child_stdout) = @process.read_from_process()
    let process = @process.spawn(
      group,
      "/bin/sh",
      ["-c", "exit 7"],
      stdin=child_stdin,
      stdout=child_stdout,
      no_wait=true,
    )
    let engine = test_serve_engine(
      session,
      writer,
      process,
      sink,
      phase=Running(
        run_id="r-abrupt-eof",
        cancel_requested=false,
        compact_queued=false,
      ),
      session_root=root,
      follower~,
    )
    let sessions : Map[String, SessionSlot] = Map([])
    let slot = slot_for(sessions, session)
    slot.engine = Some(engine)
    manager.pump = Serving(sessions~)
    let stderr_task = group.spawn(no_wait=true, () => "")
    // The record is unreadable at EOF, so the drain this engine's exit runs
    // cannot complete and the actor has to stay behind.
    write_damaged_record(root, session)
    engine.run(manager, reader, stderr_task)

    // `run` returning is retirement: the dead handle left its slot, and its
    // run was closed without a record position it could not read.
    assert_true(slot.engine is None)
    let mut finishes = 0
    for event in emitted {
      if event is Finished(payload) && payload.run_id == "r-abrupt-eof" {
        finishes = finishes + 1
      }
    }
    assert_eq(finishes, 1)
    // The follower outlived the engine precisely so a later caller can drain
    // it; once the record is readable again, that retry retires it.
    assert_true(
      manager.followers.get(session) is Some(current) &&
      physical_equal(current, follower),
    )
    write_session_record(root, session, [])
    stop_follower(manager, session, writer_exited=true)
    assert_true(follower.retired)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "workspace detach drains an orphaned pending follower before commit" {
  ambient_env_test_lock.acquire()
  defer ambient_env_test_lock.release()
  let previous = @sys.get_env_var("OPENSEEK_SESSION_ROOT")
  let dir = @fs.tmpdir(prefix="openseek-detach-orphan-follower-")
  let global_root : @pathx.Absolute = @pathx.Path(dir + "/global").resolve()
  let workspace : @pathx.Absolute = @pathx.Path(dir + "/workspace").resolve()
  let root = @workspaces.store_root(workspace)
  let engine_path = dir + "/engine.sh"
  let session = "s-detach-orphan"
  @sys.set_env_var("OPENSEEK_SESSION_ROOT", global_root.to_string())
  defer restore_session_root_env(previous)
  @fsx.ensure_dir(workspace.to_path())
  ignore(attach_workspace(workspace.to_string(), fn(_) { () }))
  write_session_record(root, session, [])
  let manager = new_engine_manager(engine_path)
  let sessions : Map[String, SessionSlot] = Map([])
  manager.pump = Serving(sessions~)
  let emitted : Array[EngineEvent] = []
  let sink = EventSink(fn(event) { emitted.push(event) })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine_path, session, root),
      ),
    )
    guard manager.followers.get(session) is Some(follower) else {
      fail("expected follower")
    }
    write_damaged_record(root, session)
    stop_follower(manager, session, writer_exited=true) catch {
      EngineError(detail) => assert_true(detail.contains("session record"))
      error if @async.is_being_cancelled() => raise error
      error => raise error
    }
    assert_false(follower.retired)

    // The detach below drains the orphan, so the record has to be readable
    // again by then.
    write_session_record(root, session, [session_user_event(1, "tail")])
    // The drain has to finish before the workspace's removal is committed:
    // once the store is gone, nothing could read what the writer left.
    let drained_before_commit : Ref[Bool] = Ref(false)
    let detached = detach_workspace(manager, workspace.to_string(), fn(_) {
      drained_before_commit.val = follower.retired &&
        emitted.iter().any(event => event is SessionCommit({ sequence: 1, .. }))
    })
    assert_true(drained_before_commit.val)
    assert_true(detached is Workspaces([]))
    assert_true(manager.followers.get(session) is None)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "workspace detach refuses an idle engine whose follower cannot drain" {
  let dir = @fs.tmpdir(prefix="openseek-detach-follower-stop-")
  let workspace : @pathx.Absolute = @pathx.Path(dir + "/workspace").resolve()
  let root = @workspaces.store_root(workspace)
  let engine_path = dir + "/engine.sh"
  let session = "s-detach-fail"
  // Readable at baseline, damaged once the follower is watching: a spawn
  // over an unreadable record is refused before it gets this far.
  write_session_record(root, session, [])
  let manager = new_engine_manager(engine_path)
  let sink = EventSink(fn(_) { () })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine_path, session, root),
      ),
    )
    guard manager.followers.get(session) is Some(follower) else {
      fail("expected follower")
    }
    write_damaged_record(root, session)
    let (child_stdin, writer) = @process.write_to_process()
    // The real EOF consumer reaches this state after its first failed final
    // scan: the child is gone and the consumer with it, but the follower is
    // still live. Detach must retry it and propagate the failure again — so
    // the fixture's child exits on its own and its close barrier is the
    // process task, exactly as it would be in production.
    let process = @process.spawn(
      group,
      "/bin/sh",
      ["-c", "exit 0"],
      stdin=child_stdin,
      no_wait=true,
    )
    let engine = test_serve_engine(
      session,
      writer,
      process,
      sink,
      phase=Idle(last_run=Some("r-detach-fail")),
      session_root=root,
      follower~,
      condemned=true,
    )
    let sessions : Map[String, SessionSlot] = Map([])
    let slot = slot_for(sessions, session)
    slot.engine = Some(engine)
    manager.pump = Serving(sessions~)
    let detail = try {
      manager.close_engines_for_workspace(workspace)
      "no error"
    } catch {
      EngineError(detail) => detail
      error if @async.is_being_cancelled() => raise error
      error => "\{error}"
    }
    assert_true(detail.contains("session record"))
    assert_true(
      manager.followers.get(session) is Some(current) &&
      physical_equal(current, follower),
    )
    assert_false(follower.stopping)
    discard_follower_startup(manager, follower)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "record stat failure is not mistaken for an empty final drain" {
  let dir = @fs.tmpdir(prefix="openseek-follower-stat-")
  let engine = dir + "/engine.sh"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  // Opening the pinned record beneath a regular file deterministically raises
  // ENOTDIR. That failure must complete Stop as failed and leave the actor
  // installed, never masquerade as the ENOENT of a record never created.
  // The follower baselines over a real record first — the spawn path refuses
  // a record it cannot read — and the directory turns into a file after.
  write_session_record(root, "s-stat", [])
  let manager = new_engine_manager(engine)
  let sink = EventSink(fn(_) { () })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, "s-stat", root),
      ),
    )
    guard manager.followers.get("s-stat") is Some(follower) else {
      fail("expected follower")
    }
    let record = @session_record.record_path(root, "s-stat")
    let session_dir = record.dirname()
    @fs.rmdir(session_dir.to_string(), recursive=true)
    @fs.write_file(
      session_dir.to_string(),
      "file",
      create_mode=CreateOrTruncate,
    )
    let detail = try {
      stop_follower(manager, "s-stat", writer_exited=true)
      "no error"
    } catch {
      EngineError(detail) => detail
      error if @async.is_being_cancelled() => raise error
      error => "\{error}"
    }
    // The reader takes the record's lock first, so ENOTDIR surfaces there —
    // still the failure this test is about, and still not the ENOENT that
    // would prove no record was ever created.
    assert_true(detail.contains("Not a directory"))
    assert_true(
      manager.followers.get("s-stat") is Some(current) &&
      physical_equal(current, follower),
    )
    assert_false(follower.stopping)
    discard_follower_startup(manager, follower)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "root change retires the old follower before installing another" {
  let dir = @fs.tmpdir(prefix="openseek-follower-root-")
  let engine = dir + "/engine.sh"
  let manager = new_engine_manager(engine)
  let sink = EventSink(fn(_) { () })
  let root_a : @pathx.Absolute = @pathx.Path(dir + "/a").resolve()
  let root_b : @pathx.Absolute = @pathx.Path(dir + "/b").resolve()
  // The same session id under two stores: installing the second follower
  // drains the first, which needs a readable record of its own.
  write_session_record(root_a, "s-root", [])
  write_session_record(root_b, "s-root", [])
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, "s-root", root_a),
      ),
    )
    guard manager.followers.get("s-root") is Some(first) else {
      fail("expected first follower")
    }
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, "s-root", root_b),
      ),
    )
    guard manager.followers.get("s-root") is Some(second) else {
      fail("expected replacement follower")
    }
    assert_false(physical_equal(first, second))
    assert_eq(second.root.to_string(), root_b.to_string())
    discard_follower_startup(manager, second)
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "one Load control message answers a bounded request batch" {
  let dir = @fs.tmpdir(prefix="openseek-follower-load-")
  let engine = dir + "/engine.sh"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  write_session_record(root, "s-load", [session_user_event(1, "hello")])
  let manager = new_engine_manager(engine)
  let sink = EventSink(fn(_) { () })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, "s-load", root),
      ),
    )
    guard manager.followers.get("s-load") is Some(follower) else {
      fail("expected follower")
    }
    let replies : Array[@async.Queue[FollowerLoadReply]] = []
    for _ in 0..<8 {
      let reply : @async.Queue[FollowerLoadReply] = Queue(kind=Blocking(1))
      replies.push(reply)
      follower.load_requests.put({ reply, active: true })
    }
    follower.load_pending = true
    assert_true(follower.inbox.try_put(Load))
    // One scan answers the whole batch: every caller receives the very same
    // snapshot value, not one read each.
    let mut shared : @protocol.SessionDocument? = None
    for reply in replies {
      guard reply.get() is LoadOk(document) else { fail("expected a snapshot") }
      match shared {
        None => shared = Some(document)
        Some(first) => assert_true(physical_equal(first, document))
      }
    }
    guard shared is Some(document) else { fail("expected a snapshot") }
    assert_eq(session_max_sequence(document), 1)
    discard_follower_startup(manager, follower)
  })
  @fs.rmdir(dir, recursive=true)
}

///|
test "startup rollback closes waiters and preserves a successor identity" {
  let manager = new_engine_manager("unused")
  let abandoned = follower_state_fixture("s-startup")
  let reply : @async.Queue[FollowerLoadReply] = Queue(kind=Blocking(1))
  let request : FollowerLoadRequest = { reply, active: true }
  assert_true(abandoned.load_requests.try_put(request))
  manager.followers["s-startup"] = abandoned
  discard_follower_startup(manager, abandoned)
  assert_true(manager.followers.get("s-startup") is None)
  assert_false(request.active)
  assert_true(reply.try_get() is Some(LoadStopped))
  assert_false(abandoned.inbox.try_put(Kick) catch { _ => false })

  let stale = follower_state_fixture("s-startup")
  let successor = follower_state_fixture("s-startup")
  manager.followers["s-startup"] = successor
  discard_follower_startup(manager, stale)
  assert_true(
    manager.followers.get("s-startup") is Some(current) &&
    physical_equal(current, successor),
  )
  assert_true(successor.inbox.try_put(Kick))
}

///|
test "pump reset completes every queued follower load" {
  let manager = new_engine_manager("unused")
  let follower = follower_state_fixture("s-reset")
  let reply : @async.Queue[FollowerLoadReply] = Queue(kind=Blocking(1))
  let request : FollowerLoadRequest = { reply, active: true }
  assert_true(follower.load_requests.try_put(request))
  manager.followers["s-reset"] = follower
  manager.pump = Serving(sessions=Map([]))
  reset_engine_generation(manager, Ref(None))
  assert_true(manager.pump is Stopped)
  assert_true(manager.followers.get("s-reset") is None)
  assert_false(request.active)
  assert_true(reply.try_get() is Some(LoadStopped))
}

///|
async test "identity-scoped stop never retires a successor" {
  let manager = new_engine_manager("unused")
  let departed = follower_state_fixture("s-exit")
  let successor = follower_state_fixture("s-exit")
  manager.followers["s-exit"] = successor
  stop_follower_instance(manager, departed, writer_exited=false)
  assert_true(
    manager.followers.get("s-exit") is Some(current) &&
    physical_equal(current, successor),
  )
  assert_false(successor.stopping)
  assert_true(successor.inbox.try_get() is None)
}

///|
#cfg(not(platform="windows"))
async test "cancelling follower baseline removes its startup identity" {
  let dir = @fs.tmpdir(prefix="openseek-follower-cancel-")
  let engine = dir + "/engine.sh"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  // A record long enough that its baseline spans many reads, so the cancel
  // below lands inside one instead of racing a read that already finished.
  write_session_record(
    root,
    "s-cancel",
    Array::makei(12_000, index => session_user_event(index + 1, "line")),
  )
  let manager = new_engine_manager(engine)
  let sink = EventSink(fn(_) { () })
  @async.with_task_group(group => {
    let startup = group.spawn(() => {
      ignore(
        ensure_follower(
          sink~,
          group~,
          manager~,
          config=follower_test_config(engine, "s-cancel", root),
        ),
      )
    })
    while manager.followers.get("s-cancel") is None {
      @async.pause()
    }
    startup.cancel()
    let cancelled = try {
      startup.wait()
      false
    } catch {
      error if @async.is_cancellation_error(error) => true
      _ => false
    }
    assert_true(cancelled)
    assert_true(manager.followers.get("s-cancel") is None)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
async test "load request is queued before its collapsed control message" {
  let follower = follower_state_fixture("s-order")
  @async.with_task_group(group => {
    let caller = group.spawn(() => request_follower_load(follower))
    assert_true(follower.inbox.get() is Load)
    let request = follower.load_requests.get()
    assert_true(request.active)
    request.active = false
    request.reply.put(
      LoadOk({ version: None, id: None, system_prompt: None, events: Some([]) }),
    )
    assert_true(caller.wait() is LoadOk(_))
  })
}

///|
async test "backpressured load schedules the next control generation" {
  let follower = follower_state_fixture("s-backpressure")
  let placeholder : @async.Queue[FollowerLoadReply] = Queue(kind=Blocking(1))
  follower.load_requests.put({ reply: placeholder, active: false })
  follower.load_pending = true
  @async.with_task_group(group => {
    let caller = group.spawn(() => request_follower_load(follower))
    @async.pause()
    // Freeing the sole request slot accepts and wakes the blocked caller.
    // Model the previous Load generation finishing before that caller runs.
    ignore(follower.load_requests.get())
    follower.load_pending = false
    assert_true(follower.inbox.get() is Load)
    let request = follower.load_requests.get()
    assert_true(request.active)
    request.active = false
    request.reply.put(
      LoadOk({ version: None, id: None, system_prompt: None, events: Some([]) }),
    )
    assert_true(caller.wait() is LoadOk(_))
  })
}

///|
async test "stop requires its generation proof when follower identity vanishes" {
  let manager = new_engine_manager("unused")
  let follower = follower_state_fixture("s-stop-proof")
  manager.followers["s-stop-proof"] = follower
  @async.with_task_group(group => {
    let caller = group.spawn(() => {
      try {
        stop_follower(manager, "s-stop-proof", writer_exited=false)
        "no error"
      } catch {
        EngineError(detail) => detail
        error if @async.is_being_cancelled() => raise error
        error => "\{error}"
      }
    })
    guard follower.inbox.get() is Stop(generation~, ..) else {
      fail("expected Stop")
    }
    manager.followers.remove("s-stop-proof")
    let detail = caller.wait()
    assert_true(detail.contains("without completing"))

    let completed = follower_state_fixture("s-stop-complete")
    manager.followers["s-stop-complete"] = completed
    let successful = group.spawn(() => {
      stop_follower(manager, "s-stop-complete", writer_exited=false)
      true
    })
    guard completed.inbox.get() is Stop(generation=completed_generation, ..) else {
      fail("expected second Stop")
    }
    completed.completed_stop_generation = completed_generation
    completed.completed_stop_error = None
    manager.followers.remove("s-stop-complete")
    assert_true(successful.wait())
    ignore(generation)
  })
}
