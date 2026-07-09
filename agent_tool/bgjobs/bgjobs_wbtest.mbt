///|
/// Poll `id` until it leaves `Running`, failing after a bounded deadline so a
/// hung child can never hang the test. Async tests run in parallel, so each test
/// isolates its own runtime and jobs.
#cfg(not(platform="windows"))
async fn poll_until_terminal(
  rt : BgJobRuntime,
  id : String,
  ticks? : Int = 200,
) -> BgJobSnapshot {
  for _ in 0..<ticks {
    if rt.snapshot(id) is Some(snap) && !(snap.status is Running) {
      return snap
    }
    @async.sleep(25)
  }
  fail("bg job \{id} did not reach a terminal state in time")
}

///|
/// Await the first pushed exit notice, on the same 200 x 25ms budget as
/// `poll_until_terminal`.
#cfg(not(platform="windows"))
async fn wait_for_first(notices : Array[BgJobSnapshot]) -> Unit {
  for _ in 0..<200 {
    if notices.length() > 0 {
      return
    }
    @async.sleep(25)
  }
}

///|
#cfg(not(platform="windows"))
async test "bg job runs to completion and captures output" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    let id = rt.start(
      program="sh",
      args=["-c", "printf hello"],
      command="printf hello",
    )
    let snap = poll_until_terminal(rt, id)
    assert_true(snap.status is Exited(0))
    assert_true(snap.output.contains("hello"))
    assert_true(snap.exit_code is Some(0))
  })
}

///|
#cfg(not(platform="windows"))
async test "bg job records a non-zero exit code" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    let id = rt.start(program="sh", args=["-c", "exit 3"], command="exit 3")
    let snap = poll_until_terminal(rt, id)
    assert_true(snap.status is Exited(3))
    assert_true(snap.exit_code is Some(3))
  })
}

///|
#cfg(not(platform="windows"))
async test "stop terminates a running job" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    let id = rt.start(program="sleep", args=["30"], command="sleep 30")
    @async.sleep(50)
    assert_true(rt.snapshot(id).unwrap().status is Running)
    assert_true(rt.stop(id))
    assert_true(rt.snapshot(id).unwrap().status is Stopped)
  })
}

///|
#cfg(not(platform="windows"))
async test "a large-output job spills; snapshot previews, read_output is full" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group), spill_dir="/tmp")
    let id = rt.start(
      program="sh",
      args=["-c", "seq 1 5000"],
      command="seq",
      max_output_chars=100,
    )
    let snap = poll_until_terminal(rt, id)
    assert_true(snap.status is Exited(0))
    assert_true(snap.over_inline_cap)
    // The snapshot output is a bounded preview...
    assert_true(snap.output.char_length() <= 100)
    // ...while read_output returns the full output from the spill file.
    let full = rt.read_output(id).unwrap()
    assert_true(full.has_prefix("1\n"))
    assert_true(full.contains("5000"))
  })
}

///|
#cfg(not(platform="windows"))
async test "adopt registers an already-running execution as a job" {
  @async.with_task_group(group => {
    let scope : @agent_runtime.AgentTaskScope[Unit] = AgentTaskScope(group)
    let rt = BgJobRuntime::new(scope)
    let exec = @shell_exec.ShellExecution::start(scope, program="sleep", args=[
      "30",
    ])
    let id = rt.adopt(exec, command="sleep 30")
    @async.sleep(50)
    assert_true(rt.snapshot(id).unwrap().status is Running)
    assert_true(rt.stop(id))
    assert_true(rt.snapshot(id).unwrap().status is Stopped)
  })
}

///|
#cfg(not(platform="windows"))
async test "on_job_exit fires once on a natural exit, never on stop" {
  @async.with_task_group(group => {
    let seen : Array[BgJobSnapshot] = []
    let rt = BgJobRuntime::new(AgentTaskScope(group), on_job_exit=snapshot => {
      seen.push(snapshot)
    })
    let done = rt.start(
      program="sh",
      args=["-c", "printf done"],
      command="printf done",
    )
    let stopped = rt.start(program="sleep", args=["30"], command="sleep 30")
    @async.sleep(50)
    assert_true(rt.stop(stopped))
    wait_for_first(seen)
    @async.sleep(50)
    // Exactly one notice — for the natural exit, not the stopped job.
    assert_true(seen.length() == 1)
    assert_true(seen[0].id == done)
    assert_true(seen[0].status is Exited(0))
  })
}

///|
#cfg(not(platform="windows"))
async test "snapshot, read_output, and stop handle unknown ids" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    assert_true(rt.snapshot("nope") is None)
    assert_true(rt.read_output("nope") is None)
    assert_false(rt.stop("nope"))
  })
}

///|
#cfg(not(platform="windows"))
async test "start allocates one id per job (id matches its spill file)" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group), spill_dir="/tmp")
    // The first started job is bg-1 (not bg-2): start must not reserve an id for
    // the spill path and then allocate a second one for the registry entry.
    let a = rt.start(program="sh", args=["-c", "printf a"], command="a")
    assert_true(a == "bg-1")
    let b = rt.start(program="sh", args=["-c", "printf b"], command="b")
    assert_true(b == "bg-2")
  })
}

///|
#cfg(not(platform="windows"))
async test "two jobs run independently with distinct ids" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    let a = rt.start(program="sh", args=["-c", "printf aaa"], command="a")
    let b = rt.start(program="sh", args=["-c", "printf bbb"], command="b")
    assert_true(a != b)
    let sa = poll_until_terminal(rt, a)
    let sb = poll_until_terminal(rt, b)
    assert_true(sa.output.contains("aaa"))
    assert_true(sb.output.contains("bbb"))
    assert_true(rt.list().length() == 2)
  })
}

///|
#cfg(not(platform="windows"))
async test "the watchdog kills a background job that floods past the hard cap" {
  @async.with_task_group(group => {
    let notices : Array[BgJobSnapshot] = []
    // Tiny hard cap so `yes` trips the watchdog immediately instead of running
    // to the 20M default.
    let rt = BgJobRuntime::new(AgentTaskScope(group), hard_output_cap=200, on_job_exit=snapshot => {
      notices.push(snapshot)
    })
    let id = rt.start(program="yes", args=[], command="yes")
    let snapshot = poll_until_terminal(rt, id)
    // Killed by the watchdog — not left running with its output dropped — and
    // reported as such, not as a requested stop.
    assert_true(snapshot.status is Stopped)
    assert_true(snapshot.killed_by_output_limit)
    assert_true(snapshot.output_truncated)
    // The kill is pushed like a natural exit: a silently dead job would look
    // like it just never finished.
    wait_for_first(notices)
    assert_true(notices.length() == 1)
    assert_true(notices[0].killed_by_output_limit)
  })
}

///|
#cfg(not(platform="windows"))
async test "the reaper kills a background job that outlives the time cap" {
  @async.with_task_group(group => {
    let notices : Array[BgJobSnapshot] = []
    let rt = BgJobRuntime::new(AgentTaskScope(group), hard_timeout_ms=80, on_job_exit=snapshot => {
      notices.push(snapshot)
    })
    let id = rt.start(program="sh", args=["-c", "sleep 5"], command="sleep 5")
    let snapshot = poll_until_terminal(rt, id)
    assert_true(snapshot.status is Stopped)
    assert_true(snapshot.killed_by_time_limit)
    assert_false(snapshot.killed_by_output_limit)
    // The kill is surfaced exactly once, like an output-cap kill.
    wait_for_first(notices)
    assert_true(notices.length() == 1)
    assert_true(notices[0].killed_by_time_limit)
  })
}

///|
#cfg(not(platform="windows"))
async test "an adopted job keeps its original wall-clock deadline" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group), hard_timeout_ms=150)
    // The execution starts OUTSIDE the registry (a foreground command) and
    // burns most of its lifetime before being adopted on detach.
    let exec = rt.spawn_foreground_retained("sh", ["-c", "sleep 5"], None, 200)
    @async.sleep(120)
    let _ = exec.background()
    let id = rt.adopt(exec, command="sleep 5", source_write_sandboxed=false, sandbox_denial_subjects=[])
    // Deadline measured from process start: ~30ms remain, not a fresh 150ms —
    // the poll budget below is far under 150ms of slack either way.
    let snapshot = poll_until_terminal(rt, id, ticks=40)
    assert_true(snapshot.killed_by_time_limit)
  })
}

///|
#cfg(not(platform="windows"))
async test "a requested stop is not blamed on the reaper" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group), hard_timeout_ms=60_000)
    let id = rt.start(program="sh", args=["-c", "sleep 5"], command="sleep 5")
    let _ = rt.stop(id)
    guard rt.snapshot(id) is Some(snapshot) else { fail("expected snapshot") }
    assert_false(snapshot.killed_by_time_limit)
    assert_false(snapshot.killed_by_output_limit)
  })
}
