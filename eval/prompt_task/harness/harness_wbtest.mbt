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
  assert_true(env.get("DEEPSEEK") == Some("key"))
  assert_true(env.get("KIMI") is None)
  let kimi_env = trial_extra_env(
    { ..config, model: KimiK27CodeHighSpeed },
    "/tmp/workspace",
  )
  assert_true(kimi_env.get("KIMI") == Some("key"))
  assert_true(kimi_env.get("DEEPSEEK") is None)
  guard env.get("OPENSEEK_SESSION_ROOT") is Some(root) else {
    fail("expected OPENSEEK_SESSION_ROOT")
  }
  assert_eq(root, ".openseek")
  guard env.get("OPENSEEK_GLOBAL_SKILLS_DIR") is Some(skills_dir) else {
    fail("expected OPENSEEK_GLOBAL_SKILLS_DIR")
  }
  assert_eq(skills_dir, "/tmp/workspace/.no-global-skills")
}

///|
test "empty api key leaves provider keys to the inherited environment" {
  // A cross-provider suite runs with an empty key so each trial inherits its
  // own DEEPSEEK/KIMI from the parent env; the harness must not pin either
  // variable to an empty string, which would shadow the inherited key.
  let config = Config(
    api_key="",
    model=V4Pro,
    problem_id="expr_eval",
    runs=1,
    concurrency=1,
    min_successes=0,
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
  assert_true(env.get("DEEPSEEK") is None)
  assert_true(env.get("KIMI") is None)
  let kimi_env = trial_extra_env(
    { ..config, model: KimiK27Code },
    "/tmp/workspace",
  )
  assert_true(kimi_env.get("KIMI") is None)
  assert_true(kimi_env.get("DEEPSEEK") is None)
}
