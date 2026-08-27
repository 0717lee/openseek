///|
const DeepSeekDefaultApiUrl : String = "https://api.deepseek.com/chat/completions"

///|
const KimiDefaultApiUrl : String = "https://api.moonshot.cn/v1/chat/completions"

///|
let default_model : @deepseek.Model = Deepseek(V4Pro)

///|
fn default_api_url_for_model(model : @deepseek.Model) -> String {
  match model {
    Kimi(_) => KimiDefaultApiUrl
    Deepseek(_) => DeepSeekDefaultApiUrl
  }
}

///|
type API_KEY = String

///|
priv struct ConnectionPool {
  mut idle : @http.Client?
  mut closed : Bool
}

///|
fn ConnectionPool::ConnectionPool() -> ConnectionPool {
  { idle: None, closed: false }
}

///|
/// Synchronous checkout is atomic with respect to MoonBit's cooperative task
/// scheduling. Concurrent chats therefore take separate connections instead
/// of trying to multiplex HTTP/1.1; at most one healthy idle connection is
/// retained afterwards.
fn ConnectionPool::checkout(self : ConnectionPool) -> @http.Client? raise {
  guard !self.closed else { fail("DeepSeek client is closed") }
  let connection = self.idle
  self.idle = None
  connection
}

///|
fn ConnectionPool::checkin(
  self : ConnectionPool,
  connection : @http.Client,
) -> Unit {
  if self.closed || self.idle is Some(_) {
    connection.close()
  } else {
    self.idle = Some(connection)
  }
}

///|
fn ConnectionPool::close(self : ConnectionPool) -> Unit {
  self.closed = true
  if self.idle is Some(connection) {
    self.idle = None
    connection.close()
  }
}

///|
/// HTTP client for the DeepSeek chat completions API.
pub struct Client {
  priv api_key : API_KEY
  priv connections : ConnectionPool
  model : @deepseek.Model
  api_url : String
  thinking : @deepseek.ThinkingMode
  retry_attempts : Int
  retry_backoff_ms : Int
  connect_retry_window_ms : Int
  idle_timeout_ms : Int
}

///|
/// Keep credentials and the live connection pool out of debug output.
pub impl Debug for Client with fn to_repr(self) {
  Repr::record({
    "api_key": Repr::omitted(),
    "model": Repr(self.model),
    "api_url": Repr(self.api_url),
    "thinking": Repr(self.thinking),
    "retry_attempts": Repr(self.retry_attempts),
    "retry_backoff_ms": Repr(self.retry_backoff_ms),
    "connect_retry_window_ms": Repr(self.connect_retry_window_ms),
    "idle_timeout_ms": Repr(self.idle_timeout_ms),
  })
}

///|
/// Constructs a DeepSeek HTTP client.
///
/// `model` defaults to `deepseek-v4-pro`; `api_url` defaults to the DeepSeek
/// endpoint, or the Kimi endpoint for Kimi models. `thinking` defaults to
/// `No`; pass `High` or `Max` to enable DeepSeek V4 thinking mode explicitly.
///
/// Transient failures — transport errors, HTTP 429, and 5xx — are retried up
/// to `retry_attempts` total tries with exponential backoff starting at
/// `retry_backoff_ms` (doubling per retry, capped at 60s). Client errors other
/// than 429 never retry, and a streaming call never retries once the stream has
/// produced any event — text, tool-call, or usage alike.
///
/// Before any HTTP request bytes are sent, new streaming connections get a
/// separate `connect_retry_window_ms` retry-start window. Its 65s default can
/// cross one short-lived DNS or edge-routing cache entry without replaying a
/// request that DeepSeek may already have received or billed. Pass `0` (or
/// less) to disable this separate window. An actively refused port remains on
/// the ordinary `retry_attempts` budget so invalid endpoints fail promptly.
///
/// `idle_timeout_ms` bounds how long a streaming request may sit with no
/// progress: it caps both the wait for response headers and the wait between
/// SSE events. A silent stall (a connection the peer accepts then never feeds,
/// which TCP alone will not surface for a long time) trips it, and the stall is
/// converted to the same retryable class as a mid-stream drop — so a stall
/// before any event is retried on a fresh connection, while one after output
/// bails to a clean failure rather than duplicating a half-consumed completion.
/// The bound is measured per read — the header line, then each SSE event line —
/// so it resets on every event, not on every byte: a stream that keeps
/// delivering events never trips it. (The clock therefore covers one whole line;
/// with real DeepSeek deltas, which are small and sub-second apart, a single
/// line never approaches the default anyway.) Pass `0` (or less) to disable.
/// Defaults to 120s; it applies to the streaming path only (the mode the agent
/// and TUI use).
pub fn Client::Client(
  api_key~ : String,
  model? : @deepseek.Model = default_model,
  api_url? : String = default_api_url_for_model(model),
  thinking? : @deepseek.ThinkingMode = No,
  retry_attempts? : Int = 3,
  retry_backoff_ms? : Int = 500,
  connect_retry_window_ms? : Int = 65_000,
  idle_timeout_ms? : Int = 120_000,
) -> Client {
  {
    api_key,
    connections: ConnectionPool(),
    model,
    api_url,
    thinking,
    retry_attempts,
    retry_backoff_ms,
    connect_retry_window_ms,
    idle_timeout_ms,
  }
}

///|
/// Close the client's retained HTTP connection. This is idempotent. A request
/// already in flight is allowed to finish, then its connection is discarded
/// instead of being returned to the pool.
pub fn Client::close(self : Client) -> Unit {
  self.connections.close()
}

///|
/// Callback hooks for a streaming DeepSeek chat request.
///
/// `on_content_delta` is called for each assistant content fragment as it
/// arrives; `on_reasoning_delta` likewise for each thinking-mode reasoning
/// fragment (it is simply not called when thinking is off). `Client::chat`
/// returns the fully accumulated response after the stream reaches `[DONE]`.
pub struct StreamHandler {
  priv on_content_delta : async (String) -> Unit
  priv on_reasoning_delta : async (String) -> Unit
}

///|
/// Constructs callbacks for `Client::chat(..., stream=...)`.
pub fn StreamHandler::StreamHandler(
  on_content_delta~ : async (String) -> Unit,
  on_reasoning_delta? : async (String) -> Unit = _ => (),
) -> StreamHandler {
  { on_content_delta, on_reasoning_delta }
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
/// A network failure annotated at the exact I/O boundary where it surfaced.
/// The underlying async TLS error often contains only `ConnectionClosed`, so
/// retaining the phase here is what lets the exhausted-retry message say
/// whether the failure happened while connecting, sending, or reading.
priv suberror RetryableTransportError {
  RetryableTransportError(phase~ : String, reason~ : String)
}

///|
/// Only errors known to represent a transient socket/stream condition are
/// replayable. TLS validation/configuration errors and unknown parser or user
/// callback errors propagate immediately instead of being guessed retryable.
fn retryable_transport_error(error : Error) -> Bool {
  error is @os_error.OSError(_) ||
  error is @socket.ResolveHostnameError(_) ||
  error is @tls.ConnectionClosed ||
  error is @io.ReaderClosed
}

///|
/// TLS backends do not agree on how a peer disappearing during the handshake
/// is typed: OpenSSL may report `ConnectionClosed` or `TlsError`, while
/// Schannel reports its socket failures as `TlsError`. Retrying either is safe
/// during setup because no HTTP bytes exist yet. A permanent certificate error
/// is therefore bounded by the same setup window rather than retried after a
/// request might have been accepted.
fn retryable_connection_setup_error(error : Error) -> Bool {
  retryable_transport_error(error) || error is @tls.TlsError(_)
}

///|
/// An actively refused port is a deterministic endpoint/configuration result,
/// not the slow bad-edge failure the connect window is meant to outlive. Keep
/// it on the ordinary short request retry budget so invalid local/custom URLs
/// still fail promptly.
fn connection_refused(error : Error) -> Bool {
  match error {
    @os_error.OSError(_) as os_error => os_error.is_ECONNREFUSED()
    _ => false
  }
}

///|
fn retryable_attempt_error(error : Error) -> Bool {
  error is RetryableApiError(_) ||
  error is RetryableTransportError(..) ||
  retryable_transport_error(error)
}

///|
/// Add transport phase information without swallowing cancellation, caller
/// failures, malformed endpoint errors, or an already classified API error.
/// Schannel uses `TlsError` for established-socket failures as well as setup
/// failures, so streaming callers opt into retrying it only after setup has
/// completed; this keeps certificate and TLS configuration errors fatal.
async fn[T] transport_io(
  phase : String,
  operation : async () -> T,
  retry_tls_error? : Bool = false,
) -> T {
  operation() catch {
    error if @async.is_cancellation_error(error) => raise error
    error if error is Failure::Failure(_) => raise error
    error if error is RetryableApiError(_) => raise error
    error if error is @http.URIParseError::InvalidFormat => raise error
    error if error is @http.URIParseError::UnsupportedProtocol(_) => raise error
    error if retryable_transport_error(error) ||
      (retry_tls_error && error is @tls.TlsError(_)) =>
      raise RetryableTransportError(phase~, reason="\{error}")
    error => raise error
  }
}

///|
/// Ceiling on a single backoff sleep. The doubling sequence from
/// `retry_backoff_ms` stops growing here, so a generous retry budget cannot
/// accumulate minutes-long sleeps between attempts.
let max_backoff_ms : Int = 60_000

///|
/// Run `attempt` up to `retry_attempts` total tries via `@async.retry`
/// (exponential backoff doubling from `retry_backoff_ms`, capped at
/// `max_backoff_ms`; `max_retry` counts restarts, hence the -1).
///
/// The `fatal_error` classification is deliberately positive: only marked API
/// failures and known socket/stream errors retry. Cancellations, plain
/// failures (our own final verdicts), malformed URLs, TLS validation failures,
/// parser failures, and callback failures propagate immediately. `bail` lets
/// an attempt declare later retries pointless — streaming chat sets it once
/// the stream has produced any event, since replaying a half-consumed
/// completion would duplicate content (or regenerate tool calls) downstream.
///
/// A `RetryableApiError` that survives the budget (or bail) re-raises as a
/// plain failure carrying the same text a non-retrying client would have
/// produced, so the private marker type never escapes the package.
async fn[T] Client::with_retries(
  self : Client,
  attempt : async () -> T,
  bail : () -> Bool,
  streaming? : Bool = false,
) -> T {
  let mut attempts = 0
  @async.retry(
    ExponentialDelay(
      initial=self.retry_backoff_ms,
      factor=2.0,
      maximum=max_backoff_ms,
    ),
    max_retry=self.retry_attempts - 1,
    fatal_error=error => {
      bail() ||
      @async.is_cancellation_error(error) ||
      error is Failure::Failure(_) ||
      error is @http.URIParseError::InvalidFormat ||
      error is @http.URIParseError::UnsupportedProtocol(_) ||
      !retryable_attempt_error(error)
    },
    () => {
      attempts = attempts + 1
      attempt()
    },
  ) catch {
    RetryableApiError(message) => fail(message)
    RetryableTransportError(phase~, reason~) =>
      if streaming {
        if bail() {
          fail(
            "DeepSeek stream connection failed after the response started during \{phase} (attempt \{attempts}; not retried to avoid duplicate output): \{reason}",
          )
        } else {
          fail(
            "DeepSeek connection failed before any response event after \{attempts} attempts during \{phase}: \{reason}",
          )
        }
      } else {
        fail(
          "DeepSeek request failed after \{attempts} attempts during \{phase}: \{reason}",
        )
      }
    error => raise error
  }
}

///|
/// Sends typed chat messages to DeepSeek and decodes the response.
///
/// Pass `tools` to enable native DeepSeek function tool calls. Pass
/// `response_format=JsonObject` only when the assistant content itself should
/// be constrained to a JSON object. Pass `stream=StreamHandler(...)` to send
/// the request in SSE streaming mode while still receiving the accumulated
/// response as the return value.
pub async fn Client::chat(
  self : Client,
  messages : Array[@deepseek.ChatMessage],
  tools? : Array[@deepseek.ToolDefinition] = [],
  response_format? : @deepseek.ResponseFormat,
  stream? : StreamHandler,
) -> @deepseek.ChatResponse {
  let is_streaming = stream is Some(_)
  let body = @deepseek.encode_chat_request(
    model=self.model,
    tools~,
    thinking=self.thinking,
    stream=is_streaming,
    response_format?,
  ) <| messages
  match stream {
    None => self.with_retries(() => self.chat_attempt(body), () => false)
    Some(stream) => {
      // Once the server has produced any complete SSE event the completion is
      // running and billed — text deltas, tool-call deltas, and usage alike,
      // even though only text reaches the callbacks. A retry past that point
      // could duplicate content or generate a different tool call, so the
      // first event (not just the first text delta) bails the retry loop and
      // failures surface instead (Codex review).
      let mut streamed = false
      self.with_retries(
        () => {
          self.chat_stream_attempt(
            body,
            on_stream_event=() => streamed = true,
            stream,
          )
        },
        () => streamed,
        streaming=true,
      )
    }
  }
}

///|
async fn Client::chat_attempt(
  self : Client,
  body : Json,
) -> @deepseek.ChatResponse {
  let (resp, data) = transport_io("sending request and reading response") <| () => {
    @http.post(self.api_url, body, headers={
      "Content-Type": "application/json",
      "Authorization": "Bearer \{self.api_key}",
    })
  }
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
/// Split a full API endpoint into the origin accepted by `@http.Client` and
/// the request target sent on a reusable connection. Keep this deliberately in
/// step with async/http's URL parser: lowercase HTTP(S), first slash or query
/// after the authority, and `/` when no request target is present.
fn split_api_endpoint(url : String) -> (String, String) raise {
  guard url.find("://") is Some(protocol_len) else {
    fail("invalid DeepSeek API URL: \{url}")
  }
  match url[:protocol_len] {
    "http" | "https" => ()
    protocol => fail("unsupported DeepSeek API URL protocol: \{protocol}")
  }
  let authority_start = protocol_len + 3
  let rest = url[authority_start:]
  guard !rest.is_empty() else { fail("invalid DeepSeek API URL: \{url}") }
  let relative_path_start = rest.find("/")
  let relative_query_start = rest.find("?")
  let relative_target_start = match
    (relative_path_start, relative_query_start) {
    (Some(path), Some(query)) => Some(path.min(query))
    (Some(path), None) => Some(path)
    (None, Some(query)) => Some(query)
    (None, None) => None
  }
  match relative_target_start {
    Some(relative_target_start) => {
      let target_start = authority_start + relative_target_start
      let target = url[target_start:].to_owned()
      (
        url[:target_start].to_owned(),
        if relative_query_start == Some(relative_target_start) {
          "/\{target}"
        } else {
          target
        },
      )
    }
    None => (url, "/")
  }
}

///|
/// A response can only leave a reusable HTTP/1.1 connection when its body has
/// explicit framing and the peer did not request connection close. Otherwise
/// EOF itself delimits the body, so there is no live socket to retain.
fn response_allows_reuse(response : @http.Response) -> Bool {
  let closes = response.headers
    .get("connection")
    .map_or(false, value => value.to_lower().contains("close"))
  !closes &&
  (
    response.headers.contains("content-length") ||
    response.headers.contains("transfer-encoding")
  )
}

///|
/// Bound the next connect backoff by the wall-clock deadline. When a fast
/// failure reaches the end of the exponential schedule, sleeping the exact
/// remainder produces one final attempt at the deadline instead of stopping
/// early merely because the attempt count was exhausted.
fn connect_retry_sleep_ms(
  now : Int64,
  deadline : Int64,
  backoff_ms : Int,
) -> Int? {
  let remaining = (deadline - now).to_int()
  if remaining <= 0 {
    None
  } else {
    Some(remaining.min(backoff_ms.max(1)))
  }
}

///|
/// Establish DNS/TCP/TLS before any HTTP request bytes are sent. Only this
/// unambiguously safe phase receives the long retry window: failures after
/// `.request` may mean DeepSeek already accepted and billed the completion.
async fn Client::open_stream_connection(
  self : Client,
  origin : String,
) -> @http.Client {
  let started = @async.now()
  let deadline = started + self.connect_retry_window_ms.to_int64()
  let mut attempts = 0
  let mut backoff_ms = self.retry_backoff_ms.max(1)
  for ;; {
    attempts = attempts + 1
    try {
      return Client(origin, headers={
        "Content-Type": "application/json",
        "Authorization": "Bearer \{self.api_key}",
        // Without an explicit Accept-Encoding the HTTP client advertises gzip and
        // transparently decompresses. A gzip-compressing intermediary buffers
        // whole compression blocks, which would re-batch the SSE deltas this
        // request exists to stream — so pin the identity encoding.
        "Accept-Encoding": "identity",
      })
    } catch {
      error if @async.is_cancellation_error(error) => raise error
      error if connection_refused(error) =>
        raise RetryableTransportError(
          phase="DNS/TCP/TLS setup",
          reason="\{error}",
        )
      error if !retryable_connection_setup_error(error) =>
        fail(
          "DeepSeek connection setup failed before sending the request during DNS/TCP/TLS setup: \{error}",
        )
      error if self.connect_retry_window_ms <= 0 =>
        raise RetryableTransportError(
          phase="DNS/TCP/TLS setup",
          reason="\{error}",
        )
      error =>
        match connect_retry_sleep_ms(@async.now(), deadline, backoff_ms) {
          Some(sleep_ms) => {
            @async.sleep(sleep_ms)
            backoff_ms = max_backoff_ms.min(backoff_ms * 2)
          }
          _ => {
            let elapsed_ms = (@async.now() - started).to_int()
            fail(
              "DeepSeek connection failed before sending the request after \{attempts} attempts over \{elapsed_ms}ms during DNS/TCP/TLS setup: \{error}",
            )
          }
        }
    }
  }
}

///|
/// `[DONE]` ends the SSE protocol before the HTTP reader necessarily consumes
/// the final chunk marker. Drain that framing under a short bound before
/// pooling. Failure merely forfeits reuse: the model response is already
/// complete and must not be turned into a retry or user-visible error.
async fn drain_completed_response(client : @http.Client) -> Bool {
  try (
    @async.with_timeout_opt(1_000, () => client.skip_response_body()) is Some(_)
  ) catch {
    error if @async.is_cancellation_error(error) => raise error
    _ => false
  }
}

///|
async fn Client::chat_stream_attempt(
  self : Client,
  body : Json,
  on_stream_event~ : () -> Unit,
  stream : StreamHandler,
) -> @deepseek.ChatResponse {
  let (origin, path) = split_api_endpoint(self.api_url)
  let client = match self.connections.checkout() {
    Some(connection) => connection
    None => self.open_stream_connection(origin)
  }
  let mut reusable = false
  defer (if reusable {
    self.connections.checkin(client)
  } else {
    client.close()
  })
  transport_io(
    "starting HTTP request",
    () => client.request(Post, path),
    retry_tls_error=true,
  )
  transport_io(
    "sending request body",
    () => client.write(body.stringify()),
    retry_tls_error=true,
  )
  // Bound the wait for response headers the same way the SSE loop bounds the
  // wait between events: a peer that accepts the connection then never sends a
  // status line would otherwise block here forever, before any event, with no
  // error for the retry loop to see.
  let resp = transport_io(
    "waiting for response headers",
    () => {
      with_idle_timeout(self.idle_timeout_ms, "DeepSeek response headers", () => {
        client.end_request()
      })
    },
    retry_tls_error=true,
  )
  guard resp.code >= 200 && resp.code < 300 else {
    let text = transport_io(
      "reading error response body",
      () => client.read_all().text(),
      retry_tls_error=true,
    )
    reusable = response_allows_reuse(resp)
    let message = "DeepSeek API error \{resp.code}: \{text}"
    if retryable_status(resp.code) {
      raise RetryableApiError(message)
    }
    fail(message)
  }
  // The stream reader finalizes malformed SSE payloads at its parse site
  // (see decode_sse_data in stream.mbt), so a mid-stream transport error
  // reaches the retry loop with its own type and the delivered-event bail
  // decides whether retrying is allowed.
  let response = read_chat_stream(
    client,
    idle_timeout_ms=self.idle_timeout_ms,
    on_stream_event~,
    on_content_delta=stream.on_content_delta,
    on_reasoning_delta=stream.on_reasoning_delta,
  )
  if response_allows_reuse(resp) && drain_completed_response(client) {
    reusable = true
  }
  response
}

///|
pub extend Client with Debug::{to_repr}
