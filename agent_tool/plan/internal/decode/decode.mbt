///|
/// Lifecycle status of one plan step. Named after the update_plan vocabulary
/// (`pending`/`in_progress`/`completed`) that coding models already know;
/// deliberately distinct from any goal-level lifecycle status.
pub enum PlanStatus {
  Pending
  InProgress
  Completed
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
/// Upper bound on a step title, in chars. Titles are echoed verbatim into the
/// model-visible checklist, so oversized titles crowd out context.
pub const MAX_TITLE_CHARS : Int = 120

///|
/// Decode `plan` tool-call arguments.
///
/// Strict by design, unlike `finish`: a malformed plan is fed back to the
/// model as an error naming the first offending field so the next call can
/// correct it. Rules: `steps` is a required non-empty array of at most
/// `MAX_STEPS` objects, each with a `status` of `"pending"`, `"in_progress"`,
/// or `"completed"` (at most one step in progress) and a `title` that is
/// non-blank, a single line, and at most `MAX_TITLE_CHARS` chars after
/// trimming. Titles are trimmed because they are echoed verbatim into the
/// checklist the model re-reads, where embedded newlines could forge extra
/// checklist rows.
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
  let mut in_progress_count = 0
  for index, item in items {
    let step = decode_step(index, item)
    if step.status is InProgress {
      in_progress_count += 1
      if in_progress_count > 1 {
        fail("arguments.steps to contain at most one in_progress step")
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
  guard item is { "title": String(raw_title), .. } else {
    fail("arguments.steps[\{index}].title to be a string")
  }
  let title = normalize_title(index, raw_title)
  guard item is { "status": String(status_text), .. } else {
    fail("arguments.steps[\{index}].status to be a string")
  }
  let status = match status_text {
    "pending" => PlanStatus::Pending
    "in_progress" => InProgress
    "completed" => Completed
    other =>
      fail(
        "arguments.steps[\{index}].status to be one of pending|in_progress|completed, got \"\{other}\"",
      )
  }
  { title, status }
}

///|
/// Trims surrounding whitespace and enforces the single-line and length
/// rules. The trimmed title is what gets rendered, so a title that only
/// differs by surrounding whitespace round-trips to the same checklist.
fn normalize_title(index : Int, raw_title : String) -> String raise {
  let title = trim_whitespace(raw_title)
  if title.length() == 0 {
    fail("arguments.steps[\{index}].title to be non-blank")
  }
  for ch in title {
    if ch == '\n' || ch == '\r' {
      fail("arguments.steps[\{index}].title to be a single line")
    }
  }
  if title.length() > MAX_TITLE_CHARS {
    fail(
      "arguments.steps[\{index}].title to be at most \{MAX_TITLE_CHARS} chars, got \{title.length()}",
    )
  }
  title
}

///|
fn trim_whitespace(text : String) -> String {
  fn is_ws(unit : UInt16) -> Bool {
    unit == ' ' || unit == '\t' || unit == '\n' || unit == '\r'
  }

  let mut start = 0
  let mut stop = text.length()
  while start < stop && is_ws(text[start]) {
    start += 1
  }
  while stop > start && is_ws(text[stop - 1]) {
    stop -= 1
  }
  text[start:stop].to_owned()
}
