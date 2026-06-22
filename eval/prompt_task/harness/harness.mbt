///|
const CompactDelimiter : String = "\n--COMPACT--\n"

///|
priv enum TrialTask {
  Single(String)
  Compact(Array[String])
}

///|
fn parse_trial_task(task_template : String) -> TrialTask raise {
  let bounded = "\n\{task_template}\n"
  if !bounded.contains(CompactDelimiter) {
    return Single(task_template)
  }
  let phases = [
    for part in bounded.split(CompactDelimiter) => {
      let phase = part.trim().to_owned()
      if phase.is_empty() {
        fail("task file contains an empty phase around --COMPACT--")
      }
      phase
    }
  ]
  Compact(phases)
}

///|
async fn run_compact_task(
  config : Config,
  phases : Array[String],
  session_id~ : String,
  workspace~ : String,
  repo_root~ : String,
  log_path~ : String,
) -> Int {
  let log = StringBuilder::new()
  let mut exit_code = 0
  let phase_count = phases.length()
  for index, phase in phases {
    let phase_prompt = replace_workspace(phase, workspace)
    let phase_result = run_openseek_turn(
      config,
      phase_prompt,
      session_id~,
      workspace~,
      repo_root~,
    )
    append_log_section(log, "phase\{index + 1}", phase_result)
    if exit_code == 0 && phase_result.0 != 0 {
      exit_code = phase_result.0
    }
    if index + 1 < phase_count {
      let compact_result = run_compaction(
        config,
        session_id~,
        workspace~,
        repo_root~,
      )
      let label = if phase_count == 2 {
        "compact"
      } else {
        "compact\{index + 1}"
      }
      append_log_section(log, label, compact_result)
      if exit_code == 0 && compact_result.0 != 0 {
        exit_code = compact_result.0
      }
    }
  }
  @fs.write_file(log_path, log.to_string(), create_mode=CreateOrTruncate)
  exit_code
}

///|
/// Run the prompt task `config.runs` times, `config.concurrency` at a time,
/// writing only durable artifacts: workspaces, raw process logs, recorded
/// session `events.jsonl` files, and a run manifest. No validation or report
/// analysis is performed in this phase.
pub async fn run_experiments(config : Config) -> RunManifest {
  if config.api_key == "" {
    fail("api_key is required for running trials")
  }
  let task = parse_trial_task(@fs.read_file(config.task_file).text())
  prepare_output_dir(config.out_dir)
  let trials = run_indexed_with_concurrency(config.runs, config.concurrency, index => {
    run_trial(config, task, index)
  })
  let manifest = RunManifest(
    model=config.model.to_string(),
    problem_id=config.problem_id,
    prompt_label=config.prompt_label,
    task_file=config.task_file,
    runs=config.runs,
    concurrency=config.concurrency,
    min_successes=config.min_successes,
    max_steps=config.max_steps,
    out_dir=config.out_dir,
    validation_probes=config.validation_probes,
    trials~,
  )
  write_manifest(manifest)
  manifest
}

///|
async fn prepare_output_dir(out_dir : String) -> Unit {
  if @fs.exists(out_dir) {
    @fs.rmdir(out_dir, recursive=true)
  }
  @fs.mkdir("\{out_dir}/workspaces", recursive=true)
  @fs.mkdir("\{out_dir}/logs", recursive=true)
}

///|
async fn[X] run_indexed_with_concurrency(
  count : Int,
  concurrency : Int,
  run : async (Int) -> X,
) -> Array[X] {
  let limit = @async.Semaphore(concurrency)
  @async.all(
    [
      for index in 0..<count => {
        () => {
          limit.acquire()
          defer limit.release()
          run(index)
        }
      }
    ],
  )
}

///|
async fn run_trial(
  config : Config,
  task : TrialTask,
  index : Int,
) -> TrialArtifact {
  let trial_name = padded_index(index + 1)
  let workspace = "\{config.out_dir}/workspaces/\{trial_name}"
  @fs.mkdir(workspace, recursive=true)
  let real_workspace = @fs.realpath(workspace)
  let session_id = "trial-\{trial_name}"
  // The engine runs from the OpenSeek checkout and receives --dir for the
  // isolated trial workspace. This keeps launcher-relative paths stable while
  // ensuring the agent's session store and tool cwd live under the workspace.
  let repo_root = @fs.realpath(config.repo_root)
  let log_path = "\{config.out_dir}/logs/\{trial_name}.log"
  let exit_code = run_trial_task(
    config,
    task,
    session_id~,
    workspace=real_workspace,
    repo_root~,
    log_path~,
  )
  let events_path = discover_session_events(
    real_workspace,
    session_id,
    fallback="\{real_workspace}/.openseek/sessions/\{session_id}/events.jsonl",
  )
  TrialArtifact(
    index=index + 1,
    workspace=real_workspace,
    log_path~,
    session_id~,
    events_path~,
    exit_code~,
  )
}

///|
async fn run_trial_task(
  config : Config,
  task : TrialTask,
  session_id~ : String,
  workspace~ : String,
  repo_root~ : String,
  log_path~ : String,
) -> Int {
  match task {
    Single(task_template) => {
      let prompt = replace_workspace(task_template, workspace)
      let (exit_code, output) = run_openseek_turn(
        config,
        prompt,
        session_id~,
        workspace~,
        repo_root~,
      )
      @fs.write_file(log_path, output, create_mode=CreateOrTruncate)
      exit_code
    }
    Compact(phases) =>
      run_compact_task(
        config,
        phases,
        session_id~,
        workspace~,
        repo_root~,
        log_path~,
      )
  }
}

///|
async fn run_openseek_turn(
  config : Config,
  prompt : String,
  session_id~ : String,
  workspace~ : String,
  repo_root~ : String,
) -> (Int, String) {
  let (program, args) = openseek_command(config, repo_root~)
  append_common_openseek_args(args, config, session_id~, workspace~)
  args.push(prompt)
  let (exit_code, output) = @process.collect_output_merged(
    program,
    args,
    extra_env=trial_extra_env(config, workspace),
    inherit_env=true,
    cwd=repo_root,
  )
  (exit_code, output.text())
}

///|
async fn run_compaction(
  config : Config,
  session_id~ : String,
  workspace~ : String,
  repo_root~ : String,
) -> (Int, String) {
  let command_path = workspace + "/.openseek-compact-command.jsonl"
  @fs.write_file(
    command_path,
    "{\"command\":\"compact\"}\n",
    create_mode=CreateOrTruncate,
  )
  let stdin = @process.redirect_from_file(command_path)
  let (program, args) = openseek_command(config, repo_root~)
  append_common_openseek_args(args, config, session_id~, workspace~)
  args.push("--serve")
  let (exit_code, output) = @process.collect_output_merged(
    program,
    args,
    stdin~,
    extra_env=trial_extra_env(config, workspace),
    inherit_env=true,
    cwd=repo_root,
  )
  (exit_code, output.text())
}

///|
async fn openseek_command(
  config : Config,
  repo_root~ : String,
) -> (String, Array[String]) {
  if config.engine != "" {
    (@fs.realpath(config.engine), [])
  } else {
    ("moon", ["run", "--target", "native", "\{repo_root}/cmd/openseek", "--"])
  }
}

///|
async fn append_common_openseek_args(
  args : Array[String],
  config : Config,
  session_id~ : String,
  workspace~ : String,
) -> Unit {
  args.append([
    "--max-steps",
    config.max_steps.to_string(),
    "--model",
    config.model.to_string(),
    "--dir",
    workspace,
    "--session",
    session_id,
  ])
  if config.system_prompt_file != "" {
    args.push("--system-prompt-file")
    args.push(@fs.realpath(config.system_prompt_file))
  }
  if config.system_prompt_addendum_file != "" {
    args.push("--system-prompt-addendum-file")
    args.push(@fs.realpath(config.system_prompt_addendum_file))
  }
}

///|
fn append_log_section(
  log : StringBuilder,
  label : String,
  result : (Int, String),
) -> Unit {
  log.write_string("===== ")
  log.write_string(label)
  log.write_string(" exit=")
  log.write_string(result.0.to_string())
  log.write_string(" =====\n")
  log.write_string(result.1)
  if !result.1.has_suffix("\n") {
    log.write_char('\n')
  }
}

///|
fn trial_extra_env(
  config : Config,
  real_workspace : String,
) -> Map[String, String] {
  {
    "DEEPSEEK": config.api_key,
    "DEEPSEEK_MODEL": config.model.to_string(),
    "OPENSEEK_MAX_STEPS": config.max_steps.to_string(),
    "OPENSEEK_SESSION_ROOT": ".openseek",
    "OPENSEEK_GLOBAL_SKILLS_DIR": "\{real_workspace}/.no-global-skills",
  }
}

///|
async fn discover_session_events(
  workspace : String,
  session_id : String,
  fallback~ : String,
) -> String {
  let matches : Array[String] = []
  collect_session_events(workspace, session_id, matches)
  if matches.length() > 0 {
    matches[0]
  } else {
    fallback
  }
}

///|
async fn collect_session_events(
  dir : String,
  session_id : String,
  matches : Array[String],
) -> Unit {
  guard is_directory(dir) else { return }
  let names = @fs.readdir(dir, sort=true) catch { _ => return }
  for name in names {
    if should_skip_scan_dir(name) {
      continue
    }
    let path = "\{dir}/\{name}"
    if is_directory(path) {
      collect_session_events(path, session_id, matches)
    } else if name == "events.jsonl" &&
      path.contains("/sessions/\{session_id}/") {
      matches.push(path)
    }
  }
}

///|
async fn is_directory(path : String) -> Bool {
  (@fs.kind(path, follow_symlink=false) catch { _ => return false }) ==
  Directory
}

///|
fn should_skip_scan_dir(name : String) -> Bool {
  name == ".git" ||
  name == "node_modules" ||
  name == ".mooncakes" ||
  name == "_build"
}

///|
fn padded_index(value : Int) -> String {
  if value < 10 {
    "0\{value}"
  } else {
    value.to_string()
  }
}
