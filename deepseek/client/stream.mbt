///|
priv struct StreamToolCall {
  mut id : String
  mut name : String
  arguments : StringBuilder
}

///|
fn StreamToolCall::StreamToolCall() -> StreamToolCall {
  { id: "", name: "", arguments: StringBuilder::new() }
}

///|
fn StreamToolCall::to_json(self : StreamToolCall) -> Json {
  {
    "id": self.id,
    "type": "function",
    "function": { "name": self.name, "arguments": self.arguments.to_string() },
  }
}

///|
priv struct StreamAccumulator {
  content : StringBuilder
  reasoning_content : StringBuilder
  tool_calls : Array[StreamToolCall]
  mut usage : Json?
}

///|
fn StreamAccumulator::StreamAccumulator() -> StreamAccumulator {
  {
    content: StringBuilder::new(),
    reasoning_content: StringBuilder::new(),
    tool_calls: [],
    usage: None,
  }
}

///|
fn StreamAccumulator::ensure_tool_call(
  self : StreamAccumulator,
  index : Int,
) -> StreamToolCall {
  while self.tool_calls.length() <= index {
    self.tool_calls.push(StreamToolCall())
  }
  self.tool_calls[index]
}

///|
fn StreamAccumulator::response(
  self : StreamAccumulator,
) -> @deepseek.ChatResponse raise {
  let reasoning_content = self.reasoning_content.to_string()
  let message = Json::object(
    Map(
      [
        ("content", Json::string(self.content.to_string())),
        ..if reasoning_content != "" {
          [("reasoning_content", Json::string(reasoning_content))]
        } else {
          []
        },
        ..if self.tool_calls.length() > 0 {
          [
            (
              "tool_calls",
              ([ for call in self.tool_calls => call.to_json() ] : Json),
            ),
          ]
        } else {
          []
        },
      ],
    ),
  )
  let envelope = Json::object(
    Map(
      [
        ("choices", ([({ "message": message } : Json)] : Json)),
        ..match self.usage {
          Some(usage) => [("usage", usage)]
          None => []
        },
      ],
    ),
  )
  @json.from_json(envelope)
}

///|
fn apply_tool_call_delta(
  acc : StreamAccumulator,
  json : Json,
  fallback_index : Int,
) -> Unit {
  guard json is Object(_) else { return }
  let index = match json {
    { "index": Number(value, ..), .. } => value.to_int()
    _ => fallback_index
  }
  guard index >= 0 else { return }
  let call = acc.ensure_tool_call(index)
  if json is { "id": String(id), .. } && id != "" {
    call.id = id
  }
  if json is { "function": { "name": String(name), .. }, .. } && name != "" {
    call.name = name
  }
  if json is { "function": { "arguments": String(arguments), .. }, .. } &&
    arguments != "" {
    call.arguments <+ "\{arguments}"
  }
}

///|
async fn apply_stream_delta(
  acc : StreamAccumulator,
  delta : Map[String, Json],
  on_content_delta~ : async (String) -> Unit,
  on_reasoning_delta~ : async (String) -> Unit,
) -> Unit {
  if delta is { "content": String(content), .. } && content != "" {
    acc.content <+ "\{content}"
    on_content_delta(content)
  }
  if delta is { "reasoning_content": String(reasoning), .. } && reasoning != "" {
    acc.reasoning_content <+ "\{reasoning}"
    on_reasoning_delta(reasoning)
  }
  if delta is { "tool_calls": Array(calls), .. } {
    for index, call in calls {
      apply_tool_call_delta(acc, call, index)
    }
  }
}

///|
async fn apply_stream_json(
  acc : StreamAccumulator,
  json : Json,
  on_content_delta~ : async (String) -> Unit,
  on_reasoning_delta~ : async (String) -> Unit,
) -> Unit {
  match json {
    { "usage": Null, .. } => ()
    { "usage": usage_json, .. } => acc.usage = Some(usage_json)
    _ => ()
  }
  match json {
    { "choices": [{ "delta": Object(delta), .. }, ..], .. } =>
      apply_stream_delta(acc, delta, on_content_delta~, on_reasoning_delta~)
    { "choices": [], .. } => ()
    _ => ()
  }
}

///|
fn sse_data_fragment(raw : String) -> String? {
  let line = raw.strip_suffix("\r").unwrap_or(raw)
  match line.strip_prefix("data:") {
    Some(data) => Some("\{data.trim()}")
    None => None
  }
}

///|
async fn flush_sse_event(
  acc : StreamAccumulator,
  data_lines : Array[String],
  on_stream_event~ : () -> Unit,
  on_content_delta~ : async (String) -> Unit,
  on_reasoning_delta~ : async (String) -> Unit,
) -> Bool {
  if data_lines.length() == 0 {
    return false
  }
  let data = "\{data_lines.join("\n").trim()}"
  data_lines.clear()
  // A flushed data payload means the completion is producing output
  // server-side — text, tool-call deltas, usage, or the terminal marker —
  // even when nothing reaches the text callbacks. Signal before parsing:
  // the retry decision must not depend on whether the payload decodes.
  //
  // Deliberately, this also fires for the EOF flush of an event whose
  // blank-line terminator never arrived: the data line itself is model
  // output (a text payload is even delivered to the callbacks below), so
  // replaying the request would duplicate or regenerate it — the missing
  // terminator does not change that. Only a drop with no data line at all
  // (caught by the emptiness guard above) leaves the request retryable.
  on_stream_event()
  if data == "[DONE]" {
    return true
  }
  apply_stream_json(
    acc,
    // A malformed payload on an established 2xx stream is a final verdict:
    // the completion already ran (and billed), so the retry loop must not
    // re-run it. fail() converts the parse error to the non-retryable class.
    @json.parse(data) catch {
      error => fail("DeepSeek stream decode error: \{error}; data: \{data}")
    },
    on_content_delta~,
    on_reasoning_delta~,
  )
  false
}

///|
/// Runs `read` under an idle bound: if it produces nothing within
/// `idle_timeout_ms`, the stall is converted to `RetryableApiError` so the
/// client's retry loop can re-run the request on a fresh connection — subject
/// to the same delivered-event bail as a mid-stream drop, so a stall after any
/// output surfaces as a failure rather than replaying a half-consumed
/// completion. `read`'s own errors propagate unchanged; a non-positive budget
/// disables the bound. The clock covers a single `read`, so on the SSE loop it
/// measures the gap between events and never trips on a long, progressing
/// completion.
async fn[T] with_idle_timeout(
  idle_timeout_ms : Int,
  what : String,
  read : async () -> T,
) -> T {
  if idle_timeout_ms <= 0 {
    read()
  } else {
    match @async.with_timeout_opt(idle_timeout_ms, read) {
      Some(value) => value
      None => raise RetryableApiError("\{what} idle for \{idle_timeout_ms}ms")
    }
  }
}

///|
async fn read_chat_stream(
  reader : @http.Client,
  idle_timeout_ms~ : Int,
  on_stream_event~ : () -> Unit,
  on_content_delta~ : async (String) -> Unit,
  on_reasoning_delta~ : async (String) -> Unit,
) -> @deepseek.ChatResponse {
  let acc = StreamAccumulator::StreamAccumulator()
  let data_lines : Array[String] = []
  for ;; {
    match
      with_idle_timeout(idle_timeout_ms, "DeepSeek stream", () => {
        reader.read_until("\n")
      }) {
      None => {
        if flush_sse_event(
            acc,
            data_lines,
            on_stream_event~,
            on_content_delta~,
            on_reasoning_delta~,
          ) {
          break
        }
        // A connection that dies before [DONE] is transport-shaped; raise
        // the retryable class so the client's retry loop may re-run the
        // request — its delivered-delta bail makes this final whenever any
        // output already reached the consumer.
        raise RetryableApiError("DeepSeek stream ended before [DONE]")
      }
      Some(raw) => {
        let trimmed = raw.trim()
        if trimmed.is_empty() {
          if flush_sse_event(
              acc,
              data_lines,
              on_stream_event~,
              on_content_delta~,
              on_reasoning_delta~,
            ) {
            break
          }
        } else if sse_data_fragment(raw) is Some(data) {
          data_lines.push(data)
        }
      }
    }
  }
  acc.response()
}
