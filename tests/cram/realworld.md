# OpenSeek Real-World CLI

This page is both documentation and an executable cram test for the native CLI.
It exercises the real DeepSeek API, so it requires MoonBit nightly because
`moon cram` is currently nightly-only.

Moon Cram runs the examples in an isolated work directory. To call the real API,
put the key in that work directory before running the document:

```bash
work_dir="$(mktemp -d)"
printf 'export DEEPSEEK=%q\n' "$DEEPSEEK" > "$work_dir/.deepseek_env"
moon cram test --work-directory "$work_dir" tests/cram/realworld.md
```

The API-backed path is the intended path for CI and maintainer runs. The
fallback branches below only keep this documentation executable in local clones
where no secret has been copied into the cram work directory.

## Cram Setup

The test runner puts `openseek.exe` on `PATH`. These setup commands locate the
checkout, name the fixture directory, and load the optional API key.

```mooncram
$ openseek_cli="$(command -v openseek.exe)"
```

```mooncram
$ repo_root="${openseek_cli%/_build/native/*/build/cmd/openseek/openseek.exe}"
```

```mooncram
$ fixtures="$repo_root/tests/cram/fixtures"
```

```mooncram
$ if [ -f .deepseek_env ]; then . ./.deepseek_env; fi
```

## V4 Pro Smoke Test

The CLI reads the API key from `DEEPSEEK`, uses `DEEPSEEK_MODEL`, and completes
a small task through the real agent loop. JSONL is the default log format, so
the output can be saved with `tee` and queried with `jq`.

```mooncram
$ if [ -n "${DEEPSEEK:-}" ]; then
>   # Real test path: call DeepSeek V4 Pro and write the JSONL transcript.
>   DEEPSEEK_MODEL=deepseek-v4-pro OPENSEEK_MAX_STEPS=4 \
>     openseek.exe "$(cat "$fixtures/pro-task.txt")" | tee pro.jsonl >/dev/null
> else
>   # Local dry-run path: keep the documentation runnable without secrets.
>   printf '{"event":"skip","reason":"local cram dry run"}\n' > pro.jsonl
> fi
```

The JSONL log stays in the cram work directory. On the real path, the following
queries see `step`, `usage`, and `finish` records while the run is still fresh
on disk.

```mooncram
$ jq -r 'select(.event == "step" or .event == "skip") | .reason // "step=\(.step)"' pro.jsonl | head -n 1
(step=1|local cram dry run) (re)
```

```mooncram
$ jq -r 'select(.event == "usage" or .event == "skip") | .reason // "prompt_tokens=\(.prompt_tokens)"' pro.jsonl | head -n 1
(prompt_tokens=[1-9][0-9]*|local cram dry run) (re)
```

```mooncram
$ jq -r 'select(.event == "finish" or .event == "skip") | .answer // .reason' pro.jsonl | tail -n 1
(.*OPENSEEK_CRAM_PRO_OK.*|local cram dry run) (re)
```

## Prompt File Override

The prompt override path is also covered end to end: the CLI reads a local
system prompt file, still authenticates with `DEEPSEEK`, and reaches a final
answer.

```mooncram
$ if [ -n "${DEEPSEEK:-}" ]; then
>   # Real test path: verify prompt-file override against DeepSeek V4 Pro.
>   openseek.exe --model deepseek-v4-pro --max-steps 4 \
>     --system-prompt-file "$fixtures/prompt-system.md" \
>     "$(cat "$fixtures/prompt-task.txt")" | tee prompt-file.jsonl >/dev/null
> else
>   # Local dry-run path: keep the documentation runnable without secrets.
>   printf '{"event":"skip","reason":"local cram dry run"}\n' > prompt-file.jsonl
> fi
```

```mooncram
$ jq -r 'select(.event == "step" or .event == "skip") | .reason // "step=\(.step)"' prompt-file.jsonl | head -n 1
(step=1|local cram dry run) (re)
```

```mooncram
$ jq -r 'select(.event == "finish" or .event == "skip") | .answer // .reason' prompt-file.jsonl | tail -n 1
(.*OPENSEEK_CRAM_PROMPT_FILE_OK.*|local cram dry run) (re)
```
