///|
/// Lifecycle status of one plan step.
pub enum PlanStatus {
  Pending
  Active
  Done
} derive(Debug, Eq)

///|
/// One step of the agent's plan: a short imperative title plus its status.
pub struct PlanStep {
  title : String
  status : PlanStatus
} derive(Debug)

///|
/// Decoded arguments of the `plan` tool: the complete, ordered list of steps.
/// Every call replaces the previous plan, so the array is the whole plan.
pub struct PlanInput {
  steps : Array[PlanStep]
} derive(Debug)

///|
/// Upper bound on plan length. More steps than this is a sign the model is
/// planning at the wrong granularity, so decoding rejects it instead of
/// letting the plan crowd out real work.
pub const MAX_STEPS : Int = 20

///|
/// Decode `plan` tool-call arguments.
///
/// Strict by design, unlike `finish`: a malformed plan is fed back to the
/// model as an error naming the first offending field so the next call can
/// correct it. Rules: `steps` is a required non-empty array of at most
/// `MAX_STEPS` objects, each with a non-blank string `title` and a `status`
/// of `"pending"`, `"active"`, or `"done"`; at most one step may be active.
pub fn decode(arguments : Json) -> PlanInput raise {
  guard arguments is { "steps": Array(items), .. } else {
    fail("arguments.steps to be an array of steps")
  }
  if items.length() == 0 {
    fail("arguments.steps to be non-empty")
  }
  if items.length() > MAX_STEPS {
    fail(
      "arguments.steps to have at most \{MAX_STEPS} steps, got \{items.length()}",
    )
  }
  let steps : Array[PlanStep] = []
  let mut active_count = 0
  for index, item in items {
    let step = decode_step(index, item)
    if step.status is Active {
      active_count += 1
      if active_count > 1 {
        fail("arguments.steps to contain at most one active step")
      }
    }
    steps.push(step)
  }
  { steps, }
}

///|
fn decode_step(index : Int, item : Json) -> PlanStep raise {
  guard item is Object(_) else {
    fail("arguments.steps[\{index}] to be an object")
  }
  guard item is { "title": String(title), .. } else {
    fail("arguments.steps[\{index}].title to be a string")
  }
  if is_blank(title) {
    fail("arguments.steps[\{index}].title to be non-blank")
  }
  guard item is { "status": String(status_text), .. } else {
    fail("arguments.steps[\{index}].status to be a string")
  }
  let status = match status_text {
    "pending" => PlanStatus::Pending
    "active" => Active
    "done" => Done
    other =>
      fail(
        "arguments.steps[\{index}].status to be one of pending|active|done, got \"\{other}\"",
      )
  }
  { title, status }
}

///|
fn is_blank(text : String) -> Bool {
  for ch in text {
    if ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r' {
      return false
    }
  }
  true
}
