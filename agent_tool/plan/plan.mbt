///|
/// Tool definition for `plan`: records or replaces the agent's step-by-step
/// plan for the current task.
///
/// ## Arguments
/// - `steps` (array, required): the complete ordered plan. Each item is an
///   object with a non-blank string `title` and a `status` of `"pending"`,
///   `"active"`, or `"done"`. At most one step may be `active`, and the plan
///   is capped at `@decode.MAX_STEPS` steps.
///
/// ## Result
/// - `Respond` with a normalized checklist rendering of the plan, so the
///   current plan stays visible in the transcript where the model re-reads it
///   on every request, plus a one-line `brief` for the UI
///   (`plan 2/5 · fix the parser`).
/// - Malformed arguments produce `Respond(is_error=true)` naming the first
///   offending field so the model can correct the call.
///
/// The tool is deliberately stateless: every call passes the whole plan and
/// replaces the previous one, so plan state lives in the transcript itself and
/// there is nothing to reconcile, persist, or leak across turns.
pub fn definition() -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="plan",
    description=(
      #|Record or update your step-by-step plan for a multi-step task. Pass the complete list of steps on every call; it replaces the previous plan. Keep titles short and imperative, mark at most one step "active", and mark finished steps "done". Use it when a task needs several distinct steps, and update it as steps complete; skip it for trivial single-step tasks. Never write a plan as plain assistant text.
    ),
    schema=JsonSchema({
      "type": "object",
      "properties": {
        "steps": {
          "type": "array",
          "description": "The complete ordered plan; replaces the previous plan.",
          "items": {
            "type": "object",
            "properties": {
              "title": {
                "type": "string",
                "description": "Short imperative step title.",
              },
              "status": {
                "type": "string",
                "enum": ["pending", "active", "done"],
              },
            },
            "required": ["title", "status"],
          },
        },
      },
      "required": ["steps"],
    }),
    execute=Sync(execute),
  )
}

///|
fn execute(arguments : Json) -> @agent_tool.ToolAction {
  let input = @decode.decode(arguments) catch {
    error => {
      let message = @tool_error.failure_message("\{error}")
      return @agent_tool.ToolAction::respond(
        "error: plan requires \{message}",
        is_error=true,
      )
    }
  }
  render(input)
}

///|
/// Renders the decoded plan as a checklist: `[x]` done, `[>]` active, `[ ]`
/// pending. The content echoes the whole plan back into the transcript; the
/// brief compresses it to done-count plus the active step for UI display.
fn render(input : @decode.PlanInput) -> @agent_tool.ToolAction {
  let total = input.steps.length()
  let mut done = 0
  let mut active : String? = None
  let lines = StringBuilder::new()
  for step in input.steps {
    let marker = match step.status {
      Done => "[x]"
      Active => "[>]"
      Pending => "[ ]"
    }
    if step.status is Done {
      done += 1
    }
    if step.status is Active {
      active = Some(step.title)
    }
    lines.write_string("\{marker} \{step.title}\n")
  }
  let content = "Plan (\{done}/\{total} done)\n\{lines.to_string()}"
  let brief = match active {
    Some(title) => "plan \{done}/\{total} · \{@agent_tool.brief_line(title)}"
    None =>
      if done == total {
        "plan \{done}/\{total} · complete"
      } else {
        "plan \{done}/\{total}"
      }
  }
  @agent_tool.ToolAction::respond(content, brief~)
}

///|
/// Asserts that `execute(arguments)` responds successfully with `content` and
/// `brief`.
fn assert_plan(
  arguments : Json,
  content : String,
  brief : String,
) -> Unit raise {
  guard execute(arguments) is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_eq(output.content, content)
  guard output.brief is Some(actual_brief) else { fail("expected a brief") }
  assert_eq(actual_brief, brief)
}

///|
/// Asserts that `execute(arguments)` responds with an error containing
/// `expected`.
fn assert_plan_error(arguments : Json, expected : String) -> Unit raise {
  guard execute(arguments) is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(
    output.content.contains(expected),
    msg="\{output.content} should contain \{expected}",
  )
}

///|
test "plan renders a checklist with progress" {
  assert_plan(
    {
      "steps": [
        { "title": "read the failing test", "status": "done" },
        { "title": "fix the parser", "status": "active" },
        { "title": "run moon test", "status": "pending" },
      ],
    },
    (
      #|Plan (1/3 done)
      #|[x] read the failing test
      #|[>] fix the parser
      #|[ ] run moon test
      #|
    ),
    "plan 1/3 · fix the parser",
  )
}

///|
test "plan with everything done says complete" {
  assert_plan(
    {
      "steps": [
        { "title": "step one", "status": "done" },
        { "title": "step two", "status": "done" },
      ],
    },
    (
      #|Plan (2/2 done)
      #|[x] step one
      #|[x] step two
      #|
    ),
    "plan 2/2 · complete",
  )
}

///|
test "plan with no active step and work left omits the active title" {
  assert_plan(
    {
      "steps": [
        { "title": "step one", "status": "done" },
        { "title": "step two", "status": "pending" },
      ],
    },
    (
      #|Plan (1/2 done)
      #|[x] step one
      #|[ ] step two
      #|
    ),
    "plan 1/2",
  )
}

///|
test "plan rejects malformed arguments with a field-naming error" {
  assert_plan_error({}, "error: plan requires arguments.steps to be an array")
  assert_plan_error(
    { "steps": [] },
    "error: plan requires arguments.steps to be non-empty",
  )
  assert_plan_error(
    { "steps": [{ "title": "one", "status": "doing" }] },
    "arguments.steps[0].status to be one of pending|active|done",
  )
  assert_plan_error(
    {
      "steps": [
        { "title": "one", "status": "active" },
        { "title": "two", "status": "active" },
      ],
    },
    "at most one active step",
  )
}

///|
test "plan definition exposes the expected name and schema shape" {
  let definition = definition()
  assert_eq(definition.name, "plan")
  guard definition.schema is JsonSchema({ "required": ["steps"], .. }) else {
    fail("expected steps to be required")
  }
  guard definition.execute is Sync(_) else { fail("expected a Sync executor") }
}
