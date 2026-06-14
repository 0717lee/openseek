# Prompt Task Eval

This harness runs a MoonBit prompt task through the real OpenSeek agent with
isolated workspaces, per-trial raw logs, durable session `events.jsonl` logs,
and bounded parallelism. Reporting is a separate analyzer pass, so reports can
be regenerated without rerunning model/API trials.

The default task is `eval/prompt_tasks/toml_parser_cli.md`. The runner replaces
`{{WORKSPACE}}` in the task template with each trial workspace path and starts
the agent with an explicit per-trial session id. The analyzer loads the run
manifest and session logs, then independently validates the final TOML project
with:

- `moon check --target native`
- `moon test --target native`
- file-input `cmd/tomljson` JSON probe
- stdin `cmd/tomljson` JSON probe
- duplicate-key invalid-input probe with no panic/debug stack

Run five Flash TOML trials concurrently:

```bash
moon run eval/prompt_task/cmd/main -- \
  --api-key "$DEEPSEEK" \
  --model deepseek-v4-flash \
  --runs 5 \
  --concurrency 5 \
  --min-successes 5 \
  --max-steps 160 \
  --prompt-label flash-current \
  --out .moonagent/eval_runs/toml_flash_current_5x
```

Analyze the finished run later:

```bash
moon run eval/prompt_task/cmd/main -- \
  --analyze-only \
  --out .moonagent/eval_runs/toml_flash_current_5x
```

For the old one-step behavior, add `--run-and-analyze` to the run command.

Run an A/B comparison by using different output directories and prompt labels:

```bash
moon run eval/prompt_task/cmd/main -- \
  --api-key "$DEEPSEEK" \
  --model deepseek-v4-flash \
  --runs 5 \
  --concurrency 5 \
  --min-successes 5 \
  --max-steps 160 \
  --prompt-label flash-candidate \
  --system-prompt-file prompt/flash_prompt.md \
  --out .moonagent/eval_runs/toml_flash_candidate_5x
```

The runner writes `run_manifest.json`, `workspaces/`, `logs/`, and
`session_store/`. The analyzer writes `report.md`, `report.json`, and
`report.html`; the report records success rate, typed-session metrics,
validation pass/fail, prompt-sensitive counters, and paths to each raw log.
