///|
/// The completion notice pushed to the model when a background job exits: its
/// id, terminal status, command, and how to read its output.
fn background_notice_text(snapshot : @bgjobs.BgJobSnapshot) -> String {
  let status = match snapshot.status {
    Exited(0) => "exit=0"
    Exited(code) => "exit=\{code}"
    Stopped => "stopped"
    Running => "running"
  }
  "background job \{snapshot.id} finished (\{status}): `\{snapshot.command}` — read its output with shell_output (job_id=\"\{snapshot.id}\")."
}

///|
/// Build the agent's standard tool registry bound to `runtime` and `scope`.
///
/// The returned registry contains the built-in local tools: `shell`, `shell_output`, `shell_stop`, `read`,
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
///
/// `on_background_wake`, when supplied, is called each time a background job
/// exits, so an idle controller can wake to surface the completion notice.
pub async fn[X] build_tools(
  runtime : @agent_runtime.AgentRuntime,
  scope : @agent_runtime.AgentTaskScope[X],
  on_background_wake? : () -> Unit,
) -> @agent_tool.Tools {
  // One background-job runtime per session, owned by `scope.group()`, shared by
  // the shell tools so a job started via `run_in_background` (or a command moved
  // to the background on timeout) is visible to shell_output / shell_stop. A
  // session temp dir makes large background-job output file-backed (full output
  // on disk via the sink); a tmpdir failure degrades to memory-only jobs.
  let spill_dir : String? = Some(@fs.tmpdir(prefix="openseek-shell-")) catch {
    _ => None
  }
  // Remove the session spill dir (and every job's spill file in it) when the
  // owning scope ends, so `/tmp/openseek-shell-*` cannot accumulate across turns
  // or sessions. A task parks on a never-fed queue until group teardown cancels
  // it, then removes the dir shielded from that cancellation (rmdir is async, so
  // it cannot run in a `defer`).
  if spill_dir is Some(dir) {
    scope.group().spawn_bg(no_wait=true, allow_failure=true) <| () => {
      let parked : @async.Queue[Unit] = Queue(kind=Unbounded)
      try parked.get() |> ignore catch {
        _ =>
          @async.protect_from_cancel(() => {
            @fs.rmdir(dir, recursive=true) catch {
              _ => ()
            }
          })
      }
    }
  }
  // When a background job exits on its own, push a completion notice into the
  // loop's lossless steer queue (surfaced to the model at the next step, or
  // persisted while idle) and poke the controller so an idle engine wakes to
  // drain it instead of leaving it until the next prompt.
  let bg_runtime = @bgjobs.BgJobRuntime::new(scope, spill_dir?, on_job_exit=snapshot => {
    runtime.queue_steer(Notice(background_notice_text(snapshot)))
    match on_background_wake {
      Some(wake) => wake()
      None => ()
    }
  })
  let workspace_root = runtime.workspace_root()
  Tools([
    @shell.definition(workspace_root~, bg_runtime~),
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

///|
#cfg(not(platform="windows"))
async test "a finished background job queues a notice and wakes the controller" {
  @async.with_task_group(group => {
    let runtime = @agent_runtime.AgentRuntime()
    let mut woke = false
    let tools = build_tools(runtime, AgentTaskScope(group), on_background_wake=() => {
      woke = true
    })
    guard tools.find("shell") is Some(shell) else { fail("shell tool missing") }
    // Start a fast background job through the shell tool.
    let action = match shell.execute {
      Async(execute) => execute({ "cmd": "true", "run_in_background": true })
      Sync(_) => fail("shell should be async")
    }
    guard action is Respond(_) else { fail("expected the job to start") }
    // The job exits on its own → on_job_exit wakes the controller and queues a
    // completion notice.
    for _ in 0..<200 {
      if woke {
        break
      }
      @async.sleep(25)
    }
    assert_true(woke)
    let steers = runtime.drain_steers()
    assert_true(steers.iter().any(s => s is Notice(_)))
  })
}
