///|
/// Build the agent's standard tool registry bound to `runtime` and `scope`.
///
/// The returned registry contains the built-in local tools: `shell`, `read`,
/// `edit`, `multi_edit`, `write`, `plan`, and `finish`. Each tool lives in its
/// own subpackage of `agent_tool` and exposes a `definition()` constructor;
/// this function bundles them into the `Tools` value the loop dispatches
/// against. File-oriented tools capture `runtime.workspace_root()` when this
/// function is called. The `scope` parameter remains part of the API so future
/// stateful tools can spawn bounded background work under the caller-owned
/// task scope.
///
/// Raises if the standard tool definitions contain duplicate names. Under the
/// checked-in registry that should be a programming error, not user input.
pub fn[X] build_tools(
  runtime : @agent_runtime.AgentRuntime,
  scope : @agent_runtime.AgentTaskScope[X],
) -> @agent_tool.Tools raise {
  // The task scope is plumbed through for stateful tools; none currently need
  // it (moon_check — the watcher tool — was removed in favor of plain
  // `moon check` through shell).
  ignore(scope)
  let workspace_root = runtime.workspace_root()
  Tools([
    @shell.definition(workspace_root~),
    @read.definition(workspace_root~),
    @edit.definition(workspace_root~),
    @multi_edit.definition(workspace_root~),
    @write.definition(workspace_root~),
    @plan.definition(),
    @finish.definition(),
  ])
}

///|
async test "agent registers the expected tool names" {
  @async.with_task_group() <| group => {
    let tools = build_tools(AgentRuntime(), AgentTaskScope(group))
    let function_tools = tools.function_tools()
    assert_eq(function_tools.length(), 7)
    let names = [ for t in function_tools => t.name ]
    assert_true(names.contains("shell"))
    assert_true(names.contains("read"))
    assert_true(names.contains("edit"))
    assert_true(names.contains("multi_edit"))
    assert_true(names.contains("write"))
    assert_true(names.contains("plan"))
    assert_true(names.contains("finish"))
    assert_false(names.contains("moon_check"))
    assert_false(names.contains("moon_cmd"))
    assert_false(names.contains("moon_ide"))
  }
}
