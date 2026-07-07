///|
#cfg(not(platform="windows"))
async test "shell_output returns a running job's output and status" {
  @async.with_task_group(group => {
    let bg = @bgjobs.BgJobRuntime::new(AgentTaskScope(group))
    let id = bg.start(
      program="sh",
      args=["-c", "printf hi; sleep 30"],
      command="job",
    )
    @async.sleep(100)
    let action = match @shell_output.definition(bg).execute {
      Async(execute) => execute({ "job_id": id })
      Sync(_) => fail("shell_output should be async")
    }
    guard action is Respond(output) else { fail("expected a Respond action") }
    assert_false(output.is_error)
    assert_true(output.content.contains("hi"))
    assert_true(output.content.contains("running"))
    let _ = bg.stop(id)
  })
}

///|
#cfg(not(platform="windows"))
async test "shell_output reports a finished job's exit code" {
  @async.with_task_group(group => {
    let bg = @bgjobs.BgJobRuntime::new(AgentTaskScope(group))
    let id = bg.start(program="sh", args=["-c", "exit 2"], command="job")
    for _ in 0..<200 {
      if bg.snapshot(id) is Some(s) && !(s.status is Running) {
        break
      }
      @async.sleep(25)
    }
    let action = match @shell_output.definition(bg).execute {
      Async(execute) => execute({ "job_id": id })
      Sync(_) => fail("shell_output should be async")
    }
    guard action is Respond(output) else { fail("expected a Respond action") }
    assert_true(output.is_error)
    assert_true(output.content.contains("exit=2"))
  })
}

///|
#cfg(not(platform="windows"))
async test "shell_output windows a large job's output and notes truncation" {
  @async.with_task_group(group => {
    let bg = @bgjobs.BgJobRuntime::new(AgentTaskScope(group), spill_dir="/tmp")
    let id = bg.start(
      program="sh",
      args=["-c", "seq 1 20000"],
      command="seq",
      max_output_chars=100,
    )
    for _ in 0..<200 {
      if bg.snapshot(id) is Some(s) && !(s.status is Running) {
        break
      }
      @async.sleep(25)
    }
    let action = match @shell_output.definition(bg).execute {
      Async(execute) => execute({ "job_id": id })
      Sync(_) => fail("shell_output should be async")
    }
    guard action is Respond(output) else { fail("expected a Respond action") }
    // Bounded to the window, with truncation metadata, but still showing the
    // recent (tail) output — here the end of the sequence.
    assert_true(output.content.contains("truncated=true"))
    assert_true(output.content.contains("20000"))
    assert_true(output.content.char_length() < 80000)
  })
}

///|
#cfg(not(platform="windows"))
async test "shell_output flags dropped output for a memory-only job" {
  @async.with_task_group(group => {
    // Memory-only runtime (no spill dir): output past the budget is dropped.
    let bg = @bgjobs.BgJobRuntime::new(AgentTaskScope(group))
    let id = bg.start(
      program="sh",
      args=["-c", "seq 1 2000"],
      command="seq",
      max_output_chars=100,
    )
    for _ in 0..<200 {
      if bg.snapshot(id) is Some(s) && !(s.status is Running) {
        break
      }
      @async.sleep(25)
    }
    let action = match @shell_output.definition(bg).execute {
      Async(execute) => execute({ "job_id": id })
      Sync(_) => fail("shell_output should be async")
    }
    guard action is Respond(output) else { fail("expected a Respond action") }
    // Only ~100 chars retained but the job produced far more — must not present
    // the prefix as complete.
    assert_true(output.content.contains("truncated=true"))
  })
}

///|
#cfg(not(platform="windows"))
async test "shell_output errors on an unknown job id" {
  @async.with_task_group(group => {
    let bg = @bgjobs.BgJobRuntime::new(AgentTaskScope(group))
    let action = match @shell_output.definition(bg).execute {
      Async(execute) => execute({ "job_id": "nope" })
      Sync(_) => fail("shell_output should be async")
    }
    guard action is Respond(output) else { fail("expected a Respond action") }
    assert_true(output.is_error)
    assert_true(output.content.contains("no background job"))
  })
}
