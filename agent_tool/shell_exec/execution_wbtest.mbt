///|
/// Poll an execution until it reaches a terminal status, failing after a bounded
/// deadline so a hung child can never hang the test.
#cfg(not(platform="windows"))
async fn poll_exec_terminal(exec : ShellExecution, ticks? : Int = 200) -> Unit {
  for _ in 0..<ticks {
    if exec.status().is_terminal() {
      return
    }
    @async.sleep(25)
  }
  fail("execution did not reach a terminal state in time")
}

///|
#cfg(not(platform="windows"))
async test "execution runs to completion and captures output" {
  @async.with_task_group(group => {
    let exec = ShellExecution::start(AgentTaskScope(group), program="sh", args=[
      "-c", "printf hello",
    ])
    poll_exec_terminal(exec)
    assert_true(exec.status() is Exited(0))
    assert_true(exec.output().contains("hello"))
    assert_true(exec.exit_code() is Some(0))
  })
}

///|
#cfg(not(platform="windows"))
async test "execution records a non-zero exit code" {
  @async.with_task_group(group => {
    let exec = ShellExecution::start(AgentTaskScope(group), program="sh", args=[
      "-c", "exit 3",
    ])
    poll_exec_terminal(exec)
    assert_true(exec.status() is Exited(3))
    assert_true(exec.exit_code() is Some(3))
  })
}

///|
#cfg(not(platform="windows"))
async test "stop terminates a running execution" {
  @async.with_task_group(group => {
    let exec = ShellExecution::start(AgentTaskScope(group), program="sleep", args=[
      "30",
    ])
    @async.sleep(50)
    assert_true(exec.status() is Running)
    assert_true(exec.stop())
    assert_true(exec.status() is Killed)
    // A second stop is idempotent and returns false on a terminal execution.
    assert_false(exec.stop())
  })
}

///|
#cfg(not(platform="windows"))
async test "request_stop synchronously terminates a running execution" {
  @async.with_task_group(group => {
    let exec = ShellExecution::start(AgentTaskScope(group), program="sleep", args=[
      "30",
    ])
    @async.sleep(50)
    assert_true(exec.status() is Running)
    // Sync stop with no await — the path used to clean up during turn
    // cancellation, where awaiting is not safe.
    exec.request_stop()
    poll_exec_terminal(exec)
    assert_true(exec.status() is Killed)
  })
}

///|
#cfg(not(platform="windows"))
async test "background flips a running execution to Backgrounded" {
  @async.with_task_group(group => {
    let exec = ShellExecution::start(AgentTaskScope(group), program="sleep", args=[
      "30",
    ])
    @async.sleep(50)
    assert_true(exec.background())
    assert_true(exec.status() is Backgrounded)
    // The process keeps running; stop still terminates it.
    assert_true(exec.stop())
    assert_true(exec.status() is Killed)
  })
}

///|
#cfg(not(platform="windows"))
async test "kill_when_full stops a runaway producer once the sink fills" {
  @async.with_task_group(group => {
    let exec = ShellExecution::start(
      AgentTaskScope(group),
      program="sh",
      args=["-c", "yes"],
      inline_cap=100,
      hard_cap=100,
      kill_when_full=true,
    )
    poll_exec_terminal(exec)
    // The runaway is killed once its output prefix fills the sink, not left to
    // block forever; truncation marks it as the output-limit case.
    assert_true(exec.status() is Killed)
    assert_true(exec.output_truncated())
  })
}

///|
#cfg(not(platform="windows"))
async test "output over the inline cap flags a pointer but keeps the prefix" {
  @async.with_task_group(group => {
    let exec = ShellExecution::start(
      AgentTaskScope(group),
      program="sh",
      args=["-c", "seq 1 100000"],
      inline_cap=100,
      hard_cap=1000,
    )
    poll_exec_terminal(exec)
    assert_true(exec.over_inline_cap())
    assert_true(exec.output_truncated())
    // Prefix retention: the output starts at the beginning, not a tail.
    assert_true(exec.output().has_prefix("1\n"))
  })
}
