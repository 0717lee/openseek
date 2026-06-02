# OpenSeek CLI

This package is the native-only command-line entry point for OpenSeek. It parses
arguments with `moonbitlang/core/argparse`, reads defaults from environment
variables, and calls `bobzhang/openseek/agent.run`.

## Command

```bash
moon run cmd/openseek -- [--api-key sk-...] [--model deepseek-v4-pro] [--max-steps 1000] [--system-prompt-file prompt.md] [--system-prompt-addendum-file addendum.md] "task text"
```

`--api-key` can also be supplied with `DEEPSEEK`. `--model` can also be supplied
with `DEEPSEEK_MODEL`; it defaults to `deepseek-v4-pro`. `--max-steps` can also
be supplied with `OPENSEEK_MAX_STEPS`; it defaults to `1000`.
`--system-prompt-file` and `--system-prompt-addendum-file` can also be supplied
with `OPENSEEK_SYSTEM_PROMPT_FILE` and
`OPENSEEK_SYSTEM_PROMPT_ADDENDUM_FILE`.

Without an explicit prompt file, the CLI selects the built-in prompt by model:
`deepseek-v4-flash` uses `prompt/flash_prompt.md`; `deepseek-v4-pro` uses
`prompt/base_prompt.md`.

## Examples

```bash
export DEEPSEEK=sk-...
moon run cmd/openseek -- "run moon test and summarize the result"
```

```bash
DEEPSEEK_MODEL=deepseek-v4-flash moon run cmd/openseek -- "inspect the package docs"
```

```bash
moon run cmd/openseek -- --max-steps 200 "write tests, fix failures, and summarize"
```

## Package Boundary

This package should stay thin: argument parsing, environment-backed defaults,
model parsing, prompt override file loading, and delegation to `@agent.run`.
The prompt package owns built-in prompt selection; the agent package owns tool
definitions and the execution loop.

Run the package tests with:

```bash
moon test cmd/openseek
```
