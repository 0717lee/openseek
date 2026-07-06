///|
async fn stop_job(
  rt : @bgjobs.BgJobRuntime,
  arguments : Json,
) -> @agent_tool.ToolOutput {
  let action = match @shell_stop.definition(rt).execute {
    Async(execute) => execute(arguments)
    Sync(_) => fail("shell_stop should be an async tool")
  }
  guard action is Respond(output) else { fail("expected a Respond action") }
  output
}

///|
#cfg(not(platform="windows"))
async test "shell_stop stops a running job" {
  @async.with_task_group(group => {
    let rt = @bgjobs.BgJobRuntime::new(AgentTaskScope(group))
    let id = rt.start(program="sleep", args=["30"], command="sleep 30")
    @async.sleep(50)
    let output = stop_job(rt, { "job_id": id })
    assert_false(output.is_error)
    assert_true(output.content.contains("stopped background job"))
    assert_true(rt.snapshot(id).unwrap().status is Stopped)
  })
}

///|
async test "shell_stop errors on an unknown job id" {
  @async.with_task_group(group => {
    let rt = @bgjobs.BgJobRuntime::new(AgentTaskScope(group))
    let output = stop_job(rt, { "job_id": "nope" })
    assert_true(output.is_error)
    assert_true(output.content.contains("no background job"))
  })
}

///|
async test "shell_stop rejects a missing job id" {
  @async.with_task_group(group => {
    let rt = @bgjobs.BgJobRuntime::new(AgentTaskScope(group))
    let output = stop_job(rt, {})
    assert_true(output.is_error)
    assert_true(output.content.contains("requires a non-empty job_id"))
  })
}
