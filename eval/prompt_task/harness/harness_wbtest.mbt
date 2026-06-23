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

///|
fn claude_jsonl_fixture_for_test() -> String {
  let user_prompt : Json = {
    "type": "user",
    "message": { "role": "user", "content": "inspect parser behavior" },
  }
  let assistant_call : Json = {
    "type": "assistant",
    "message": {
      "role": "assistant",
      "content": [
        {
          "type": "tool_use",
          "id": "toolu_read_1",
          "name": "Read",
          "input": { "file_path": "parser.mbt" },
        },
      ],
    },
  }
  let tool_result : Json = {
    "type": "user",
    "message": {
      "role": "user",
      "content": [
        {
          "type": "tool_result",
          "tool_use_id": "toolu_read_1",
          "content": "parse_expr currently accepts trailing commas",
        },
      ],
    },
  }
  user_prompt.stringify() +
  "\n" +
  assistant_call.stringify() +
  "\n" +
  tool_result.stringify() +
  "\n"
}

///|
async test "claude jsonl fixture seeds session and injects recall needle" {
  @vfs.with_tmpdir(prefix="openseek-prompt-task-fixture", root => {
    let transcript = root + "/claude.jsonl"
    let workspace = root + "/workspace"
    @fs.mkdir(workspace, recursive=true)
    @fs.write_file(
      transcript,
      claude_jsonl_fixture_for_test(),
      create_mode=CreateOrTruncate,
    )
    seed_session_fixture(
      SessionFixtureSpec(
        format="claude-jsonl",
        path=transcript,
        target_bytes=80,
        needle_id="COMPACT-ACTIVE-WORK-742",
        needle_text="cancelled compaction must emit compaction_failed",
        answer_file="{{WORKSPACE}}/answer.json",
      ),
      session_id="trial-01",
      workspace~,
      system_prompt="system",
    )
    let loaded = @store.SessionStore(workspace + "/.openseek").load(
      SessionId("trial-01"),
    )
    assert_eq(loaded.events().length(), 3)
    guard loaded.events()[1].item() is Assistant(message) else {
      fail("expected assistant tool call")
    }
    assert_eq(message.tool_calls().length(), 1)
    assert_eq(message.tool_calls()[0].name, "Read")
    let mut found_needle = false
    let mut found_answer_file = false
    for chat in loaded.chat_messages() {
      if chat.content.contains("BENCHMARK_DECISION_ID: COMPACT-ACTIVE-WORK-742") {
        found_needle = true
      }
      if chat.content.contains(workspace + "/answer.json") {
        found_answer_file = true
      }
    }
    assert_true(found_needle)
    assert_true(found_answer_file)
  })
}
