///|
/// Agent-facing API-key resolution for the command mains that launch or resume
/// agent runs (`cmd/openseek`, `cmd/tui`). This lived in
/// `internal/agentcli` because it was duplicated byte-for-byte across the
/// mains — including both error strings — and silent drift between the copies
/// (e.g. one main learning a new provider fallback and the other not) is the
/// hazard the shared definition removes. It sits on `Model` because the
/// provider a key belongs to is exactly what the model tag decides.

///|
/// Resolve the API key for this model: an explicit `--api-key` wins, then the
/// provider-specific option (which each command table backs with the
/// provider's environment variable). Fails with provider-specific guidance
/// when neither is set.
///
/// The model and the parsed options are matched together so each arm reads
/// only the option that provider actually uses, and keeps that option's name
/// next to the provider's display name and environment variable. Adding a
/// provider is then one new arm rather than an edit in three places.
pub fn Model::api_key(
  self : Model,
  matches : @argparse.Matches,
) -> String raise {
  let (generic_key, provider_key, provider, env_var) = match (self, matches) {
    (
      Deepseek(_),
      {
        values: {
          "api-key"? : Some([generic, ..])
          | (Some([]) | None with generic = ""),
          "deepseek-api-key"? : Some([key, ..])
          | (Some([]) | None with key = ""),
          ..
        },
        ..,
      },
    ) => (generic.trim(), key.trim(), "DeepSeek", "DEEPSEEK")
    (
      Kimi(_),
      {
        values: {
          "api-key"? : Some([generic, ..])
          | (Some([]) | None with generic = ""),
          "kimi-api-key"? : Some([key, ..])
          | (Some([]) | None with key = ""),
          ..
        },
        ..,
      },
    ) => (generic.trim(), key.trim(), "Kimi", "KIMI")
  }
  // `trim` yields a borrowed view; the caller owns the key, so copy out.
  if !generic_key.is_empty() {
    return generic_key.to_owned()
  }
  if !provider_key.is_empty() {
    return provider_key.to_owned()
  }
  fail(
    "an API key is required for \{provider} models: pass --api-key or set \{env_var}",
  )
}
