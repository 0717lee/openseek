///|
/// Step ceiling requested for one explore child. Generous enough that a
/// scout answering a real question never dies mid-search (a truncated child
/// burns its whole allowance and returns nothing); the answer-early rule in
/// the prompt, not this ceiling, is what keeps exploration cheap.
pub let default_explore_max_steps : Int = 100

///|
/// Wall deadline for one explore child. A scout that has not answered in
/// ten minutes is lost, not thorough. Sized with the step ceiling: at the
/// few seconds per step observed in dogfood runs, a child must be able to
/// spend its full step allowance without dying by the clock instead.
pub let default_explore_deadline_ms : Int = 600_000

///|
/// Input caps: a question is a question, not a document.
pub let max_query_chars : Int = 2_000

///|
/// Hints cap, same reasoning as the query cap.
pub let max_hints_chars : Int = 2_000

///|
/// Tool definition for `explore`: delegate one self-contained question to a
/// read-only scout subagent and get back a bounded, cited answer.
///
/// The scout runs in a DEDICATED CHILD PROCESS: `self_exe` (the parent's
/// own executable — never PATH, so parent and child are the same binary and
/// the report's derived JSON codecs cannot drift) invoked as
/// `subrun explore`. The child's toolset is `read`,
/// `shell(read_only=true)` (its instrument for `moon ide doc` and friends),
/// and `submit_answer` — no edit tools, no nested subagent tools. The
/// child inherits the environment for its API key; model and endpoint ride
/// argv. Its cost is reserved from the shared per-turn `SubrunBudget`
/// BEFORE launch and reconciled after from the observed event stream.
///
/// Failure is graceful by contract: a child that produces no report, times
/// out, or exhausts the budget returns an is_error result telling the
/// parent to fall back to reading directly — never a broken turn.
pub fn definition(
  self_exe~ : String,
  model~ : @deepseek.Model,
  workspace_root~ : String,
  budget~ : @agent_subrun.SubrunBudget,
  api_url? : String,
) -> @agent_tool.AgentToolDefinition {
  @agent_tool.AgentToolDefinition(
    name="explore",
    description="Delegate ONE self-contained question to a read-only scout subagent and get a bounded, cited answer. Use it when answering would mean reading MANY files or discovering MoonBit APIs you are not sure about — (a) workspace questions (\"where is X handled, how does Y flow\") where you want the conclusion, not the file dumps; (b) MoonBit stdlib/dependency API discovery (what a package offers, exact signatures) — prefer this over guessing APIs from memory. For a single direct lookup you can do in one step (one `moon ide doc` query, one file read), do it yourself instead. The scout cannot edit anything and returns file:line citations you can verify.",
    schema=JsonSchema({
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "The one question to answer, self-contained (the scout sees nothing else of this conversation).",
        },
        "hints": {
          "type": "string",
          "description": "Optional pointers: paths, package names, or symbols the scout should start from.",
        },
      },
      "required": ["query"],
    }),
    execute=Async(arguments => {
      execute(self_exe, model, workspace_root, budget, api_url, arguments)
    }),
  )
}

///|
async fn execute(
  self_exe : String,
  model : @deepseek.Model,
  workspace_root : String,
  budget : @agent_subrun.SubrunBudget,
  api_url : String?,
  arguments : Json,
) -> @agent_tool.ToolAction {
  guard arguments is { "query": String(query), .. } && query.trim() != "" else {
    return @agent_tool.ToolAction::respond(
      "error: explore requires a non-empty string `query`",
      is_error=true,
    )
  }
  guard query.length() <= max_query_chars else {
    return @agent_tool.ToolAction::respond(
      "error: explore query exceeds \{max_query_chars} chars — ask one self-contained question",
      is_error=true,
    )
  }
  let hints : String? = match arguments {
    { "hints": String(hints), .. } if hints.trim() != "" => Some(hints)
    _ => None
  }
  guard !(hints is Some(h) && h.length() > max_hints_chars) else {
    return @agent_tool.ToolAction::respond(
      "error: explore hints exceed \{max_hints_chars} chars",
      is_error=true,
    )
  }
  // Reserve BEFORE launch: the child's effective ceiling comes out of the
  // turn's shared allowance, so one child cannot overshoot what remains.
  guard budget.reserve(default_explore_max_steps) is Some(granted_steps) else {
    return @agent_tool.ToolAction::respond(
      "explore budget exhausted for this turn — answer from what you already know, or read the files directly.",
      is_error=true,
      brief="explore (budget exhausted)",
    )
  }
  // API key rides the inherited environment, never argv (visible in ps).
  let args = [
    "subrun",
    "explore",
    "--model",
    "\{model}",
    "--max-steps",
    "\{granted_steps}",
  ]
  if api_url is Some(url) {
    args.push("--api-url")
    args.push(url)
  }
  let input : Json = match hints {
    Some(hints) => { "query": query, "hints": hints }
    None => { "query": query }
  }
  let result = @agent_subrun.run_subrun(
    command=self_exe,
    args~,
    input~,
    parse_report=parse_child_report,
    wall_deadline_ms=default_explore_deadline_ms,
    kind="explore",
    label=@agent_tool.brief_line(query, limit=48),
    cwd=workspace_root,
  )
  // On external cancellation run_subrun re-raises before this line: the
  // reservation stays debited for the rest of the turn — deliberately
  // conservative, since the dead child's true spend is unknown.
  budget.reconcile(reserved=granted_steps, used=result.steps_used())
  match result.value() {
    Some(report) =>
      @agent_tool.ToolAction::respond(
        render_report(report),
        brief="explore (\{report.citations.length()} citation(s), \{result.steps_used()} step(s))",
      )
    None =>
      @agent_tool.ToolAction::respond(
        "explore produced no report (\{to_repr(result.terminal())}) — fall back to reading directly.",
        is_error=true,
        brief="explore (no report)",
      )
  }
}

///|
/// Parse-and-validate the child's report line: the same contract
/// `submit_answer` enforced in the child, re-checked at the trust boundary —
/// the line is same-binary JSON, but the parent still refuses an oversized
/// or malformed report rather than rendering it.
fn parse_child_report(json : Json) -> Result[ExploreReport, String] {
  match ExploreReport::parse(json) {
    Err(msg) => Err(msg)
    Ok(report) => {
      let problems = report.validate()
      if problems.length() > 0 {
        Err(problems.join("; "))
      } else {
        Ok(report)
      }
    }
  }
}

///|
/// The CHILD-side entry for `openseek subrun explore`: decode the input
/// line, run the scout kind in this process, and return the report (the
/// dispatch prints it as the final `subrun_report` line). `None` when the
/// child finished without a valid submission or the input is malformed.
pub async fn run_child(
  input : Json,
  api_key~ : String,
  model~ : @deepseek.Model,
  max_steps~ : Int,
  thinking? : @deepseek.ThinkingMode = Max,
  api_url? : String,
  workspace_root? : String = ".",
) -> ExploreReport? {
  guard input is { "query": String(query), .. } && query.trim() != "" else {
    return None
  }
  let hints : String? = match input {
    { "hints": String(hints), .. } if hints.trim() != "" => Some(hints)
    _ => None
  }
  @agent_subrun.execute_kind(
    session_id="explore",
    system_prompt=explore_system_prompt(),
    task=explore_task(query, hints),
    tools=captured => {
      @agent_tool.Tools([
        @read.definition(workspace_root~),
        @shell.definition(workspace_root~, read_only=true),
        submit_answer_tool(captured),
      ])
    },
    max_steps~,
    api_key~,
    model~,
    thinking~,
    api_url?,
    workspace_root~,
  )
}

///|
/// Render the bounded report as the tool result. Every field was capped at
/// submission, so the rendered whole stays far below the loop's 60K clamp.
fn render_report(report : ExploreReport) -> String {
  let out = StringBuilder()
  out <+ "\{report.answer}"
  if report.citations.length() > 0 {
    out <+ "\n\nCitations:"
    for citation in report.citations {
      let line = match citation.line {
        Some(line) => ":\{line}"
        None => ""
      }
      let note = match citation.note {
        Some(note) => " — \{note}"
        None => ""
      }
      out <+ "\n- \{citation.file}\{line}\{note}"
    }
  }
  if report.unresolved is Some(unresolved) {
    out <+ "\n\nUnresolved: \{unresolved}"
  }
  out.to_string()
}

///|
test "render_report shows answer, citations, and unresolved" {
  let rendered = render_report(sample_report())
  assert_true(rendered.contains("Buffer::to_bytes"))
  assert_true(rendered.contains("- protocol/event.mbt:14 — Event enum"))
  assert_true(rendered.contains("- moonbitlang/core/buffer"))
  assert_true(rendered.contains("Unresolved: did not check the js backend"))
}

///|
test "parse_child_report re-checks the contract at the trust boundary" {
  guard parse_child_report(sample_report().to_json()) is Ok(_) else {
    fail("expected a valid report")
  }
  guard parse_child_report({ "answer": "no version" }) is Err(_) else {
    fail("expected a parse rejection")
  }
  guard parse_child_report({ ..sample_report(), answer: "" }.to_json())
    is Err(_) else {
    fail("expected a validation rejection")
  }
}
