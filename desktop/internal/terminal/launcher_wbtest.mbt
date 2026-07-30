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
    // A shell that cannot enter the working directory exits immediately, so
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
/// The launcher enters the working directory itself, so a directory that is
/// missing (a conversation whose workspace has not been created yet) must be
/// reported rather than silently producing a shell in the wrong place.
async test "a session whose cwd does not exist exits nonzero" {
  @async.with_task_group(group => {
    let state = new_terminal_state()
    let pushes : @async.Queue[TerminalPush] = Queue(kind=Unbounded)
    group.spawn_bg(allow_failure=true, () => {
      run_terminal_pump(state, async fn(push) { pushes.put(push) })
    })
    let _ = open_terminal(
      state,
      cwd="/nonexistent/openseek-terminal-test",
      cols=80,
      rows=24,
    )
    let mut code = 0
    @async.with_timeout(5000, () => {
      for ;; {
        if pushes.get() is Exited(code=exit_code, ..) {
          code = exit_code
          break
        }
      }
    })
    assert_true(code != 0)
    group.return_immediately(())
  })
}
