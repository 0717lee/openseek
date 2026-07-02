///|
/// The built-in system prompt is currently model-independent: every DeepSeek
/// model receives the flash prompt. (The base prompt stays in the package for
/// prompt experiments but is not selected by default.)
///
/// Prompt *wording* is authored in `flash_prompt.mbt.md` and its quality is
/// exercised end-to-end by the `eval/prompt_task` suite. Asserting on
/// individual phrases of the generated prompt here only mirrors that document
/// and breaks on every rewording, so this package pins just the selection
/// contract.
test "system_prompt_for_model returns the flash prompt for every model" {
  assert_eq(system_prompt_for_model(Deepseek(V4Flash)), flash_prompt())
  assert_eq(system_prompt_for_model(Deepseek(V4Pro)), flash_prompt())
}
