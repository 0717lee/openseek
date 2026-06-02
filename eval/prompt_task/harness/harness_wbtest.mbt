///|
async test "indexed runner honors concurrency and preserves order" {
  let mut active = 0
  let mut max_active = 0
  let results = run_indexed_with_concurrency(5, 2, index => {
    active += 1
    if active > max_active {
      max_active = active
    }
    @async.sleep(20)
    active -= 1
    index
  })
  json_inspect(results, content=[0, 1, 2, 3, 4])
  assert_eq(max_active, 2)
}

///|
test "json stdout probe accepts valid json only" {
  assert_true(json_stdout_probe(0, "{\"a\":1}\n", "").passed)
  let invalid = json_stdout_probe(0, "not-json\n", "")
  assert_false(invalid.passed)
  assert_true(invalid.reason.contains("stdout is not JSON"))
}

///|
test "agent log summary reads jsonl events and ignores process noise" {
  let summary = summarize_agent_log(
    (
      #|Blocking waiting for file lock /tmp/.moon-lock ...
      #|{"event":"agent_step","step":1}
      #|{"event":"tool_result","tool_name":"write","is_error":true,"content":"failed"}
      #|{"event":"tool_result","tool_name":"shell","is_error":false,"content":"exit=0"}
      #|{"event":"agent_finished","answer":"ok"}
    ),
  )
  assert_true(summary.finished)
  assert_eq(summary.steps, 1)
  assert_eq(summary.tool_errors, 1)
  assert_eq(summary.shell_uses, 1)
}

///|
test "agent log summary falls back to legacy text markers" {
  let summary = summarize_agent_log(
    (
      #|tool: exit=0
      #|--- step 1 ---
      #|tool error: failed
      #|=== finished ===
    ),
  )
  assert_true(summary.finished)
  assert_eq(summary.steps, 1)
  assert_eq(summary.tool_errors, 1)
  assert_eq(summary.shell_uses, 1)
}

///|
test "trial evaluation uses jsonl finish and counters" {
  let validation : ValidationResult = {
    passed: true,
    reason: "ok",
    moon_check: true,
    moon_test: true,
    file_probe: true,
    stdin_probe: true,
    duplicate_probe: true,
  }
  let result = evaluate_trial(
    "flash",
    0,
    "ws",
    "log",
    0,
    (
      #|not json
      #|{"event":"agent_step","step":1}
      #|{"event":"tool_result","tool_name":"shell","is_error":false,"content":"exit=0"}
      #|{"event":"agent_finished","answer":"ok"}
    ),
    validation,
  )
  assert_true(result.success)
  assert_true(result.finished)
  assert_eq(result.reason, "ok")
  assert_eq(result.steps, 1)
  assert_eq(result.tool_errors, 0)
  assert_eq(result.warnings, "shell output observed 1 time(s)")
}

///|
test "markdown report includes concurrency and prompt label" {
  let report : EvalReport = {
    model: "deepseek-v4-flash",
    prompt_label: "flash",
    task_file: "eval/prompt_tasks/toml_parser_cli.md",
    runs: 1,
    concurrency: 1,
    min_successes: 1,
    successes: 1,
    out_dir: "out",
    results: [
      {
        index: 1,
        prompt_label: "flash",
        success: true,
        reason: "ok",
        workspace: "ws",
        log_path: "log",
        exit_code: 0,
        steps: 10,
        tool_errors: 0,
        finished: true,
        validation: {
          passed: true,
          reason: "ok",
          moon_check: true,
          moon_test: true,
          file_probe: true,
          stdin_probe: true,
          duplicate_probe: true,
        },
        moon_check_uses: 1,
        moon_test_uses: 1,
        moon_run_e_mentions: 1,
        moon_run_c_mentions: 0,
        bad_run_e_mentions: 0,
        from_str_mentions: 1,
        parse_int_mentions: 0,
        argparse_mentions: 1,
        old_argparse_mentions: 0,
        c_ffi_mentions: 0,
        env_args_mentions: 0,
        result_style_mentions: 0,
        try_mentions: 0,
        warnings: "",
      },
    ],
  }
  let text = report.markdown()
  assert_true(text.contains("flash"))
  assert_true(text.contains("concurrency"))
  assert_true(text.contains("File Probe"))
}
