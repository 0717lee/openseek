///|
#cfg(not(platform="windows"))
async test "shell_stop cancels a running job" {
  @async.with_task_group(group => {
    let bg = @bgjobs.BgJobRuntime::new(AgentTaskScope(group))
    let id = bg.start(program="sleep", args=["30"], command="sleep 30")
    @async.sleep(50)
    assert_true(bg.snapshot(id).unwrap().status is Running)
    let action = match @shell_stop.definition(bg).execute {
      Async(execute) => execute({ "job_id": id })
      Sync(_) => fail("shell_stop should be async")
    }
    guard action is Respond(output) else { fail("expected a Respond action") }
    assert_false(output.is_error)
    assert_true(output.content.contains("stopped"))
    assert_true(bg.snapshot(id).unwrap().status is Stopped)
  })
}

///|
#cfg(not(platform="windows"))
async test "shell_stop errors on an unknown job id" {
  @async.with_task_group(group => {
    let bg = @bgjobs.BgJobRuntime::new(AgentTaskScope(group))
    let action = match @shell_stop.definition(bg).execute {
      Async(execute) => execute({ "job_id": "nope" })
      Sync(_) => fail("shell_stop should be async")
    }
    guard action is Respond(output) else { fail("expected a Respond action") }
    assert_true(output.is_error)
    assert_true(output.content.contains("no background job"))
  })
}
