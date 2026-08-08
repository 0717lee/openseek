///|
/// `split_child_session_id` against the ids the runner actually derives —
/// the inverse of `<parent>-sr-<N>`, checked on both the ids that are child
/// sessions and the ones that only look like it.
test "splits a child session id into parent and ordinal" {
  assert_eq(
    @openseek_protocol.split_child_session_id("run-sr-3"),
    Some(("run", 3)),
  )
  assert_eq(
    @openseek_protocol.split_child_session_id("run-sr-12"),
    Some(("run", 12)),
  )
  // Real desktop ids carry dashes and digits of their own; only the trailing
  // `-sr-<N>` names a sub-run.
  assert_eq(
    @openseek_protocol.split_child_session_id(
      "desktop-20260807-174209-535-023270351-sr-2",
    ),
    Some(("desktop-20260807-174209-535-023270351", 2)),
  )
}

///|
test "an ordinary session id has no parent" {
  let cases = [
    // No marker at all, and a parent id that merely contains the digits.
    "run", "run-3", "sr-1",
    // The marker without a well-formed ordinal.
     "run-sr-", "run-sr-x", "run-sr-1x", "run-sr-x1",
    // Bounded: ten digits is not an ordinal, so the id stays ordinary
    // rather than folding under a parent.
     "run-sr-9999999999",
    // A bare marker has no parent to fold under.
     "-sr-1",
  ]
  // Collecting the offenders rather than asserting per id: a failure names
  // the ids that split when they should not have.
  assert_eq(
    cases.filter(id => @openseek_protocol.split_child_session_id(id) is Some(_)),
    [],
  )
}

///|
test "a grandchild belongs to the innermost parent" {
  assert_eq(
    @openseek_protocol.split_child_session_id("run-sr-1-sr-2"),
    Some(("run-sr-1", 2)),
  )
}
