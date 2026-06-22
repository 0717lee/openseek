///|
async test "compaction rejects empty sessions before summary generation" {
  try
    @compact.compact_session(
      Session(SessionId("empty"), system_prompt="system"),
      api_key="",
      model=V4Flash,
    )
  catch {
    error => assert_true("\{error}".contains("at least one event"))
  } noraise {
    _ => fail("accepted empty session")
  }
}
