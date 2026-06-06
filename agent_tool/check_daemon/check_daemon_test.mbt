///|
async fn[X] run_check_daemon(
  runtime : @agent_tool.AgentRuntime[X],
  arguments : Json,
) -> @agent_tool.ToolAction {
  match definition(runtime).execute {
    Async(execute) => execute(arguments)
    Sync(_) => fail("check_daemon tool should be async")
  }
}

///|
#cfg(platform="windows")
fn print_once_cmd() -> String {
  "[Console]::Out.Write('daemon-ok')"
}

///|
#cfg(not(platform="windows"))
fn print_once_cmd() -> String {
  "printf %s daemon-ok"
}

///|
#cfg(platform="windows")
fn sleep_cmd() -> String {
  "Start-Sleep -Seconds 5"
}

///|
#cfg(not(platform="windows"))
fn sleep_cmd() -> String {
  "sleep 5"
}

///|
async test "check_daemon starts a command and retains initial output" {
  @async.with_task_group() <| group => {
    let runtime = @agent_tool.AgentRuntime(group)
    let result = run_check_daemon(runtime, {
      "action": "start",
      "cmd": print_once_cmd(),
      "name": "once",
      "initial_wait_ms": 100,
    })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_true(output.content.contains("check_daemon started"))
    assert_true(output.content.contains("id=daemon-1"))
    assert_true(output.content.contains("name=once"))
    assert_true(output.content.contains("daemon-ok"))
  }
}

///|
async test "check_daemon status reports latest retained output" {
  @async.with_task_group() <| group => {
    let runtime = @agent_tool.AgentRuntime(group)
    ignore(
      run_check_daemon(runtime, {
        "action": "start",
        "cmd": print_once_cmd(),
        "initial_wait_ms": 100,
      }),
    )
    let result = run_check_daemon(runtime, {
      "action": "status",
      "id": "daemon-1",
    })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_true(output.content.contains("check_daemon status"))
    assert_true(output.content.contains("id=daemon-1"))
    assert_true(output.content.contains("daemon-ok"))
  }
}

///|
async test "check_daemon stop marks a running command stopped" {
  @async.with_task_group() <| group => {
    let runtime = @agent_tool.AgentRuntime(group)
    ignore(
      run_check_daemon(runtime, {
        "action": "start",
        "cmd": sleep_cmd(),
        "initial_wait_ms": 1,
      }),
    )
    let result = run_check_daemon(runtime, {
      "action": "stop",
      "id": "daemon-1",
    })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_true(output.content.contains("check_daemon stopped"))
    assert_true(output.content.contains("status=stopped"))
  }
}

///|
async test "check_daemon rejects unknown ids" {
  @async.with_task_group() <| group => {
    let runtime = @agent_tool.AgentRuntime(group)
    let result = run_check_daemon(runtime, {
      "action": "status",
      "id": "missing",
    })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("unknown check_daemon id=missing"))
  }
}
