# OpenSeek Prompt

This package owns OpenSeek's built-in system prompt text and prompt-selection
policy. Prompt Markdown files are converted to generated MoonBit string
functions through the module-level `md_to_mbt_string` dev-build rule.

## Prompt Sources

- `default_prompt.mbt.md`: the default built-in prompt used by the supported
  DeepSeek and Kimi model names.
- `base_prompt.mbt.md`: the older built-in prompt, retained for comparison and
  prompt experiments but not selected by default.

## API Shape

- `system_prompt_for_model(model)`: return the default built-in prompt for a
  supported chat model. The supported DeepSeek and Kimi model names all use
  `default_prompt.mbt.md`.

The agent package depends on this package for its default prompt, while the CLI
can still override or append prompt files for A/B experiments.
