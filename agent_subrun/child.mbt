///|
/// The CHILD-side executor: run one bounded agent turn in THIS process with a
/// restricted toolset and a structured value captured through a submit-style
/// control tool. Three callers share it: the `openseek subrun <kind>` child
/// mode (where this process IS the sub-run), the standalone review CLI (its
/// own process by construction), and kind-internals unit tests (which get
/// the full lifecycle — capture, reject-retry, ceiling salvage — against a
/// mock endpoint without spawning anything).
///
/// Parent-side concerns deliberately absent: the wall deadline, cost
/// accounting, and terminal classification live in the process runner
/// (`run_subrun`), which observes this process from outside through its
/// event stream and exit. Events go to the process log as always — in a
/// child process, stdout IS the report channel the parent reads.
pub async fn[T] execute_kind(
  session_id~ : String,
  system_prompt~ : String,
  task~ : String,
  tools~ : (Ref[T?]) -> @agent_tool.Tools raise,
  max_steps~ : Int,
  api_key~ : String,
  model~ : @deepseek.Model,
  thinking? : @deepseek.ThinkingMode = Max,
  api_url? : String,
  workspace_root? : String = ".",
) -> T? {
  let captured : Ref[T?] = { val: None }
  let tools = tools(captured)
  let session = @agent_session.Session(
    @agent_session.SessionId(session_id),
    system_prompt~,
  )
  let _ : @agent_session.Session = @async.with_task_group() <| group => {
    @agent.run_turn_in_scope(
      runtime=@agent_runtime.AgentRuntime(workspace_root~),
      scope=@agent_runtime.AgentTaskScope(group),
      api_key~,
      model~,
      session~,
      task~,
      append_item=(session, item) => session.append(item),
      max_steps~,
      thinking~,
      api_url?,
      tools~,
    )
  }
  captured.val
}

///|
/// The distinguished final line a child writes after its turn: the typed
/// report. Parent and child are the same binary, so the derived
/// `to_json`/`from_json` pair on the report type cannot drift — this line is
/// a typed channel despite the process boundary.
pub fn report_line(report : Json) -> String {
  ({ "subrun_report": report } : Json).stringify()
}

///|
/// The report a parent extracts from one child stdout line, or `None` for
/// every other line (protocol events, stray output).
pub fn parse_report_line(line : Json) -> Json? {
  match line {
    { "subrun_report": report, .. } => Some(report)
    _ => None
  }
}

///|
test "report lines round-trip and ordinary lines are not reports" {
  let report : Json = { "answer": "x" }
  let line = @json.parse(report_line(report))
  assert_eq(parse_report_line(line), Some(report))
  assert_eq(parse_report_line({ "event": "agent_step", "step": 1 }), None)
}
