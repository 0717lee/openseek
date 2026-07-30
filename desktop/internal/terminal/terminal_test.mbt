// Behavioral tests through the public API: a real pump running in a task
// group, sessions spawning real PTY children. Process-specific cases are
// platform-gated; lifecycle cases use the platform's default shell.

///|
/// Collect pushes from a pump into a queue the test can await on.
fn new_push_queue() -> @async.Queue[@terminal.TerminalPush] {
  Queue(kind=Unbounded)
}

///|
async fn wait_for_output(
  pushes : @async.Queue[@terminal.TerminalPush],
  needle : String,
) -> Unit {
  let mut seen = ""
  for ;; {
    if pushes.get() is Output(data~, ..) {
      seen = seen + @utf8.decode_lossy(data)
      if seen.contains(needle) {
        break
      }
    }
  }
}

///|
async fn wait_for_exit(pushes : @async.Queue[@terminal.TerminalPush]) -> Unit {
  for ;; {
    if pushes.get() is Exited(..) {
      break
    }
  }
}

///|
#cfg(not(platform="windows"))
async test "terminal session round-trips output and reports exit" {
  @async.with_task_group(group => {
    let state = @terminal.new_terminal_state()
    let pushes = new_push_queue()
    group.spawn_bg(allow_failure=true, () => {
      @terminal.run_terminal_pump(state, async fn(push) { pushes.put(push) })
    })
    let id = @terminal.open_terminal(state, cwd="/tmp", cols=80, rows=24, command=[
      "/bin/cat",
    ])
    @terminal.write_terminal(state, id~, @utf8.encode("ping\n"))
    @async.with_timeout(5000, () => wait_for_output(pushes, "ping"))
    @terminal.resize_terminal(state, id~, cols=100, rows=30)
    @terminal.close_terminal(state, id~)
    @async.with_timeout(5000, () => wait_for_exit(pushes))
    group.return_immediately(())
  })
}

///|
#cfg(not(platform="windows"))
async test "terminal session runs in the requested directory" {
  @async.with_task_group(group => {
    let state = @terminal.new_terminal_state()
    let pushes = new_push_queue()
    group.spawn_bg(allow_failure=true, () => {
      @terminal.run_terminal_pump(state, async fn(push) { pushes.put(push) })
    })
    let id = @terminal.open_terminal(state, cwd="/tmp", cols=80, rows=24, command=[
      "/bin/sh", "-c", "pwd",
    ])
    // /tmp is a symlink to /private/tmp on macOS; match the suffix.
    @async.with_timeout(5000, () => wait_for_output(pushes, "tmp"))
    @async.with_timeout(5000, () => wait_for_exit(pushes))
    ignore(id)
    group.return_immediately(())
  })
}

///|
/// Direct spawning reports a missing executable while opening the session,
/// instead of first opening a shell that later exits 127.
async test "a missing program fails while opening the session" {
  @async.with_task_group(group => {
    let state = @terminal.new_terminal_state()
    let pushes = new_push_queue()
    group.spawn_bg(allow_failure=true, () => {
      @terminal.run_terminal_pump(state, async fn(push) { pushes.put(push) })
    })
    let failed = try {
      let _ = @terminal.open_terminal(state, cwd=".", cols=80, rows=24, command=[
        "openseek-terminal-test-program-that-does-not-exist",
      ])
      false
    } catch {
      @terminal.TerminalError(_) => true
      _ => false
    }
    assert_true(failed)
    group.return_immediately(())
  })
}

///|
async test "an empty command is rejected before spawning" {
  let state = @terminal.new_terminal_state()
  let failed = try {
    let _ = @terminal.open_terminal(state, cwd=".", cols=80, rows=24, command=[])
    false
  } catch {
    @terminal.TerminalError(_) => true
    _ => false
  }
  assert_true(failed)
}

///|
/// `close_all_terminals` (the connect handshake's sweep) retires every live
/// session; each one still reports its exit.
#cfg(not(platform="windows"))
async test "close_all_terminals retires every live session" {
  @async.with_task_group(group => {
    let state = @terminal.new_terminal_state()
    let pushes = new_push_queue()
    group.spawn_bg(allow_failure=true, () => {
      @terminal.run_terminal_pump(state, async fn(push) { pushes.put(push) })
    })
    let first = @terminal.open_terminal(state, cwd=".", cols=80, rows=24)
    let second = @terminal.open_terminal(state, cwd=".", cols=80, rows=24)
    @terminal.close_all_terminals(state)
    let exited : Array[Int] = []
    @async.with_timeout(5000, () => {
      while exited.length() < 2 {
        if pushes.get() is Exited(id~, ..) {
          exited.push(id)
        }
      }
    })
    exited.sort()
    assert_eq(exited, [first, second])
    group.return_immediately(())
  })
}

///|
/// An old page can disappear after its open request reaches the host but
/// before the pump starts it. The next connect handshake must reject that
/// queued request instead of starting a shell with no tab to own it.
async test "close_all_terminals cancels queued opens from an older page" {
  @async.with_task_group(group => {
    let state = @terminal.new_terminal_state()
    let pushes = new_push_queue()
    let cancelled : @async.Queue[Bool] = Queue(kind=Blocking(1))
    group.spawn_bg(allow_failure=true, () => {
      let was_cancelled = try {
        let _ = @terminal.open_terminal(state, cwd=".", cols=80, rows=24)
        false
      } catch {
        @terminal.TerminalError("terminal open was cancelled by reconnect") =>
          true
        _ => false
      }
      cancelled.put(was_cancelled)
    })
    // Let the opener enqueue its request and block on the reply before the
    // reconnect sweep advances the page connection.
    @async.pause()
    @terminal.close_all_terminals(state)
    group.spawn_bg(allow_failure=true, () => {
      @terminal.run_terminal_pump(state, async fn(push) { pushes.put(push) })
    })
    let was_cancelled = @async.with_timeout(5000, () => cancelled.get())
    assert_true(was_cancelled)
    group.return_immediately(())
  })
}

///|
test "ops on unknown terminal ids degrade cleanly" {
  let state = @terminal.new_terminal_state()
  // ack and close are fire-and-forget: an id that already exited is fine.
  @terminal.ack_terminal(state, id=99, bytes=100)
  @terminal.close_terminal(state, id=99)
  let failed = try {
    @terminal.resize_terminal(state, id=99, cols=80, rows=24)
    false
  } catch {
    @terminal.TerminalError(_) => true
    _ => false
  }
  assert_true(failed)
}
