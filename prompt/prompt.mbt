///|
/// Selects the built-in system prompt for a supported chat model.
///
/// Supported DeepSeek and Kimi model names currently share the Flash prompt.
/// The older base prompt remains in the package for comparison and prompt
/// experiments, but it is not selected by default.
pub fn system_prompt_for_model(_model : @deepseek.Model) -> String {
  flash_prompt()
}

///|
/// Render the goal continuation prompt injected (as hidden internal context)
/// at the start of every automatic goal turn.
///
/// Ported from Codex's goals/continuation.md: objective in `<objective>`
/// tags with XML-escaped text, budget numbers, scope-fidelity rules, an
/// evidence-based completion audit, and the repeated-impasse blocked rule.
/// When `has_plan_tool` is set (the registry exposes `plan`), a paragraph
/// asks the model to keep a concise plan current — and states that a fully
/// completed plan is never completion evidence.
pub fn goal_continuation_prompt(
  objective~ : String,
  tokens_used~ : Int,
  token_budget? : Int,
  has_plan_tool? : Bool = false,
) -> String {
  let escaped = objective
    .replace_all(old="&", new="&amp;")
    .replace_all(old="<", new="&lt;")
    .replace_all(old=">", new="&gt;")
  let (budget_text, remaining_text) = match token_budget {
    Some(budget) => {
      let remaining = budget - tokens_used
      (
        budget.to_string(),
        (if remaining < 0 { 0 } else { remaining }).to_string(),
      )
    }
    None => ("none", "unbounded")
  }
  // The objective is substituted LAST: it is user-controlled text, and an
  // objective containing a literal "{{tokens_used}}" must stay literal
  // instead of being rewritten by a later placeholder pass.
  let mut prompt = goal_continuation()
    .replace_all(old="{{tokens_used}}", new=tokens_used.to_string())
    .replace_all(old="{{token_budget}}", new=budget_text)
    .replace_all(old="{{remaining_tokens}}", new=remaining_text)
    .replace_all(old="{{objective}}", new=escaped)
  if has_plan_tool {
    prompt = prompt +
      (
        #|
        #|Progress visibility:
        #|If the next work is meaningfully multi-step, use the `plan` tool to show a concise plan tied to the real objective and keep it current as steps complete. Skip planning overhead for trivial one-step progress. A plan update is not a substitute for doing the work, and a plan with every step completed is not evidence the goal is complete — only the completion audit is.
      )
  }
  prompt
}
