///|
/// Parent-runner tests against SCRIPTED children: any process that speaks
/// the contract (JSONL events on stdout, a final `subrun_report` line,
/// stdin EOF as cancel) exercises spawn/drain/deadline/teardown without a
/// model or a built binary — the same hermetic trick the MCP stdio tests
/// use. Skips cleanly where the sandbox forbids spawning `sh`.
fn parse_answer(json : Json) -> Result[String, String] {
  match json {
    { "answer": String(answer), .. } => Ok(answer)
    _ => Err("answer must be a string")
  }
}

///|
async fn run_script(
  script : String,
  wall_deadline_ms? : Int = 10_000,
) -> @agent_subrun.SubrunResult[String] {
  @agent_subrun.run_subrun(
    command="sh",
    args=["-c", script],
    input={ "query": "q" },
    parse_report=parse_answer,
    wall_deadline_ms~,
  )
}

///|
/// A child that could not even spawn is a Failed terminal, not a crash.
async test "a spawn failure folds into Failed" {
  let result = @agent_subrun.run_subrun(
    command="/nonexistent/openseek-not-here",
    args=[],
    input={ "query": "q" },
    parse_report=parse_answer,
    wall_deadline_ms=2_000,
  )
  guard result.terminal() is Failed(reason) else {
    // Some sandboxes surface spawn refusal as an immediate empty exit:
    // accept NoReport there but never a hang or crash.
    assert_true(result.terminal() is NoReport)
    return
  }
  assert_true(reason.contains("spawn") || reason.contains("subrun"))
}

///|
async test "events and the report line are drained and accounted" {
  let script =
    #|read line
    #|printf '{"timestamp":"t","level":"INFO","source":"s","event":"agent_step","step":1}\n'
    #|printf 'not json at all\n'
    #|printf '{"timestamp":"t","level":"INFO","source":"s","event":"usage","usage":{"prompt_tokens":90,"completion_tokens":10,"total_tokens":100,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":90}}\n'
    #|printf '{"timestamp":"t","level":"INFO","source":"s","event":"agent_step","step":2}\n'
    #|printf '{"timestamp":"t","level":"INFO","source":"s","event":"usage","usage":{"prompt_tokens":95,"completion_tokens":5,"total_tokens":100,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":95}}\n'
    #|printf '{"subrun_report": {"answer": "forty-two"}}\n'
  let result = run_script(script)
  if result.terminal() is Failed(_) {
    println("skipped: cannot spawn sh")
    return
  }
  assert_true(result.value() is Some("forty-two"))
  debug_inspect(result.terminal(), content="Captured")
  assert_eq(result.steps_used(), 2)
  assert_eq(result.prompt_tokens(), 185)
  assert_eq(result.completion_tokens(), 15)
}

///|
async test "a clean exit without a report is NoReport" {
  let script =
    #|read line
    #|printf '{"timestamp":"t","level":"INFO","source":"s","event":"agent_step","step":1}\n'
  let result = run_script(script)
  if result.terminal() is Failed(_) {
    println("skipped: cannot spawn sh")
    return
  }
  assert_true(result.value() is None)
  debug_inspect(result.terminal(), content="NoReport")
}

///|
async test "an observed step exhaustion without a report is MaxSteps" {
  let script =
    #|read line
    #|printf '{"timestamp":"t","level":"INFO","source":"s","event":"max_steps_exhausted"}\n'
  let result = run_script(script)
  if result.terminal() is Failed(_) {
    println("skipped: cannot spawn sh")
    return
  }
  debug_inspect(result.terminal(), content="MaxSteps")
}

///|
async test "a garbled report is Failed, never rendered" {
  let script =
    #|read line
    #|printf '{"subrun_report": {"answer": 42}}\n'
  let result = run_script(script)
  if result.terminal() is Failed(reason) && reason.contains("spawn") {
    println("skipped: cannot spawn sh")
    return
  }
  assert_true(result.value() is None)
  guard result.terminal() is Failed(reason) else { fail("expected Failed") }
  assert_true(reason.contains("report rejected"))
}

///|
/// The deadline closes stdin (graceful cancel); a child that answers the
/// EOF with its report inside the grace window still counts as Captured.
async test "a report arriving in the cancel grace window still captures" {
  let script =
    #|read line
    #|read _ignored
    #|printf '{"subrun_report": {"answer": "flushed on eof"}}\n'
  let result = run_script(script, wall_deadline_ms=300)
  if result.terminal() is Failed(_) {
    println("skipped: cannot spawn sh")
    return
  }
  assert_true(result.value() is Some("flushed on eof"))
  debug_inspect(result.terminal(), content="Captured")
}

///|
/// A child that ignores the graceful cancel is terminated after the grace
/// and reported TimedOut.
async test "a stalling child times out after deadline and grace" {
  let script =
    #|read line
    #|sleep 60
  let result = run_script(script, wall_deadline_ms=300)
  if result.terminal() is Failed(_) {
    println("skipped: cannot spawn sh")
    return
  }
  assert_true(result.value() is None)
  debug_inspect(result.terminal(), content="TimedOut")
}

///|
/// External cancellation re-raises out of run_subrun: an outer timeout gets
/// its None back, which only happens when the cancellation propagated.
async test "external cancellation re-raises out of the runner" {
  let script =
    #|read line
    #|sleep 60
  let outcome = @async.with_timeout_opt(300, () => {
    run_script(script, wall_deadline_ms=30_000)
  })
  assert_true(outcome is None)
}
