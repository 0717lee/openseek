// Turning a `start` payload into the validated configuration a serve engine
// is spawned with.

///|
const DefaultModel = "deepseek-v4-pro"

///|
const DefaultMaxSteps = 1000

///|
/// Sent as the API key when a custom endpoint is configured without one: the
/// engine refuses to start with an empty key, but an endpoint like the
/// default OpenSeek proxy does not validate it.
const PlaceholderApiKey = "unused"

///|
priv struct RunConfig {
  task : String
  api_key : String
  // Custom chat-completions endpoint; None means the engine's built-in
  // default (the official DeepSeek endpoint).
  api_url : String?
  model : String
  max_steps : Int
  engine : String
  // Where the engine process runs: natively, or inside a WSL distro. In WSL
  // mode `engine` above (the bundled Windows binary) still serves the
  // host's own one-shot session queries; the serve process runs the
  // distro's engine instead.
  host : EngineHost
  cwd : @path.Path?
  session : String?
  session_root : @path.Path?
}

///|
/// The official OpenSeek proxy; must stay a prefix of the frontend's
/// `OpenseekApiUrl`. Endpoints under it authenticate with the packaged
/// client token instead of a user API key.
const OpenseekProxyPrefix : String = "https://openseek-api.moonbitlang.cn/"

///|
fn configured_api_key(
  payload_key : String?,
  api_url : String?,
  deepseek_env : String?,
  client_token? : String,
) -> String raise EngineError {
  if payload_key is Some(value) {
    return value
  }
  if api_url is Some(url) {
    // Only the official proxy gets the client token; any other endpoint
    // would be handing the credential to a third-party server.
    if url.has_prefix(OpenseekProxyPrefix) && client_token is Some(token) {
      return token
    }
    return PlaceholderApiKey
  }
  if deepseek_env is Some(value) {
    return value
  }
  raise EngineError(
    "DeepSeek API key is required; pass api_key or set DEEPSEEK",
  )
}

///|
fn configured_max_steps(value : Int?) -> Int raise EngineError {
  let parsed = if value is Some(value) {
    value
  } else if @env.get("OPENSEEK_MAX_STEPS") is Some(text) {
    @string.parse_int(text) catch {
      _ => raise EngineError("OPENSEEK_MAX_STEPS must be a positive integer")
    }
  } else {
    DefaultMaxSteps
  }
  guard parsed > 0 else {
    raise EngineError("max_steps must be a positive integer")
  }
  parsed
}

///|
async fn run_config(payload : StartRequest, engine : String) -> RunConfig {
  let task = payload.task.trim().to_owned()
  guard !task.is_empty() else { raise EngineError("task must not be empty") }
  serve_config(
    task,
    engine,
    api_key?=payload.api_key,
    api_url?=payload.api_url,
    model?=payload.model,
    max_steps?=payload.max_steps,
    session?=payload.session,
    session_root?=payload.session_root,
    workspace?=payload.workspace,
    wsl?=payload.wsl,
  )
}

///|
/// The config a compaction spawns an engine with when its conversation has
/// none live (resumed after a restart, or the process died between turns):
/// the same settings a start carries, pinned to the compacted session. The
/// blank task is never sent — `compact_run` writes only the compact command,
/// and the fingerprint deliberately excludes the task.
async fn compact_config(payload : CompactRequest, engine : String) -> RunConfig {
  guard !payload.session.is_empty() else {
    raise EngineError("session id must not be empty")
  }
  serve_config(
    "",
    engine,
    api_key?=payload.api_key,
    api_url?=payload.api_url,
    model?=payload.model,
    max_steps?=payload.max_steps,
    session=payload.session,
    session_root?=payload.session_root,
    workspace?=payload.workspace,
    wsl?=payload.wsl,
  )
}

///|
/// The validated configuration shared by every op that can spawn a serve
/// engine.
async fn serve_config(
  task : String,
  engine : String,
  api_key? : String,
  api_url? : String,
  model? : String,
  max_steps? : Int,
  session? : String,
  session_root? : String,
  workspace? : String,
  wsl? : WslRequest,
) -> RunConfig {
  // Only the official endpoint strictly needs a key; a custom endpoint
  // decides for itself, so a missing key becomes a placeholder there. Do
  // not reuse the official DeepSeek env key for a custom/OpenSeek endpoint.
  let api_key = configured_api_key(
    api_key,
    api_url,
    @env.get("DEEPSEEK"),
    client_token?=openseek_client_token(),
  )
  let host = engine_host(wsl, engine)
  // A workspace run happens in the project directory itself, with the
  // session's durable record in the in-project store. Only registered
  // workspaces qualify — the registry, not the payload, decides which
  // directories a run may work in.
  let workspace : @path.Path? = if workspace is Some(path) {
    match registered_workspace(path) {
      Some(dir) => Some(dir)
      None => raise EngineError("\{path} is not a registered workspace")
    }
  } else {
    None
  }
  {
    task,
    api_key,
    api_url,
    model: match model {
      Some(model) => model
      // The engine takes its model from OPENSEEK_MODEL (DEEPSEEK_MODEL is
      // deliberately ignored — see `serve_engine_env`), so the host's
      // fallback must read the same variable.
      None => @env.get("OPENSEEK_MODEL").unwrap_or(DefaultModel)
    },
    max_steps: configured_max_steps(max_steps),
    engine,
    host,
    cwd: if workspace is Some(dir) {
      Some(dir)
    } else {
      resolved_run_cwd(session)
    },
    session,
    session_root: if workspace is Some(dir) {
      Some(workspace_session_root(dir))
    } else if session is Some(_) {
      resolved_session_root(payload_root?=session_root.map(root => Path(root)))
    } else {
      None
    },
  }
}

///|
/// Engine working directory for a run. A named conversation gets its own
/// workspace directory derived from its durable session id (created on demand
/// by `start_run`), so the agent's files land somewhere the user can find and
/// resuming the session returns to them. With no session, fall back to the
/// user's home directory: inheriting the host's own cwd would hand the agent
/// whatever directory the app happened to be launched from (`/` under Finder),
/// which is never a sensible place to work in.
async fn resolved_run_cwd(session : String?) -> @path.Path? {
  if session is Some(session) && session_workspace_dir(session) is Some(dir) {
    return Some(dir)
  }
  @home.dir().map(home => home.to_string())
}

///|
/// The manager's map key for a run: its durable session id, or the one shared
/// slot for session-less runs (the desktop client always names a session).
fn session_key(config : RunConfig) -> String {
  config.session.unwrap_or("")
}

///|
/// Everything that pins a serve process to a config: a prompt whose
/// fingerprint differs (model change, new session, …) must replace the
/// process. The task is deliberately excluded — prompts vary per turn.
fn engine_fingerprint(config : RunConfig) -> String {
  [
    config.engine,
    config.host.fingerprint(),
    config.api_key,
    config.api_url.unwrap_or(""),
    config.model,
    config.max_steps.to_string(),
    config.cwd.map(cwd => cwd.to_string()).unwrap_or(""),
    config.session.unwrap_or(""),
    config.session_root.map(root => root.to_string()).unwrap_or(""),
  ].join("\u{0}")
}

///|
test "a different endpoint cannot reuse a live engine process" {
  let base : RunConfig = {
    task: "t",
    api_key: "k",
    api_url: None,
    model: "deepseek-v4-pro",
    max_steps: 1000,
    engine: "openseek",
    host: Native,
    cwd: None,
    session: None,
    session_root: None,
  }
  let custom = {
    ..base,
    api_url: Some("https://proxy.example/chat/completions"),
  }
  assert_true(engine_fingerprint(base) != engine_fingerprint(custom))
  assert_eq(engine_fingerprint(base), engine_fingerprint({ ..base, task: "u" }))
}

///|
test "switching engine hosts cannot reuse a live engine process" {
  let base : RunConfig = {
    task: "t",
    api_key: "k",
    api_url: None,
    model: "deepseek-v4-pro",
    max_steps: 1000,
    engine: "openseek",
    host: Native,
    cwd: None,
    session: None,
    session_root: None,
  }
  let wsl = { ..base, host: Wsl(distro=Some("Ubuntu"), engine="openseek") }
  assert_true(engine_fingerprint(base) != engine_fingerprint(wsl))
  assert_true(
    engine_fingerprint(wsl) !=
    engine_fingerprint({
      ..base,
      host: Wsl(distro=Some("Debian"), engine="openseek"),
    }),
  )
}

///|
test "custom endpoint does not reuse DEEPSEEK env fallback" {
  assert_eq(
    configured_api_key(
      None,
      Some("https://proxy.example/chat/completions"),
      Some("official-key"),
    ),
    PlaceholderApiKey,
  )
  assert_eq(
    configured_api_key(
      Some("custom-key"),
      Some("https://proxy.example/chat/completions"),
      Some("official-key"),
    ),
    "custom-key",
  )
}

///|
test "official OpenSeek proxy authenticates with the client token" {
  assert_eq(
    configured_api_key(
      None,
      Some("https://openseek-api.moonbitlang.cn/chat/completions"),
      Some("official-key"),
      client_token="stamped-token",
    ),
    "stamped-token",
  )
  // A user-provided key always wins over the stamped token.
  assert_eq(
    configured_api_key(
      Some("user-key"),
      Some("https://openseek-api.moonbitlang.cn/chat/completions"),
      None,
      client_token="stamped-token",
    ),
    "user-key",
  )
  // An unstamped build behaves as before.
  assert_eq(
    configured_api_key(
      None,
      Some("https://openseek-api.moonbitlang.cn/chat/completions"),
      None,
    ),
    PlaceholderApiKey,
  )
}

///|
test "other endpoints never see the client token" {
  assert_eq(
    configured_api_key(
      None,
      Some("https://proxy.example/chat/completions"),
      None,
      client_token="stamped-token",
    ),
    PlaceholderApiKey,
  )
  // A lookalike host on another domain does not match the prefix.
  assert_eq(
    configured_api_key(
      None,
      Some("https://openseek-api.moonbitlang.cn.evil.example/chat/completions"),
      None,
      client_token="stamped-token",
    ),
    PlaceholderApiKey,
  )
}

///|
test "official endpoint still uses DEEPSEEK env fallback" {
  assert_eq(
    configured_api_key(None, None, Some("official-key")),
    "official-key",
  )
  let _ = configured_api_key(None, None, None) catch {
    EngineError(message) => {
      assert_true(message.contains("DeepSeek API key is required"))
      return
    }
  }
  fail("official endpoint accepted a missing key")
}

///|
async test "desktop start ignores OPENSEEK_API_URL without an explicit payload URL" {
  let previous = @sys.get_env_var("OPENSEEK_API_URL")
  @sys.set_env_var("OPENSEEK_API_URL", "https://env.example/chat/completions")
  let config = run_config(
    {
      task: "hello",
      api_key: Some("official-key"),
      api_url: None,
      model: None,
      max_steps: None,
      session: None,
      session_root: None,
      workspace: None,
      wsl: None,
    },
    "openseek",
  ) catch {
    error => {
      if previous is Some(value) {
        @sys.set_env_var("OPENSEEK_API_URL", value)
      } else {
        @sys.unset_env_var("OPENSEEK_API_URL")
      }
      raise error
    }
  }
  if previous is Some(value) {
    @sys.set_env_var("OPENSEEK_API_URL", value)
  } else {
    @sys.unset_env_var("OPENSEEK_API_URL")
  }
  assert_true(config.api_url is None)
  assert_eq(config.api_key, "official-key")
}
