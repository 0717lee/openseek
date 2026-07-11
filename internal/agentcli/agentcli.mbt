///|
/// Shared agent-facing CLI accessors for the command mains that launch or
/// resume agent runs (`cmd/openseek`, `cmd/tui`). The API-key resolution in
/// particular was duplicated byte-for-byte across the mains — including both
/// error strings — which made silent drift between the copies (e.g. one main
/// learning a new provider fallback and the other not) the main hazard this
/// package removes.

///|
/// Environment variable that carries the API key for `model`'s provider.
/// Spawned engine processes inherit their key through this variable, so it
/// must stay in lockstep with `api_key`'s lookup order.
pub fn api_key_env_for_model(model : @deepseek.Model) -> String {
  match model {
    Kimi(_) => "KIMI"
    Deepseek(_) => "DEEPSEEK"
  }
}

///|
/// Human-readable provider name for `model`, used in error guidance.
fn api_key_provider_for_model(model : @deepseek.Model) -> String {
  match model {
    Kimi(_) => "Kimi"
    Deepseek(_) => "DeepSeek"
  }
}

///|
/// Resolve the API key for `model`: an explicit `--api-key` wins, then the
/// provider-specific option (which each command table backs with the
/// provider's environment variable). Fails with provider-specific guidance
/// when neither is set.
pub fn api_key(
  matches : @argparse.Matches,
  model : @deepseek.Model,
) -> String raise {
  let (generic_key, deepseek_key, kimi_key) = match matches {
    {
      values: {
        "api-key"? : Some([generic_key, ..])
        | (Some([])
        | None) with generic_key = "",
        "deepseek-api-key"? : Some([deepseek_key, ..])
        | (Some([])
        | None) with deepseek_key = "",
        "kimi-api-key"? : Some([kimi_key, ..])
        | (Some([])
        | None) with kimi_key = "",
        ..
      },
      ..,
    } => (generic_key.trim(), deepseek_key.trim(), kimi_key.trim())
  }
  if !generic_key.is_empty() {
    return "\{generic_key}"
  }
  let provider_key = match model {
    Kimi(_) => kimi_key
    Deepseek(_) => deepseek_key
  }
  if !provider_key.is_empty() {
    return "\{provider_key}"
  }
  fail(
    "an API key is required for \{api_key_provider_for_model(model)} models: pass --api-key or set \{api_key_env_for_model(model)}",
  )
}

///|
/// `--api-url` as an override: unset or whitespace-only means "use the
/// provider default".
pub fn api_url(matches : @argparse.Matches) -> String? raise {
  let url = match matches {
    { values: { "api-url": [url, ..], .. }, .. } => url.trim()
    _ => fail("missing parsed argument: api-url")
  }
  if url.is_empty() {
    None
  } else {
    Some("\{url}")
  }
}

///|
/// `--session` as a durable session id. `--session` is a root global without
/// a default, so read it gracefully: it is absent (not empty) in a
/// subcommand's matches when unset.
pub fn session_id(matches : @argparse.Matches) -> @agent_session.SessionId? {
  let id = match matches {
    {
      values: {
        "session"? : Some([session, ..])
        | (Some([])
        | None) with session = "",
        ..
      },
      ..,
    } => session.trim()
  }
  if id.is_empty() {
    None
  } else {
    Some(SessionId("\{id}"))
  }
}
