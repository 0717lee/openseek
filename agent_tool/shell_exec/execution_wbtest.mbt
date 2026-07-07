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
    assert_true(exec.head().contains("hello"))
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
async test "stop and request_stop terminate a running execution" {
  @async.with_task_group(group => {
    let exec = ShellExecution::start(AgentTaskScope(group), program="sleep", args=[
      "30",
    ])
    @async.sleep(50)
    assert_true(exec.status() is Running)
    assert_true(exec.stop())
    assert_true(exec.status() is Killed)
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
    exec.request_stop()
    poll_exec_terminal(exec)
    assert_true(exec.status() is Killed)
  })
}

///|
#cfg(not(platform="windows"))
async test "background flips to Backgrounded and keeps running" {
  @async.with_task_group(group => {
    let exec = ShellExecution::start(AgentTaskScope(group), program="sleep", args=[
      "30",
    ])
    @async.sleep(50)
    assert_true(exec.background())
    assert_true(exec.status() is Backgrounded)
    assert_true(exec.stop())
    assert_true(exec.status() is Killed)
  })
}

///|
#cfg(not(platform="windows"))
async test "kill_when_full stops a runaway once the sink fills" {
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
    assert_true(exec.status() is Killed)
    assert_true(exec.output_truncated())
  })
}

///|
#cfg(not(platform="windows"))
async test "large output spills and read_all returns the full output" {
  @async.with_task_group(group => {
    let path = "/tmp/openseek-exec-spill.out"
    let exec = ShellExecution::start(
      AgentTaskScope(group),
      program="sh",
      args=["-c", "seq 1 5000"],
      inline_cap=100,
      hard_cap=1000000,
      spill_path=path,
    )
    poll_exec_terminal(exec)
    assert_true(exec.status() is Exited(0))
    assert_true(exec.over_inline_cap())
    assert_true(exec.spill_path() is Some(_))
    // head is a bounded preview; read_all is the full output.
    assert_true(exec.head().has_prefix("1\n"))
    let full = exec.read_all()
    assert_true(full.has_prefix("1\n"))
    assert_true(full.contains("5000"))
  })
}
