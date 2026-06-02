# Verified OpenSeek CLI Documentation

These examples are executed by `moon cram test tests/cram`. The Moon wrapper
builds the native package at `cmd/openseek` first, then exposes the executable
on `PATH` as `openseek.exe`.

Every command here is offline: it either prints help or fails argument
validation before the agent contacts DeepSeek, so the suite needs no API key and
makes no network calls. The live, API-backed examples live in
[`tests/live/deepseek.md`](../live/deepseek.md).

## Help Banner

`--help` prints the full usage, the available options, and the environment
variables and defaults behind each one, then exits successfully.

```mooncram
$ openseek.exe --help
Usage: openseek --api-key <api-key> [options] <task...>

DeepSeek-backed MoonBit coding agent.

Arguments:
  task...  Task description.

Options:
  -h, --help                                                   Show help information.
  --api-key <api-key>                                          DeepSeek API key. [env: DEEPSEEK]
  --model <model>                                              DeepSeek model: deepseek-v4-flash or deepseek-v4-pro. [env: DEEPSEEK_MODEL] [default: deepseek-v4-pro]
  --max-steps <max-steps>                                      Maximum number of agent loop steps before stopping. [env: OPENSEEK_MAX_STEPS] [default: 1000]
  --system-prompt-file <system-prompt-file>                    Read the complete system prompt from this file instead of the built-in prompt. [env: OPENSEEK_SYSTEM_PROMPT_FILE] [default: ]
  --system-prompt-addendum-file <system-prompt-addendum-file>  Append this file to the selected system prompt for prompt experiments. [env: OPENSEEK_SYSTEM_PROMPT_ADDENDUM_FILE] [default: ]
```

## A DeepSeek API Key Is Required

With no `--api-key` flag and no `DEEPSEEK` in the environment, the CLI reports
the missing required argument, prints the usage to help the caller, and exits
non-zero.

```mooncram
$ env -u DEEPSEEK openseek.exe "summarize this project"
error: the following required argument was not provided: 'api-key'

Usage: openseek --api-key <api-key> [options] <task...>

DeepSeek-backed MoonBit coding agent.

Arguments:
  task...  Task description.

Options:
  -h, --help                                                   Show help information.
  --api-key <api-key>                                          DeepSeek API key. [env: DEEPSEEK]
  --model <model>                                              DeepSeek model: deepseek-v4-flash or deepseek-v4-pro. [env: DEEPSEEK_MODEL] [default: deepseek-v4-pro]
  --max-steps <max-steps>                                      Maximum number of agent loop steps before stopping. [env: OPENSEEK_MAX_STEPS] [default: 1000]
  --system-prompt-file <system-prompt-file>                    Read the complete system prompt from this file instead of the built-in prompt. [env: OPENSEEK_SYSTEM_PROMPT_FILE] [default: ]
  --system-prompt-addendum-file <system-prompt-addendum-file>  Append this file to the selected system prompt for prompt experiments. [env: OPENSEEK_SYSTEM_PROMPT_ADDENDUM_FILE] [default: ]

[1]
```
