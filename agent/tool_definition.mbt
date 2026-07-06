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
  on_background_wake? : () -> Unit = () => (),
) -> @agent_tool.Tools raise {
  // One background-job runtime per session, owned by `scope.group()`, shared by
  // the shell tools so a job started via `run_in_background` is later visible to
  // the poll/stop tools. When a job finishes on its own, push a completion
  // notice as steering (the loop surfaces it to the model, which reads the full
  // output with `shell_output`) and call `on_background_wake` — a serve engine
  // uses it to wake an idle loop so the notice is delivered between turns.
  let bg_runtime = @bgjobs.BgJobRuntime::new(scope, on_job_exit=snapshot => {
    runtime.queue_steer(Notice(background_job_notice(snapshot)))
    on_background_wake()
  })
  let workspace_root = runtime.workspace_root()
  Tools([
    // Foreground shell runs on the shared execution model too (on the session
    // group, with the foreground output-limit kill), so it uses the same output
    // sink as background jobs and can later be detached on timeout.
    @shell.definition(bg_runtime~, workspace_root~, foreground_spawn=(
      program,
      args,
      cwd,
      max_output_chars,
    ) => {
      @shell_exec.ShellExecution::start(
        scope,
        program~,
        args~,
        cwd?,
        inline_cap=max_output_chars,
        hard_cap=max_output_chars,
        kill_when_full=true,
      )
    }),
    @shell_output.definition(bg_runtime),
    @shell_stop.definition(bg_runtime),
    @read.definition(workspace_root~),
    @edit.definition(workspace_root~),
    @multi_edit.definition(workspace_root~),
    @write.definition(workspace_root~),
    @plan.definition(),
    @finish.definition(),
  ])
}

///|
/// A one-line completion notice for a finished background job, pushed to the
/// model as steering so it knows the job is done and can read its output.
fn background_job_notice(snapshot : @bgjobs.BgJobSnapshot) -> String {
  let status = match snapshot.status {
    Running => "is still running"
    Exited(code) => "exited with code \{code}"
    Stopped => "was stopped"
  }
  "background job \{snapshot.id} (`\{snapshot.command}`) \{status}. Read its output with shell_output (job_id=\"\{snapshot.id}\")."
}

///|
async test "agent registers the expected tool names" {
  @async.with_task_group() <| group => {
    let tools = build_tools(AgentRuntime(), AgentTaskScope(group))
    let function_tools = tools.function_tools()
    assert_eq(function_tools.length(), 9)
    let names = [ for t in function_tools => t.name ]
    assert_true(names.contains("shell"))
    assert_true(names.contains("shell_output"))
    assert_true(names.contains("shell_stop"))
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
