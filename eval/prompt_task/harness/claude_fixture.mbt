///|
priv enum ClaudeFixturePart {
  FixtureUser(String)
  FixtureAssistant(String, Array[@deepseek.ToolCall])
  FixtureTool(String, String, String, Bool)
}

///|
async fn seed_session_fixture(
  fixture : SessionFixtureSpec,
  session_id~ : String,
  workspace~ : String,
  system_prompt~ : String,
) -> Unit {
  guard fixture.format == "claude-jsonl" else {
    fail("unsupported session fixture format: \{fixture.format}")
  }
  let session = claude_jsonl_fixture_session(
    fixture,
    session_id~,
    workspace~,
    system_prompt~,
  )
  let store = @store.SessionStore(workspace + "/.openseek")
  store.create(session)
}

///|
async fn claude_jsonl_fixture_session(
  fixture : SessionFixtureSpec,
  session_id~ : String,
  workspace~ : String,
  system_prompt~ : String,
) -> @agent_session.Session {
  let text = @fs.read_file(fixture.path).text()
  let tool_names : Map[String, String] = {}
  let mut session = @agent_session.Session(
    SessionId(session_id),
    system_prompt~,
  )
  let needle = fixture_needle_text(fixture, workspace)
  let mut inserted_needle = false
  let mut approx_bytes = 0
  let threshold = fixture.target_bytes / 2
  let mut done = false
  for line in text.split("\n") {
    if done {
      continue
    }
    let trimmed = line.trim()
    if trimmed.is_empty() {
      continue
    }
    let parts = claude_fixture_parts(@json.parse(trimmed), tool_names)
    for part in parts {
      if done {
        continue
      }
      match part {
        FixtureTool(id, name, content, is_error) => {
          let content = if !inserted_needle && approx_bytes >= threshold {
            inserted_needle = true
            content + "\n\n" + needle
          } else {
            content
          }
          session = session.append(
            Tool(
              ToolResult(tool_call_id=id, tool_name=name, content~, is_error~),
            ),
          )
          approx_bytes += content.length()
        }
        _ => {
          session = append_fixture_part(session, part)
          approx_bytes += fixture_part_bytes(part)
        }
      }
      if approx_bytes >= fixture.target_bytes {
        done = true
      }
    }
  }
  if !inserted_needle {
    session = append_synthetic_needle(session, needle)
  }
  session
}

///|
fn append_fixture_part(
  session : @agent_session.Session,
  part : ClaudeFixturePart,
) -> @agent_session.Session {
  match part {
    FixtureUser(content) => session.append(User(UserMessage(content)))
    FixtureAssistant(content, calls) =>
      session.append(Assistant(AssistantMessage(content, tool_calls=calls)))
    FixtureTool(id, name, content, is_error) =>
      session.append(
        Tool(ToolResult(tool_call_id=id, tool_name=name, content~, is_error~)),
      )
  }
}

///|
fn fixture_part_bytes(part : ClaudeFixturePart) -> Int {
  match part {
    FixtureUser(content) => content.length()
    FixtureAssistant(content, calls) => {
      let mut size = content.length()
      for call in calls {
        size += call.name.length() + call.arguments.length()
      }
      size
    }
    FixtureTool(_, _, content, _) => content.length()
  }
}

///|
fn fixture_needle_text(
  fixture : SessionFixtureSpec,
  workspace : String,
) -> String {
  let answer_file = replace_workspace(fixture.answer_file, workspace)
  if answer_file == "" {
    (
      $|BENCHMARK_DECISION_ID: \{fixture.needle_id}
      $|BENCHMARK_REQUIRED_FIX: \{fixture.needle_text}
    )
  } else {
    (
      $|BENCHMARK_DECISION_ID: \{fixture.needle_id}
      $|BENCHMARK_REQUIRED_FIX: \{fixture.needle_text}
      $|BENCHMARK_ANSWER_FILE: \{answer_file}
    )
  }
}

///|
fn append_synthetic_needle(
  session : @agent_session.Session,
  needle : String,
) -> @agent_session.Session {
  let call_id = "fixture-needle-read"
  let call : @deepseek.ToolCall = ToolCall(
    id=call_id,
    name="Read",
    arguments=({ "file_path": "fixture/needle.md" } : Json).stringify(),
  )
  session
  .append(Assistant(AssistantMessage("", tool_calls=[call])))
  .append(
    Tool(
      ToolResult(
        tool_call_id=call_id,
        tool_name="Read",
        content=needle,
        brief="fixture needle",
      ),
    ),
  )
}

///|
fn claude_fixture_parts(
  json : Json,
  tool_names : Map[String, String],
) -> Array[ClaudeFixturePart] raise {
  let fields = object_fields(json, "claude jsonl line")
  let message_fields = match fields.get("message") {
    Some(Object(fields)) => fields
    _ => return []
  }
  let role = string_field_default(
    message_fields,
    "role",
    string_field_default(fields, "type", ""),
  )
  let content = match message_fields.get("content") {
    Some(content) => content
    None => return []
  }
  match role {
    "assistant" => claude_assistant_parts(content, tool_names)
    "user" => claude_user_parts(content, tool_names)
    _ => []
  }
}

///|
fn claude_assistant_parts(
  content : Json,
  tool_names : Map[String, String],
) -> Array[ClaudeFixturePart] raise {
  match content {
    String(text) =>
      if text.trim().is_empty() {
        []
      } else {
        [FixtureAssistant(text, [])]
      }
    Array(blocks) => {
      let texts : Array[String] = []
      let calls : Array[@deepseek.ToolCall] = []
      for block in blocks {
        match block {
          Object(fields) =>
            match string_field_default(fields, "type", "") {
              "text" =>
                push_non_empty(texts, string_field_default(fields, "text", ""))
              "tool_use" => {
                let id = string_field(fields, "id")
                let name = string_field(fields, "name")
                let arguments = match fields.get("input") {
                  Some(input) => input.stringify()
                  None => "{}"
                }
                tool_names[id] = name
                calls.push(ToolCall(id~, name~, arguments~))
              }
              _ => ()
            }
          String(text) => push_non_empty(texts, text)
          _ => ()
        }
      }
      let text = texts.join("\n\n")
      if text == "" && calls.length() == 0 {
        []
      } else {
        [FixtureAssistant(text, calls)]
      }
    }
    _ => []
  }
}

///|
fn claude_user_parts(
  content : Json,
  tool_names : Map[String, String],
) -> Array[ClaudeFixturePart] raise {
  match content {
    String(text) =>
      if text.trim().is_empty() {
        []
      } else {
        [FixtureUser(text)]
      }
    Array(blocks) => {
      let texts : Array[String] = []
      let tools : Array[ClaudeFixturePart] = []
      for block in blocks {
        match block {
          Object(fields) =>
            match string_field_default(fields, "type", "") {
              "text" =>
                push_non_empty(texts, string_field_default(fields, "text", ""))
              "tool_result" => {
                let id = string_field(fields, "tool_use_id")
                let name = match tool_names.get(id) {
                  Some(name) => name
                  None => "unknown"
                }
                let result_content = match fields.get("content") {
                  Some(value) => claude_content_text(value)
                  None => ""
                }
                tools.push(
                  FixtureTool(
                    id,
                    name,
                    result_content,
                    bool_field_default(fields, "is_error", false),
                  ),
                )
              }
              _ => ()
            }
          String(text) => push_non_empty(texts, text)
          _ => ()
        }
      }
      let parts = tools
      let text = texts.join("\n\n")
      if text != "" {
        parts.push(FixtureUser(text))
      }
      parts
    }
    _ => []
  }
}

///|
fn claude_content_text(content : Json) -> String {
  match content {
    String(text) => text
    Array(items) => {
      let texts : Array[String] = []
      for item in items {
        push_non_empty(texts, claude_content_text(item))
      }
      texts.join("\n\n")
    }
    Object(fields) =>
      match fields.get("text") {
        Some(String(text)) => text
        _ => content.stringify()
      }
    _ => content.stringify()
  }
}

///|
fn push_non_empty(items : Array[String], value : String) -> Unit {
  if !value.trim().is_empty() {
    items.push(value)
  }
}
