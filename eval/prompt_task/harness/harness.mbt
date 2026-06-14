///|
/// Run prompt-task experiments and immediately analyze them. This keeps the
/// previous one-call API available; new callers that want a pure experiment
/// phase should call `run_experiments` and run the analyzer separately.
pub async fn run_suite(config : Config) -> @analyzer.EvalReport {
  let manifest = run_experiments(config)
  @analyzer.analyze_manifest(manifest)
}

///|
/// Run the prompt task `config.runs` times, `config.concurrency` at a time,
/// writing only durable artifacts: workspaces, raw process logs, recorded
/// session `events.jsonl` files, and a run manifest. No validation or report
/// analysis is performed in this phase.
pub async fn run_experiments(config : Config) -> @manifest.RunManifest {
  if config.api_key == "" {
    fail("api_key is required for running trials")
  }
  prepare_output_dir(config.out_dir)
  let task_template = @fs.read_file(config.task_file).text()
  let trials = run_indexed_with_concurrency(config.runs, config.concurrency, index => {
    run_trial(config, task_template, index)
  })
  let manifest = @manifest.RunManifest(
    model=config.model.to_string(),
    prompt_label=config.prompt_label,
    task_file=config.task_file,
    runs=config.runs,
    concurrency=config.concurrency,
    min_successes=config.min_successes,
    max_steps=config.max_steps,
    out_dir=config.out_dir,
    trials~,
  )
  @manifest.write_manifest(manifest)
  manifest
}

///|
async fn prepare_output_dir(out_dir : String) -> Unit {
  if @fs.exists(out_dir) {
    @fs.rmdir(out_dir, recursive=true)
  }
  @fs.mkdir(out_dir + "/workspaces", recursive=true)
  @fs.mkdir(out_dir + "/logs", recursive=true)
  @fs.mkdir(out_dir + "/session_store", recursive=true)
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
  task_template : String,
  index : Int,
) -> @manifest.TrialArtifact {
  let trial_name = padded_index(index + 1)
  let workspace = config.out_dir + "/workspaces/" + trial_name
  @fs.mkdir(workspace, recursive=true)
  let real_workspace = @fs.realpath(workspace)
  let real_out_dir = @fs.realpath(config.out_dir)
  let session_root = real_out_dir + "/session_store"
  let session_id = "trial-" + trial_name
  let events_path = session_root + "/sessions/" + session_id + "/events.jsonl"
  let task = task_template.replace_all(old="{{WORKSPACE}}", new=real_workspace)
  // The engine runs *in* the trial workspace, so the prompt's environment
  // grounding names the workspace rather than the OpenSeek checkout — and
  // relative paths in the model's tool calls land in the right tree.
  // Launcher-relative paths (the default --repo-root ".", the engine
  // binary, prompt files) must be canonicalized before the child cwd
  // changes their meaning.
  let repo_root = @fs.realpath(config.repo_root)
  let (program, args) = if config.engine != "" {
    (@fs.realpath(config.engine), [])
  } else {
    ("moon", ["run", repo_root + "/cmd/openseek", "--"])
  }
  args.append([
    "--max-steps",
    config.max_steps.to_string(),
    "--model",
    config.model.to_string(),
    "--session-root",
    session_root,
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
  args.push(task)
  let (exit_code, output) = @process.collect_output_merged(
    program,
    args,
    extra_env={
      "DEEPSEEK": config.api_key,
      "DEEPSEEK_MODEL": config.model.to_string(),
      "OPENSEEK_MAX_STEPS": config.max_steps.to_string(),
      "OPENSEEK_GLOBAL_SKILLS_DIR": real_workspace + "/.no-global-skills",
    },
    inherit_env=true,
    cwd=real_workspace,
  )
  let log_path = config.out_dir + "/logs/" + trial_name + ".log"
  @fs.write_file(log_path, output.text(), create_mode=CreateOrTruncate)
  TrialArtifact(
    index=index + 1,
    workspace=real_workspace,
    log_path~,
    session_root~,
    session_id~,
    events_path~,
    exit_code~,
  )
}

///|
fn padded_index(value : Int) -> String {
  if value < 10 {
    "0" + value.to_string()
  } else {
    value.to_string()
  }
}
