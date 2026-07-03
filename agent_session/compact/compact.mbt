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
async fn generate_compaction_summary(
  api_key~ : String,
  model~ : @deepseek.Model,
  session : @agent_session.Session,
  api_url? : String,
) -> (String, @agent_session.TurnUsage) {
  let client = @client.Client(api_key~, model~, api_url?, thinking=No)
  let response = client.chat(compaction_messages(session))
  let summary = response.content.trim().to_owned()
  if summary.is_empty() {
    fail("compaction summary was empty")
  }
  (
    summary,
    TurnUsage(
      prompt_tokens=response.usage.prompt_tokens,
      completion_tokens=response.usage.completion_tokens,
    ),
  )
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
async fn append_usage_event(
  store? : @store.SessionStore,
  session : @agent_session.Session,
  usage : @agent_session.TurnUsage,
) -> @agent_session.Session {
  if store is Some(store) {
    store.append(session, Usage(usage))
  } else {
    session.append(Usage(usage), unix_ms=@env.now().reinterpret_as_int64())
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
  let (summary, usage) = generate_compaction_summary(
    api_key~,
    model~,
    session,
    api_url?,
  )
  // The summarizer call is real model spend: record it durably so budget
  // accounting (a fold over Usage events) cannot undercount compaction.
  // Appended before the Summary so the summary stays the range's terminator.
  let session = append_usage_event(store?, session, usage)
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
