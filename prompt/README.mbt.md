# OpenSeek Prompt

This package owns OpenSeek's built-in system prompt text and prompt-selection
policy. Prompt Markdown files are converted to generated MoonBit string
functions through the module-level `md_to_mbt_string` dev-build rule.

## Prompt Sources

- `flash_prompt.mbt.md`: the default built-in prompt used by DeepSeek V4
  Flash and DeepSeek V4 Pro.
- `base_prompt.mbt.md`: the older built-in prompt, retained for comparison and
  prompt experiments but not selected by default.

## API Shape

- `system_prompt_for_model(model)`: return the default built-in prompt for a
  DeepSeek model. Both current V4 models use the Flash prompt.

The agent package depends on this package for its default prompt, while the CLI
can still override or append prompt files for A/B experiments.
