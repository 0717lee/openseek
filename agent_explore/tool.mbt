///|
/// Step ceiling requested for one explore child. Exploration must stay
/// cheap: it reads and cites, it does not build.
pub let default_explore_max_steps : Int = 40

///|
/// Wall deadline for one explore child. A scout that has not answered in
/// five minutes is lost, not thorough.
pub let default_explore_deadline_ms : Int = 300_000

///|
/// Input caps: a question is a question, not a document.
pub let max_query_chars : Int = 2_000

///|
/// Hints cap, same reasoning as the query cap.
pub let max_hints_chars : Int = 2_000

///|
/// Tool definition for `explore`: delegate one self-contained question to a
/// read-only child agent and get back a bounded, cited answer.
///
/// The child runs on the `@agent_subrun` substrate with `read`,
/// `shell(read_only=true)` (its instrument for `moon ide doc` and friends),
/// and `submit_answer` — no edit tools, no nested subagent tools. Its
/// events are suppressed from the host stream; its cost is reserved from
/// the shared per-turn `SubrunBudget` BEFORE launch and reconciled after.
///
/// Failure is graceful by contract: a child that produces no report, times
/// out, or exhausts the budget returns an is_error result telling the
/// parent to fall back to reading directly — never a broken turn.
pub fn definition(
  api_key~ : String,
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
      execute(api_key, model, workspace_root, budget, api_url, arguments)
    }),
  )
}

///|
async fn execute(
  api_key : String,
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
  let result = @agent_subrun.run_subrun(
    {
      session_id: "explore",
      system_prompt: explore_system_prompt(),
      task: explore_task(query, hints),
      tools: captured => {
        @agent_tool.Tools([
          @read.definition(workspace_root~),
          @shell.definition(workspace_root~, read_only=true),
          submit_answer_tool(captured),
        ])
      },
      max_steps: granted_steps,
      wall_deadline_ms: Some(default_explore_deadline_ms),
    },
    api_key~,
    model~,
    api_url?,
    workspace_root~,
  )
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
