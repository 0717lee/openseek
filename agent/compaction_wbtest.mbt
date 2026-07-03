///|
/// A partial summary — e.g. from `sessions compact --from/--to` — can be
/// appended after a high-token usage it does not cover. That usage still
/// describes the prompt a resumed run will replay, so the auto-compaction seed
/// must survive it and reset only when a summary actually covers the tracked
/// usage.
test "last_recorded_prompt_tokens keeps a usage a partial summary does not cover" {
  let base = @agent_session.Session(
    SessionId("compaction-seed"),
    system_prompt="system",
  )
  let filler = base.append(
    Usage(TurnUsage(prompt_tokens=100, completion_tokens=1)),
  )
  let high = filler.append(
    Usage(TurnUsage(prompt_tokens=300_000, completion_tokens=10)),
  )
  let usage_seq = high.last_sequence()

  // A summary over an earlier range that leaves the high usage uncovered: the
  // seed survives, so a resumed run still auto-compacts before its first call.
  let uncovered = high.append(
    Summary(
      SessionSummary(content="x", from_sequence=1, to_sequence=usage_seq - 1),
    ),
  )
  assert_eq(last_recorded_prompt_tokens(uncovered), 300_000)

  // A summary that covers the high usage resets the seed to zero.
  let covered = high.append(
    Summary(SessionSummary(content="x", from_sequence=1, to_sequence=usage_seq)),
  )
  assert_eq(last_recorded_prompt_tokens(covered), 0)
}
