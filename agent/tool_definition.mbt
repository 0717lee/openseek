///|
/// The agent's local tool registry. Each tool lives in its own subpackage of
/// `agent_tool` and exposes a `definition()` constructor; this function bundles
/// them into the `Tools` value the loop dispatches against. Raises if two
/// definitions share a name.
fn tool_definitions(
  runtime : @agent_tool.AgentRuntime[Unit],
) -> @agent_tool.Tools raise {
  Tools([
    @shell.definition(),
    @read.definition(),
    @edit.definition(),
    @write.definition(),
    @check_daemon.definition(runtime),
    @moon_check.definition(),
    @moon_cmd.definition(),
    @moon_ide.definition(),
    @finish.definition(),
  ])
}

///|
async test "agent registers the expected tool names" {
  @async.with_task_group() <| group => {
    let tools = tool_definitions(AgentRuntime(group))
    let function_tools = tools.function_tools()
    assert_eq(function_tools.length(), 9)
    let names = [ for t in function_tools => t.name ]
    assert_true(names.contains("shell"))
    assert_true(names.contains("read"))
    assert_true(names.contains("edit"))
    assert_true(names.contains("write"))
    assert_true(names.contains("check_daemon"))
    assert_true(names.contains("moon_check"))
    assert_true(names.contains("moon_cmd"))
    assert_true(names.contains("moon_ide"))
    assert_true(names.contains("finish"))
  }
}
