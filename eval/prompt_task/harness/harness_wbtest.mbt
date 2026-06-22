///|
async test "prepare output dir creates runner artifact directories" {
  @vfs.with_tmpdir(prefix="openseek-prompt-task-output", root => {
    let out_dir = root + "/out"
    prepare_output_dir(out_dir)
    assert_true(@fs.exists(out_dir + "/workspaces"))
    assert_true(@fs.exists(out_dir + "/logs"))
  })
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
test "trial task parser keeps single-stage tasks unchanged" {
  match parse_trial_task("hello\nworld\n") {
    Single(task) => assert_eq(task, "hello\nworld\n")
    Compact(_) => fail("unexpected compact task")
  }
}

///|
test "trial task parser splits one compact delimiter" {
  match parse_trial_task(" phase 1 \n--COMPACT--\n phase 2 ") {
    Compact(phases) => json_inspect(phases, content=["phase 1", "phase 2"])
    Single(_) => fail("expected compact task")
  }
}

///|
test "trial task parser accepts multiple compact delimiters" {
  match
    parse_trial_task(
      " phase 1 \n--COMPACT--\n phase 2 \n--COMPACT--\n phase 3 ",
    ) {
    Compact(phases) =>
      json_inspect(phases, content=["phase 1", "phase 2", "phase 3"])
    Single(_) => fail("expected compact task")
  }
}

///|
fn assert_empty_compact_phase_rejected(input : String) -> Unit raise {
  let _ = parse_trial_task(input) catch {
    Failure::Failure(message) => {
      assert_true(message.contains("empty phase"))
      return
    }
    _ => fail("unexpected error")
  }
  fail("accepted empty compact phase")
}

///|
test "trial task parser rejects empty compact phases" {
  assert_empty_compact_phase_rejected("--COMPACT--\nphase")
  assert_empty_compact_phase_rejected("phase\n--COMPACT--")
  assert_empty_compact_phase_rejected("a\n--COMPACT--\n\n--COMPACT--\nb")
}

///|
test "trial environment pins workspace-local session root" {
  let config = Config(
    api_key="key",
    model=V4Flash,
    problem_id="toml_parser_cli",
    runs=1,
    concurrency=1,
    min_successes=1,
    max_steps=12,
    out_dir="out",
    repo_root=".",
    prompt_label="label",
    task_file="task.md",
    validation_probes=default_toml_validation_probes(),
    system_prompt_file="",
    system_prompt_addendum_file="",
  )
  let env = trial_extra_env(config, "/tmp/workspace")
  guard env.get("OPENSEEK_SESSION_ROOT") is Some(root) else {
    fail("expected OPENSEEK_SESSION_ROOT")
  }
  assert_eq(root, ".openseek")
  guard env.get("OPENSEEK_GLOBAL_SKILLS_DIR") is Some(skills_dir) else {
    fail("expected OPENSEEK_GLOBAL_SKILLS_DIR")
  }
  assert_eq(skills_dir, "/tmp/workspace/.no-global-skills")
}
