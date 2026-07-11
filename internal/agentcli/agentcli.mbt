///|
/// Shared agent-facing CLI accessors for the command mains that launch or
/// resume agent runs (`cmd/openseek`, `cmd/tui`). The API-key resolution in
/// particular was duplicated byte-for-byte across the mains — including both
/// error strings — which made silent drift between the copies (e.g. one main
/// learning a new provider fallback and the other not) the main hazard this
/// package removes.

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
  let (provider_key, provider, env_var) = match model {
    Kimi(_) => (kimi_key, "Kimi", "KIMI")
    Deepseek(_) => (deepseek_key, "DeepSeek", "DEEPSEEK")
  }
  if !provider_key.is_empty() {
    return "\{provider_key}"
  }
  fail(
    "an API key is required for \{provider} models: pass --api-key or set \{env_var}",
  )
}
