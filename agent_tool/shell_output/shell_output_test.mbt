///|
async fn poll_terminal(rt : @bgjobs.BgJobRuntime, id : String) -> Unit {
  for _ in 0..<200 {
    if rt.snapshot(id) is Some(snap) && !(snap.status is Running) {
      return
    }
    @async.sleep(25)
  }
  fail("job \{id} did not finish in time")
}

///|
fn read_output(
  rt : @bgjobs.BgJobRuntime,
  arguments : Json,
) -> @agent_tool.ToolOutput raise {
  let action = match @shell_output.definition(rt).execute {
    Sync(execute) => execute(arguments)
    Async(_) => fail("shell_output should be a sync tool")
  }
  guard action is Respond(output) else { fail("expected a Respond action") }
  output
}

///|
#cfg(not(platform="windows"))
async test "shell_output reports a finished job's output and status" {
  @async.with_task_group(group => {
    let rt = @bgjobs.BgJobRuntime::new(AgentTaskScope(group))
    let id = rt.start(
      program="sh",
      args=["-c", "printf hi"],
      command="printf hi",
    )
    poll_terminal(rt, id)
    let output = read_output(rt, { "job_id": id })
    assert_false(output.is_error)
    assert_true(output.content.contains("hi"))
    assert_true(output.content.contains("status=exited=0"))
  })
}

///|
#cfg(not(platform="windows"))
async test "shell_output flags a non-zero exit as an error" {
  @async.with_task_group(group => {
    let rt = @bgjobs.BgJobRuntime::new(AgentTaskScope(group))
    let id = rt.start(program="sh", args=["-c", "exit 2"], command="exit 2")
    poll_terminal(rt, id)
    let output = read_output(rt, { "job_id": id })
    assert_true(output.is_error)
    assert_true(output.content.contains("status=exited=2"))
  })
}

///|
async test "shell_output errors on an unknown job id" {
  @async.with_task_group(group => {
    let rt = @bgjobs.BgJobRuntime::new(AgentTaskScope(group))
    let output = read_output(rt, { "job_id": "nope" })
    assert_true(output.is_error)
    assert_true(output.content.contains("no background job"))
  })
}

///|
async test "shell_output rejects a missing job id" {
  @async.with_task_group(group => {
    let rt = @bgjobs.BgJobRuntime::new(AgentTaskScope(group))
    let output = read_output(rt, {})
    assert_true(output.is_error)
    assert_true(output.content.contains("requires a non-empty job_id"))
  })
}
