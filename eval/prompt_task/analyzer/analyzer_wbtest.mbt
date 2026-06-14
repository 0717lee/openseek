///|
fn sample_events() -> String {
  let session = @agent_session.Session(SessionId("trial-01"), system_prompt="")
    .append(User(UserMessage("build a toml cli")))
    .append(
      Assistant(
        AssistantMessage("I will run moon check", tool_calls=[
          ToolCall(
            id="call_1",
            name="moon_cmd",
            arguments="{\"command\":\"moon check\"}",
          ),
        ]),
      ),
    )
    .append(
      Tool(
        ToolResult(
          tool_call_id="call_1",
          tool_name="moon_cmd",
          content="moon check passed",
        ),
      ),
    )
    .append(Terminal(Finished("done")))
  let out = StringBuilder::new()
  for event in session.events() {
    out.write_string(event.to_json().stringify())
    out.write_char('\n')
  }
  out.to_string()
}

///|
test "session summary counts typed events" {
  let parsed = @session_log.parse_events(sample_events())
  let session = @session_log.session_from_parse(
    parsed,
    id="trial-01",
    system_prompt="",
  )
  let summary = summarize_session(session)
  assert_true(summary.finished)
  assert_eq(summary.steps, 1)
  assert_eq(summary.tool_results, 1)
  assert_eq(summary.tool_errors, 0)
  assert_eq(summary.shell_uses, 0)
  assert_eq(summary.runtime_notices, 0)
  assert_true(summary.text.contains("moon check"))
}

///|
test "eval session produces standalone result" {
  let parsed = @session_log.parse_events(sample_events())
  let session = @session_log.session_from_parse(
    parsed,
    id="trial-01",
    system_prompt="",
  )
  let result = eval_session(session)
  assert_true(result.success)
  assert_eq(result.session_id, "trial-01")
  assert_eq(result.steps, 1)
  assert_false(result.validation.ran)
  assert_true(result.markdown().contains("Prompt Task Eval Result"))
  assert_true(result.html().contains("<html"))
}

///|
test "shell result failure detection reads exit markers" {
  assert_false(shell_result_failed("exit=0\nok"))
  assert_true(shell_result_failed("exit=2\nfailed"))
}

///|
test "json stdout probe accepts valid json only" {
  assert_true(json_stdout_probe(0, "{\"a\":1}\n", "").passed)
  let invalid = json_stdout_probe(0, "not-json\n", "")
  assert_false(invalid.passed)
  assert_true(invalid.reason.contains("stdout is not JSON"))
}

///|
test "markdown report includes prompt label and parser metrics" {
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
        session_id: "trial-01",
        events_path: "events",
        exit_code: 0,
        steps: 1,
        tool_results: 1,
        tool_errors: 0,
        shell_uses: 0,
        shell_failures: 0,
        runtime_notices: 0,
        finished: true,
        finish_message: "done",
        terminal_status: "finished",
        terminal_message: "done",
        validation: {
          ran: true,
          passed: true,
          reason: "ok",
          moon_check: true,
          moon_test: true,
          file_probe: true,
          stdin_probe: true,
          duplicate_probe: true,
        },
        parse_errors: 0,
        partial_tail: false,
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
  assert_true(text.contains("Parse Errors"))
  assert_true(text.contains("## Trial Details"))
  assert_true(report.html().contains("<html"))
  assert_true(report.html().contains("trial-card"))
}
