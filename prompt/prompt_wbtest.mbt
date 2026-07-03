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
  assert_eq(system_prompt_for_model(V4Flash), flash_prompt())
  assert_eq(system_prompt_for_model(V4Pro), flash_prompt())
}

///|
test "goal continuation escapes objective XML and keeps placeholders literal" {
  let prompt = goal_continuation_prompt(
    objective="fix <parser> & keep {{tokens_used}} literal",
    tokens_used=42,
    token_budget=100,
  )
  // XML-escaped objective inside the tags.
  assert_true(
    prompt.contains("fix &lt;parser&gt; &amp; keep {{tokens_used}} literal"),
  )
  // The placeholder inside the user objective stayed literal: numeric
  // substitution ran before the objective was inserted.
  assert_false(prompt.contains("keep 42 literal"))
  // Budget numbers rendered.
  assert_true(prompt.contains("Tokens used: 42"))
  assert_true(prompt.contains("Token budget: 100"))
  assert_true(prompt.contains("Tokens remaining: 58"))
}

///|
test "goal continuation renders unbudgeted goals and the plan paragraph" {
  let bare = goal_continuation_prompt(objective="obj", tokens_used=7)
  assert_true(bare.contains("Token budget: none"))
  assert_true(bare.contains("Tokens remaining: unbounded"))
  assert_false(bare.contains("Progress visibility"))
  let with_plan = goal_continuation_prompt(
    objective="obj",
    tokens_used=7,
    has_plan_tool=true,
  )
  assert_true(with_plan.contains("Progress visibility"))
  assert_true(with_plan.contains("not evidence the goal is complete"))
}
