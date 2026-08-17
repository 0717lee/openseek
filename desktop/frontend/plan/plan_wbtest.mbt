// What the meter, the fold summary, and the panel report — asserted against
// the pure helpers the views read, since the rendered markup is no longer
// reachable from `moon test` (rabbita 0.15.1 dropped the js `render_to_string`).

///|
fn steps_of(pairs : Array[(String, Status)]) -> Array[Step] {
  [
    for pair in pairs => { title: pair.0, status: pair.1 }
  ]
}

///|
test "the meter's fill is proportional and keeps the smallest share visible" {
  // Two of four completed is half the track.
  assert_eq(fill_width(2, 4), "--plan-progress-width: 50.0%")
  assert_eq(fill_width(4, 4), "--plan-progress-width: 100.0%")
  // `decode` tolerates plans well past the tool's own cap so a newer engine
  // still renders. A whole-percent width truncated one step of those to
  // nothing, drawing an active plan as an empty track; tenths keep the
  // smallest share a plan can have at 0.5%.
  assert_eq(fill_width(1, MAX_RENDERED_STEPS), "--plan-progress-width: 0.5%")
  assert_eq(fill_width(1, 150), "--plan-progress-width: 0.6%")
}

///|
test "the meter reads completion from the steps, not from their order" {
  let underway = steps_of([
    ("read the failing test", Completed),
    ("fix the parser", Completed),
    ("run moon test", InProgress),
    ("update the mbti", Pending),
  ])
  assert_eq(completed_count(underway), 2)
  assert_true(active_step(underway) is Some({ title: "run moon test", .. }))
  // Every step completed is what turns the fill green; a plan merely underway
  // must not read as finished.
  let finished = steps_of([("one", Completed), ("two", Completed)])
  assert_eq(completed_count(finished), finished.length())
  assert_true(active_step(finished) is None)
  // A plan with nothing in progress and nothing done is neither.
  let idle = steps_of([("one", Pending), ("two", Pending)])
  assert_eq(completed_count(idle), 0)
  assert_true(active_step(idle) is None)
}

///|
test "the one-line summary names the active step, or reports completion" {
  assert_eq(
    summary_line(steps_of([("one", Completed), ("two", InProgress)])),
    "plan 1/2 · two",
  )
  assert_eq(
    summary_line(steps_of([("one", Completed), ("two", Completed)])),
    "plan 2/2 · all steps done",
  )
  assert_eq(
    summary_line(steps_of([("one", Completed), ("two", Pending)])),
    "plan 1/2",
  )
}

///|
test "an unknown status keeps its own class rather than passing for pending" {
  assert_eq(status_class(Pending), "pending")
  assert_eq(status_class(InProgress), "in_progress")
  assert_eq(status_class(Completed), "completed")
  // The word itself is unvalidated model output; the row shows it as text.
  assert_eq(status_class(Other("blocked")), "other")
}
