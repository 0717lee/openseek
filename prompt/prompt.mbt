///|
/// Selects the built-in system prompt for a supported chat model.
///
/// Supported DeepSeek and Kimi model names currently share the default
/// prompt. The older base prompt remains in the package for comparison and
/// prompt experiments, but it is not selected by default.
pub fn system_prompt_for_model(_model : @deepseek.Model) -> String {
  default_prompt()
}
