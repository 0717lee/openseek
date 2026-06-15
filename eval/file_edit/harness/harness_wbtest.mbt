///|
async test "prepare output dir creates a missing output directory" {
  let root = @fs.tmpdir(prefix="openseek-file-edit-output")
  let out_dir = root + "/out"
  prepare_output_dir(out_dir)
  assert_true(@fs.exists(out_dir + "/workspaces"))
  assert_true(@fs.exists(out_dir + "/logs"))
  @fs.rmdir(root, recursive=true)
}

///|
async test "dry run exact replacement oracle" {
  let case = @cases.case_for_trial(0)
  let root = @fs.tmpdir(prefix="openseek-file-edit-harness")
  let workspace = root + "/workspace"
  let log_path = root + "/trial.log"
  @fs.mkdir(workspace, recursive=true)
  write_fixture(workspace, case)
  @vfs.FileSystem({ "src/note.txt": "alpha\ndelta\ngamma\n" }).write_to(
    workspace,
  )
  @fs.write_file(
    log_path,
    (
      $|--- step 1 ---
      $|tool: ok: replaced 1 occurrence
      $|=== finished ===
      $|file-edit-eval:\{case.id}
    ),
    create_mode=CreateOrTruncate,
  )
  let result = evaluate_trial(
    "builtin",
    0,
    case,
    workspace,
    log_path,
    0,
    @fs.read_file(log_path).text(),
  )
  assert_true(result.success)
  assert_eq(result.reason, "ok")
  assert_eq(result.prompt_label, "builtin")
  assert_eq(result.edit_successes, 1)
  assert_true(result.marker_present)
  @fs.rmdir(root, recursive=true)
}

///|
async test "dry run exact replacement oracle with jsonl agent log" {
  let case = @cases.case_for_trial(0)
  let root = @fs.tmpdir(prefix="openseek-file-edit-harness-jsonl")
  let workspace = root + "/workspace"
  let log_path = root + "/trial.log"
  @fs.mkdir(workspace, recursive=true)
  write_fixture(workspace, case)
  @vfs.FileSystem({ "src/note.txt": "alpha\ndelta\ngamma\n" }).write_to(
    workspace,
  )
  @fs.write_file(
    log_path,
    (
      $|not json
      $|{"event":"agent_step","step":1}
      $|{"event":"tool_result","tool_name":"edit","is_error":false,"content":"ok: replaced 1 occurrence"}
      $|{"event":"tool_result","tool_name":"shell","is_error":false,"content":"exit=0"}
      $|{"event":"agent_finished","answer":"file-edit-eval:\{case.id}"}
    ),
    create_mode=CreateOrTruncate,
  )
  let result = evaluate_trial(
    "builtin",
    0,
    case,
    workspace,
    log_path,
    0,
    @fs.read_file(log_path).text(),
  )
  assert_true(result.success)
  assert_eq(result.steps, 1)
  assert_eq(result.tool_errors, 0)
  assert_eq(result.shell_uses, 1)
  assert_eq(result.edit_successes, 1)
  assert_true(result.marker_present)
  assert_eq(result.warnings, "shell tool used 1 time(s)")
  @fs.rmdir(root, recursive=true)
}

///|
test "count_occurrences counts non-overlapping markers" {
  assert_eq(count_occurrences("tool error: a\ntool error: b", "tool error:"), 2)
  assert_eq(count_occurrences("abc", "z"), 0)
}

///|
test "line counter documents all-match behavior" {
  let log_text =
    #|command=moon run -e fn main {}
    #|command=moon run -c fn main {}
    #|command=moon test
    #|note=moon run without command prefix
  debug_inspect(
    [
      count_lines_containing_all(log_text, ["command=moon "]),
      count_lines_containing_all(log_text, ["moon run", " -e"]),
      count_lines_containing_all(log_text, ["moon run", " -c"]),
      count_lines_containing_all(log_text, ["command=moon ", "missing"]),
      count_lines_containing_all("a\nb\n", []),
    ],
    content="[3, 1, 1, 0, 3]",
  )
}

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
test "log monitor counts prompt-sensitive moon commands" {
  let log_text =
    #|tool: cwd=.
    #|command=moon run -e fn main { println("ok") }
    #|exit=0
    #|tool error: cwd=.
    #|command=moon run -c fn main { println("old") }
    #|exit=1
    #|tool: cwd=.
    #|command=moon check
    #|exit=0
    #|tool: cwd=.
    #|command=moon test
    #|exit=0
    #|tool: cwd=.
    #|command=moon info
    #|exit=0
    #|tool: cwd=.
    #|command=moon fmt
    #|exit=0
  assert_eq(count_lines_containing_all(log_text, ["command=moon "]), 6)
  assert_eq(count_lines_containing_all(log_text, ["moon run", " -e"]), 1)
  assert_eq(count_lines_containing_all(log_text, ["moon run", " -c"]), 1)
  assert_eq(count_lines_containing_all(log_text, ["command=moon check"]), 1)
  assert_eq(count_lines_containing_all(log_text, ["command=moon test"]), 1)
  assert_eq(count_lines_containing_all(log_text, ["command=moon info"]), 1)
  assert_eq(count_lines_containing_all(log_text, ["command=moon fmt"]), 1)
}

///|
test "markdown report summarizes threshold" {
  let report : EvalReport = {
    model: "deepseek-v4-flash",
    prompt_label: "builtin",
    runs: 1,
    concurrency: 1,
    min_successes: 1,
    successes: 1,
    out_dir: "out",
    results: [
      {
        index: 1,
        case_id: "exact_replace",
        prompt_label: "builtin",
        success: true,
        reason: "ok",
        workspace: "ws",
        log_path: "log",
        exit_code: 0,
        steps: 3,
        tool_errors: 0,
        shell_uses: 0,
        moon_cmd_uses: 1,
        moon_run_e_mentions: 1,
        moon_run_c_mentions: 0,
        moon_check_uses: 1,
        moon_test_uses: 0,
        moon_info_uses: 0,
        moon_fmt_uses: 0,
        edit_successes: 1,
        write_successes: 0,
        validation_passed: true,
        marker_present: true,
        warnings: "",
      },
    ],
  }
  let text = report.markdown()
  assert_true(text.contains("1/1"))
  assert_true(text.contains("builtin"))
  assert_true(text.contains("exact_replace"))
}
