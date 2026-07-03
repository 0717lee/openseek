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
  objective? : String,
  unread_opening~ : Bool,
) -> Array[@deepseek.ChatMessage] {
  let mut prompt = match objective {
    Some(objective) => {
      let prompt =
        $|\{CompactionUserPrompt}
        $|
        $|An active session goal is in progress. Preserve everything needed to
        $|keep pursuing this exact objective:
        $|<objective>
        $|\{objective}
        $|</objective>
      prompt
    }
    None => CompactionUserPrompt
  }
  if unread_opening {
    prompt = (
      $|\{prompt}
      $|
      $|The final user-role message before this one is a fresh instruction the
      $|assistant has not acted on yet. It will be re-delivered verbatim right
      $|after your summary: do not summarize, paraphrase, or restate any part
      $|of it.
    )
  }
  session.chat_messages()..push(ChatMessage(User, content=prompt))
}

///|
/// Generate a checkpoint summary through the model without appending
/// anything: the caller owns durability of both the summary and the
/// summarizer's own token spend. `objective` (an active goal's objective)
/// makes the summary preserve goal-relevant state explicitly.
///
/// The request streams with a silent handler so it rides the client's
/// idle-timeout protection — the same mode the agent loop uses.
pub async fn generate_summary(
  api_key~ : String,
  model~ : @deepseek.Model,
  session : @agent_session.Session,
  api_url? : String,
  objective? : String,
  unread_opening? : Bool = false,
) -> (String, @agent_session.TurnUsage) {
  let client = @client.Client(api_key~, model~, api_url?, thinking=No)
  let response = client.chat(
    compaction_messages(session, objective?, unread_opening~),
    stream=StreamHandler(on_content_delta=_ => ()),
  )
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
  let (summary, usage) = generate_summary(api_key~, model~, session, api_url?)
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
