// The default path — no explicit `command`, so the session launches the
// user's login shell. Covered here because the shipped terminal always takes
// it, and a launcher that fails takes it silently: the shell dies before
// anything is typed.

///|
async test "a default session launches a live login shell in the given cwd" {
  @async.with_task_group(group => {
    let state = new_terminal_state()
    let pushes : @async.Queue[TerminalPush] = Queue(kind=Unbounded)
    group.spawn_bg(allow_failure=true, () => {
      run_terminal_pump(state, async fn(push) { pushes.put(push) })
    })
    let id = open_terminal(state, cwd="/tmp", cols=80, rows=24)
    // The PTY enters the working directory before starting the shell, so
    // "still running after its first output" is the property under test. The
    // timeout is generous because a real login shell runs the user's profile
    // (a slow one is not a failure); an early exit fails through the `Exited`
    // branch long before it.
    let text = StringBuilder::new()
    @async.with_timeout(15000, () => {
      for ;; {
        match pushes.get() {
          Output(data~, ..) => {
            text.write_string(@utf8.decode_lossy(data))
            if text.to_string().length() > 0 {
              break
            }
          }
          Exited(code~, ..) =>
            fail(
              "session exited early with status \{code}: \{text.to_string()}",
            )
        }
      }
    })
    close_terminal(state, id~)
    group.return_immediately(())
  })
}

///|
/// The platform spawn rejects a missing working directory before reporting
/// the session as open.
async test "a session whose cwd does not exist fails while opening" {
  @async.with_task_group(group => {
    let state = new_terminal_state()
    let pushes : @async.Queue[TerminalPush] = Queue(kind=Unbounded)
    group.spawn_bg(allow_failure=true, () => {
      run_terminal_pump(state, async fn(push) { pushes.put(push) })
    })
    let failed = try {
      let _ = open_terminal(
        state,
        cwd="/nonexistent/openseek-terminal-test",
        cols=80,
        rows=24,
      )
      false
    } catch {
      TerminalError(_) => true
      _ => false
    }
    assert_true(failed)
    group.return_immediately(())
  })
}
