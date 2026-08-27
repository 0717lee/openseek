# DeepSeek Client

This package is the effectful HTTP transport for DeepSeek chat completions. It
uses `bobzhang/openseek/deepseek` for typed models, messages, tool definitions,
request JSON encoding, and response JSON decoding.

Use this package when code needs to call the real DeepSeek API. Keep pure
request/response tests in `bobzhang/openseek/deepseek`; use this package for
transport behavior such as retries, HTTP errors, and streaming.

The package depends on `moonbitlang/async/http` and is native-only.

## API Shape

- `Client(api_key~, model?, api_url?, thinking?, retry_attempts?,
  retry_backoff_ms?, connect_retry_window_ms?, idle_timeout_ms?)`: configure
  the API key, endpoint, model, thinking mode, retry budgets, and streaming
  idle bound.
- `Client::chat(messages, tools?, response_format?, stream?)`: send a request
  and decode the response as `@deepseek.ChatResponse`. Without `stream`, this
  is a normal JSON response. With `stream=StreamHandler(...)`, it uses SSE and
  still returns the accumulated response.
- `Client::close()`: close the retained keep-alive connection. Agent turns do
  this automatically; long-lived direct users should call it when finished.
- `StreamHandler(on_content_delta~, on_reasoning_delta?)`: receive non-empty
  content and reasoning deltas while a streaming chat request is in progress.

`Client` implements `Debug` with the API key redacted.

## Configuration

The default endpoint is `https://api.deepseek.com/chat/completions`, the default
model is `deepseek-v4-pro`, and `thinking=No` is sent unless a different mode is
provided. Kimi K2.7 Code models default to
`https://api.moonshot.cn/v1/chat/completions` and omit DeepSeek-specific
thinking fields when the request body is encoded.

Retries cover transient failures: transport errors, HTTP 429, and HTTP 5xx.
Other HTTP 4xx responses fail immediately. `retry_attempts` counts total tries;
`retry_backoff_ms` is the first exponential-backoff delay, capped internally at
60 seconds. Their defaults remain three total tries and a 500ms initial delay.
A streaming request stops replaying as soon as the first complete SSE event
arrives, so partial model output and tool calls are never duplicated
automatically. The ordinary three-attempt policy still applies when a request
was sent but no SSE event came back; as with the previous client behavior, an
upstream that accepted such a request before the connection failed could bill
more than one completion. Set `retry_attempts=1` if that tradeoff is not
acceptable.

New streaming connections have a separate 65-second retry-start window,
`connect_retry_window_ms`. It applies only to DNS/TCP/TLS setup, before any HTTP
request bytes are sent, so it can cross a short-lived DNS or edge-routing cache
entry safely. The separate connection window itself never repeats a completion
because none has been requested yet. Eligible fast failures retry through its
deadline; an in-progress OS connect may finish after it. An actively refused
port instead uses the ordinary short `retry_attempts` policy so invalid
endpoints fail promptly. Pass `0` to disable only the separate long window.

Successful sequential streaming calls on the same `Client` reuse one healthy
HTTP/1.1 connection, avoiding another DNS lookup, TCP connect, and TLS
handshake for every tool-call round. A connection is retained only after
`[DONE]` and the remaining HTTP response framing have both been consumed.
Transport failures, `Connection: close`, incomplete body framing, and stale
connections all cause that socket to be discarded; a later retry reconnects.

When transport retries are exhausted, the error includes the attempt count and
the I/O phase (for example, DNS/TCP/TLS setup or waiting for response headers).
This turns an otherwise context-free TLS `ConnectionClosed` into a diagnostic
without claiming that a particular proxy, DNS resolver, or network is always
responsible.

```moonbit check
///|
test "construct DeepSeek client configuration" {
  let client = @client.Client(
    api_key="test-key",
    model=Deepseek(V4Flash),
    thinking=Max,
    retry_attempts=5,
    retry_backoff_ms=200,
  )
  debug_inspect(
    client,
    content=(
      #|{
      #|  api_key: ...,
      #|  model: Deepseek(V4Flash),
      #|  api_url: "https://api.deepseek.com/chat/completions",
      #|  thinking: Max,
      #|  retry_attempts: 5,
      #|  retry_backoff_ms: 200,
      #|  connect_retry_window_ms: 65000,
      #|  idle_timeout_ms: 120000,
      #|}
    ),
  )
}
```

## Non-Streaming Chat

Without `stream`, `Client::chat` builds the same JSON body as
`@deepseek.encode_chat_request`, using the client's `model` and `thinking`
configuration, then posts it to `api_url` with `Content-Type:
application/json` and bearer authorization.

Use `tools=[...]` when the model may request native DeepSeek function calls.
Use `response_format=JsonObject` only when the assistant content itself must be
a JSON object.

At runtime:

```moonbit nocheck
///|
let client = @client.Client(api_key~, thinking=Max)
defer client.close()

///|
let response = client.chat(
  [@deepseek.ChatMessage(User, content="Return {\"ok\":true}.")],
  response_format=JsonObject,
)
```

The request body has this shape:

```moonbit check
///|
test "Client::chat request body shape" {
  let client = @client.Client(
    api_key="test-key",
    model=Deepseek(V4Flash),
    thinking=Max,
  )
  let tool = @deepseek.ToolDefinition("read", "Read a file.", {
    "type": "object",
    "properties": { "path": { "type": "string" } },
    "required": ["path"],
  })
  let body = @deepseek.encode_chat_request(
    model=client.model,
    thinking=client.thinking,
    tools=[tool],
    response_format=JsonObject,
  ) <| [
    ChatMessage(User, content="read README.mbt.md"),
  ]
  json_inspect(body, content={
    "model": "deepseek-v4-flash",
    "messages": [{ "role": "user", "content": "read README.mbt.md" }],
    "stream": false,
    "response_format": { "type": "json_object" },
    "tools": [
      {
        "type": "function",
        "function": {
          "name": "read",
          "description": "Read a file.",
          "parameters": {
            "type": "object",
            "properties": { "path": { "type": "string" } },
            "required": ["path"],
          },
        },
      },
    ],
    "thinking": { "type": "enabled" },
    "reasoning_effort": "max",
  })
}
```

If a response contains tool calls, append the assistant tool-call echo first,
then append one `Tool(call.id)` result message per call before the next request.

## Streaming Chat

Pass `stream=StreamHandler(...)` to `Client::chat` to send `stream=true` plus
`stream_options={"include_usage":true}` for usage-bearing streams. The transport
pins `Accept-Encoding: identity` so a gzip-compressing intermediary cannot
buffer and re-batch SSE deltas.

The stream reader:

- calls `on_content_delta` for each non-empty `delta.content`
- calls `on_reasoning_delta` for each non-empty `delta.reasoning_content`
- accumulates content, reasoning, tool-call fragments, and final usage
- returns the accumulated value as a normal `@deepseek.ChatResponse`

Streaming calls retry only until the first SSE event is produced. After any
event - text, reasoning, tool-call, or usage - retrying could duplicate or
change the completion, so later failures surface directly.

At runtime:

```moonbit nocheck
///|
let stream = @client.StreamHandler(on_content_delta=delta => print(delta), on_reasoning_delta=reasoning => {
  log_reasoning(reasoning)
})

///|
let response = client.chat(
  [@deepseek.ChatMessage(User, content="Explain this briefly.")],
  stream~,
)
```

The request body has this shape:

```moonbit check
///|
test "Client::chat streaming request body shape" {
  let client = @client.Client(api_key="test-key")
  let body = @deepseek.encode_chat_request(
    model=client.model,
    thinking=client.thinking,
    stream=true,
  ) <| [
    ChatMessage(User, content="stream this"),
  ]
  json_inspect(body, content={
    "model": "deepseek-v4-pro",
    "messages": [{ "role": "user", "content": "stream this" }],
    "stream": true,
    "stream_options": { "include_usage": true },
    "thinking": { "type": "disabled" },
  })
}
```

## Errors

HTTP statuses outside `200..<300` fail with
`DeepSeek API error <status>: <body>`. A successful HTTP response that is not
valid JSON fails with `DeepSeek response is not JSON`; a valid JSON response
that does not match the expected DeepSeek envelope fails with
`DeepSeek response decode error`.

## Tests

Run the package tests with:

```bash
moon test deepseek/client
```

The blackbox test suite includes a real DeepSeek API smoke test when `DEEPSEEK`
is set. Kimi smoke tests are opt-in: set `KIMI` to a Kimi API key. The normal
Kimi smoke also uses `OPENSEEK_MODEL` to choose the Kimi model; streaming,
tool-call, and multi-turn reasoning-content smokes use `kimi-k2.7-code`.
Without those environment variables, the smoke tests print skip messages and
return successfully.
