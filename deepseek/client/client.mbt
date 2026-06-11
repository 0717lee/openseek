///|
let default_api_url : String = "https://api.deepseek.com/chat/completions"

///|
let default_model : @deepseek.Model = V4Pro

///|
type API_KEY = String

///|
/// HTTP client for the DeepSeek chat completions API.
pub struct Client {
  priv api_key : API_KEY
  model : @deepseek.Model
  api_url : String
  thinking : @deepseek.ThinkingMode?
  reasoning_effort : @deepseek.ReasoningEffort?
  retry_attempts : Int
  retry_backoff_ms : Int
} derive(Debug(ignore=API_KEY))

///|
/// Constructs a DeepSeek HTTP client.
///
/// `model` defaults to `deepseek-v4-pro`; `api_url` defaults to the DeepSeek
/// chat completions endpoint. Pass `thinking` and `reasoning_effort` to control
/// DeepSeek V4 thinking mode explicitly.
///
/// Transient failures — transport errors, HTTP 429, and 5xx — are retried up
/// to `retry_attempts` total tries with exponential backoff starting at
/// `retry_backoff_ms` (doubling per retry). Client errors other than 429
/// never retry, and a streaming call never retries once a delta has been
/// delivered.
pub fn Client::Client(
  api_key~ : String,
  model? : @deepseek.Model = default_model,
  api_url? : String = default_api_url,
  thinking? : @deepseek.ThinkingMode? = None,
  reasoning_effort? : @deepseek.ReasoningEffort? = None,
  retry_attempts? : Int = 3,
  retry_backoff_ms? : Int = 500,
) -> Client {
  {
    api_key,
    model,
    api_url,
    thinking,
    reasoning_effort,
    retry_attempts,
    retry_backoff_ms,
  }
}

///|
/// A response status worth retrying: rate limiting or a server-side failure.
/// Other 4xx are caller errors (bad key, malformed request) that a retry
/// cannot fix.
fn retryable_status(code : Int) -> Bool {
  code == 429 || (code >= 500 && code < 600)
}

///|
/// Marks an attempt failure the retry loop may absorb. Carries the
/// already-formatted public failure message so the final attempt re-raises
/// the same text a non-retrying client would have produced.
priv suberror RetryableApiError {
  RetryableApiError(String)
}

///|
/// Run `attempt` up to `retry_attempts` times. `RetryableApiError` and
/// transport errors back off and retry; cancellations and everything else
/// (including non-retryable HTTP statuses, raised as plain failures by the
/// attempt) propagate immediately. `bail` lets an attempt declare later
/// retries pointless — chat_stream sets it once deltas were delivered, since
/// replaying a half-consumed stream would duplicate content downstream.
async fn[T] Client::with_retries(
  self : Client,
  attempt : async () -> T,
  bail : () -> Bool,
) -> T {
  for tries = 1; ; tries = tries + 1 {
    return attempt() catch {
      error if @async.is_being_cancelled() ||
        @async.is_cancellation_error(error) => raise error
      RetryableApiError(message) if tries >= self.retry_attempts || bail() =>
        fail(message)
      RetryableApiError(_) => {
        @async.sleep(self.retry_backoff_ms << (tries - 1))
        continue
      }
      // A plain Failure is one of our own final verdicts (non-retryable
      // status, malformed response body, truncated stream): never retry it.
      Failure::Failure(_) as error => raise error
      // A malformed api_url fails identically every time, before any
      // network I/O — retrying only repeats the configuration error.
      @http.URIParseError::InvalidFormat as error => raise error
      @http.URIParseError::UnsupportedProtocol(_) as error => raise error
      error if bail() || tries >= self.retry_attempts => raise error
      // Anything else is transport-shaped (connect refused, reset, DNS):
      // retry within budget.
      _ => {
        @async.sleep(self.retry_backoff_ms << (tries - 1))
        continue
      }
    }
  }
}

///|
/// Sends typed chat messages to DeepSeek and decodes the response.
///
/// Pass `tools` to enable native DeepSeek function tool calls. Pass
/// `response_format=JsonObject` only when the assistant content itself should
/// be constrained to a JSON object.
pub async fn Client::chat(
  self : Client,
  messages : Array[@deepseek.ChatMessage],
  tools? : Array[@deepseek.ToolDefinition] = [],
  response_format? : @deepseek.ResponseFormat,
) -> @deepseek.ChatResponse {
  let body = @deepseek.encode_chat_request(
    self.model,
    messages,
    tools~,
    thinking?=self.thinking,
    reasoning_effort?=self.reasoning_effort,
    response_format?,
  )
  self.with_retries(() => self.chat_attempt(body), () => false)
}

///|
async fn Client::chat_attempt(
  self : Client,
  body : Json,
) -> @deepseek.ChatResponse {
  let (resp, data) = @http.post(self.api_url, body, headers={
    "Content-Type": "application/json",
    "Authorization": "Bearer \{self.api_key}",
  })
  let text = data.text()
  guard resp.code >= 200 && resp.code < 300 else {
    let message = "DeepSeek API error \{resp.code}: \{text}"
    if retryable_status(resp.code) {
      raise RetryableApiError(message)
    }
    fail(message)
  }
  // A 2xx body that fails to parse or decode is a final verdict, not a
  // transport error: the completion already ran (and billed), so retrying
  // would duplicate it for the same bad payload.
  @json.from_json(
    @json.parse(text) catch {
      error => fail("DeepSeek response is not JSON: \{error}; body: \{text}")
    },
  ) catch {
    error => fail("DeepSeek response decode error: \{error}; body: \{text}")
  }
}

///|
/// Sends typed chat messages in DeepSeek SSE streaming mode.
///
/// `on_content_delta` is called for each assistant content fragment as it
/// arrives; `on_reasoning_delta` likewise for each thinking-mode reasoning
/// fragment (it is simply not called when thinking is off). The returned value
/// is the fully accumulated response, including reasoning, tool calls, and
/// final token usage when the API sends it.
pub async fn Client::chat_stream(
  self : Client,
  messages : Array[@deepseek.ChatMessage],
  on_content_delta~ : async (String) -> Unit,
  on_reasoning_delta? : async (String) -> Unit = _ => (),
  tools? : Array[@deepseek.ToolDefinition] = [],
  response_format? : @deepseek.ResponseFormat,
) -> @deepseek.ChatResponse {
  let body = @deepseek.encode_chat_request(
    self.model,
    messages,
    tools~,
    thinking?=self.thinking,
    reasoning_effort?=self.reasoning_effort,
    stream=true,
    response_format?,
  )
  // Once any delta reached a callback the consumer has observed partial
  // output; a retry would replay it from the top. Bail out of the retry
  // loop at that point and surface the failure instead.
  let mut streamed = false
  self.with_retries(
    () => {
      self.chat_stream_attempt(
        body,
        on_content_delta=delta => {
          streamed = true
          on_content_delta(delta)
        },
        on_reasoning_delta=delta => {
          streamed = true
          on_reasoning_delta(delta)
        },
      )
    },
    () => streamed,
  )
}

///|
async fn Client::chat_stream_attempt(
  self : Client,
  body : Json,
  on_content_delta~ : async (String) -> Unit,
  on_reasoning_delta~ : async (String) -> Unit,
) -> @deepseek.ChatResponse {
  let client = @http.post_stream(self.api_url, headers={
    "Content-Type": "application/json",
    "Authorization": "Bearer \{self.api_key}",
    // Without an explicit Accept-Encoding the HTTP client advertises gzip and
    // transparently decompresses. A gzip-compressing intermediary buffers
    // whole compression blocks, which would re-batch the SSE deltas this
    // request exists to stream — so pin the identity encoding.
    "Accept-Encoding": "identity",
  })
  defer client.close()
  client.write(body.stringify())
  let resp = client.end_request()
  guard resp.code >= 200 && resp.code < 300 else {
    let text = client.read_all().text()
    let message = "DeepSeek API error \{resp.code}: \{text}"
    if retryable_status(resp.code) {
      raise RetryableApiError(message)
    }
    fail(message)
  }
  // The stream reader finalizes malformed SSE payloads at its parse site
  // (see decode_sse_data in stream.mbt), so a mid-stream transport error
  // reaches the retry loop with its own type and the delivered-delta bail
  // decides whether retrying is allowed.
  read_chat_stream(client, on_content_delta~, on_reasoning_delta~)
}
