///|
/// Selects the built-in system prompt for a DeepSeek model.
///
/// Both DeepSeek V4 models currently share the Flash prompt. The older base
/// prompt remains in the package for comparison and prompt experiments, but it
/// is not selected by default.
pub fn system_prompt_for_model(_model : @deepseek.Model) -> String {
  flash_prompt()
}
