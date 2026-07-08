///|
const CompactionUserPrompt : String =
  #|You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff
  #|summary for another model that will resume this task.
  #|
  #|Summarize the entire conversation context above. Include:
  #|- Current goal and user intent
  #|- Key decisions and constraints
  #|- Important files, commands, tool results, and implementation details
  #|- What remains to be done, with concrete next steps
  #|
  #|Be concise, structured, and focused on helping the next model continue
  #|without losing context. Return only the summary text.

///|
fn compaction_messages(
  session : @agent_session.Session,
) -> Array[@deepseek.ChatMessage] {
  session.chat_messages()..push(ChatMessage(User, content=CompactionUserPrompt))
}

///|
/// Generate a handoff summary of the session's projected history through one
/// model call, failing when the endpoint returns an empty summary. Pass a
/// `thinking=No` client where the model honors the control (Kimi models
/// ignore it): a checkpoint summary needs no reasoning budget.
pub async fn generate_compaction_summary(
  client~ : @client.Client,
  session : @agent_session.Session,
) -> String {
  let response = client.chat(compaction_messages(session))
  let summary = response.content.trim().to_owned()
  if summary.is_empty() {
    fail("compaction summary was empty")
  }
  summary
}

///|
async fn append_compaction_summary(
  store? : @store.SessionStore,
  session : @agent_session.Session,
  summary~ : String,
  from_sequence~ : Int,
  to_sequence~ : Int,
) -> @agent_session.Session {
  if store is Some(store) {
    store.compact(session, content=summary, from_sequence~, to_sequence~)
  } else {
    session.compact(
      content=summary,
      from_sequence~,
      to_sequence~,
      unix_ms=@env.now().reinterpret_as_int64(),
    )
  }
}

///|
/// Summarize the current session through the model endpoint and append the
/// resulting checkpoint summary to the session history.
pub async fn compact_session(
  store? : @store.SessionStore,
  session : @agent_session.Session,
  api_key~ : String,
  model~ : @deepseek.Model,
  api_url? : String,
) -> @agent_session.Session {
  let from_sequence = 1
  let to_sequence = session.last_sequence()
  if to_sequence <= 0 {
    fail("session compaction requires at least one event")
  }
  @xlog.info() <?
    {
      "event": "compaction_started",
      "from_sequence": from_sequence,
      "to_sequence": to_sequence,
    }
  let client = @client.Client(api_key~, model~, api_url?, thinking=No)
  let summary = generate_compaction_summary(client~, session)
  let next = append_compaction_summary(
    store?,
    session,
    summary~,
    from_sequence~,
    to_sequence~,
  )
  @xlog.info() <?
    {
      "event": "compaction_finished",
      "from_sequence": from_sequence,
      "to_sequence": to_sequence,
      "summary": summary,
    }
  next
}
