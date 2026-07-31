///|
/// The parent-facing `subtask` tool: delegate ONE slice of write-capable
/// work to a confined worker subagent in its own git worktree, then
/// integrate the validated result. Launching provisions the worktree,
/// spawns `subrun worker`, and CAPTURES the outcome from git evidence
/// (never the child's claims); `integrate`/`integrate_continue`/
/// `integrate_abort`/`discard` drive the committed branch's lifecycle.
/// Lives in the CLI (like the review tool) because it needs the session's
/// self-exe, model, and durable-session plumbing.
let max_active_workers : Int = 4

///|
let worker_slots : @async.Semaphore = Semaphore(max_active_workers)

///|
fn subtask_tool_definition(
  self_exe~ : String,
  model~ : @deepseek.Model,
  workspace_root~ : String,
  budget~ : @agent_subrun.SubrunBudget,
  api_url? : String,
  child_session? : @agent_subrun.ChildSession,
) -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="subtask",
    concurrent_safe=true,
    description=(
      #|Delegate ONE slice of write-capable work to a confined worker subagent in its own
      #|git worktree, or drive a finished slice's integration. LAUNCH: pass name (a short
      #|slug), task (the self-contained work order — the worker sees nothing else of this
      #|conversation), and allowed_paths (the repo-relative path prefixes this slice may
      #|change; partitions must be DISJOINT across active subtasks — overlapping launches
      #|are refused). The worker edits only inside its worktree and allowed paths, cannot
      #|commit, and its changes are validated against allowed_paths from git evidence and
      #|committed on a branch. Then INTEGRATE one subtask at a time: pass integrate=<name>
      #|to merge its branch here (re-run your checks after each); on a conflict, resolve
      #|the markers with the file tools, then integrate_continue=<name> (or
      #|integrate_abort=<name>); discard=<name> abandons a slice and frees its paths.
      #|PARALLELISM: to run several slices at once, pass them as `slices`: an ARRAY of
      #|{name, task, allowed_paths, context?} objects in ONE call — they are launched
      #|concurrently and reported together (2-4 per call; at most 4 run at once). Prefer
      #|this over issuing separate calls, which the loop can only overlap when they land
      #|in the same step. Commit your own work first: workers fork this repository's HEAD.
    ),
    schema=JsonSchema({
      "type": "object",
      "properties": {
        "slices": {
          "type": "array",
          "description": "Parallel launch: several {name, task, allowed_paths, context?} slices run CONCURRENTLY from this one call (at most 4 — the worker-slot cap). Their allowed_paths must be disjoint from each other and from any active subtask.",
          "maxItems": 4,
          "items": {
            "type": "object",
            "properties": {
              "name": { "type": "string" },
              "task": { "type": "string" },
              "allowed_paths": {
                "type": "array",
                "items": { "type": "string" },
              },
              "context": { "type": "string" },
            },
            "required": ["name", "task", "allowed_paths"],
          },
        },
        "name": {
          "type": "string",
          "description": "Single launch: short lowercase slug naming the slice (becomes the branch and worktree name).",
        },
        "task": {
          "type": "string",
          "description": "Launch: the self-contained work order, incl. what to verify.",
        },
        "allowed_paths": {
          "type": "array",
          "items": { "type": "string" },
          "description": "Launch: repo-relative path prefixes this slice may change (component-wise; disjoint from other active subtasks).",
        },
        "context": {
          "type": "string",
          "description": "Launch: optional extra pointers for the worker.",
        },
        "integrate": {
          "type": "string",
          "description": "Merge the named committed subtask's branch into this checkout.",
        },
        "integrate_continue": {
          "type": "string",
          "description": "After resolving a conflicted integration's markers: commit it.",
        },
        "integrate_abort": {
          "type": "string",
          "description": "Abort a conflicted integration; the branch and worktree survive.",
        },
        "discard": {
          "type": "string",
          "description": "Abandon the named subtask: remove its worktree and branch, free its paths.",
        },
      },
    }),
    execute=Async(arguments => {
      subtask_execute(
        self_exe, model, workspace_root, budget, api_url, child_session, arguments,
      )
    }),
  )
}

///|
let max_task_chars : Int = 4_000

///|
let max_context_chars : Int = 2_000

///|
async fn subtask_execute(
  self_exe : String,
  model : @deepseek.Model,
  workspace_root : String,
  budget : @agent_subrun.SubrunBudget,
  api_url : String?,
  child_session : @agent_subrun.ChildSession?,
  arguments : Json,
) -> @agent_tool.ToolAction {
  // Lifecycle actions first: exactly one of them may be present.
  match arguments {
    { "integrate": String(name), .. } if name.trim() != "" =>
      return subtask_lifecycle(workspace_root, "integrate", name)
    { "integrate_continue": String(name), .. } if name.trim() != "" =>
      return subtask_lifecycle(workspace_root, "integrate_continue", name)
    { "integrate_abort": String(name), .. } if name.trim() != "" =>
      return subtask_lifecycle(workspace_root, "integrate_abort", name)
    { "discard": String(name), .. } if name.trim() != "" =>
      return subtask_lifecycle(workspace_root, "discard", name)
    _ => ()
  }
  // `slices` launches several confined workers CONCURRENTLY from one call;
  // a bare name/task/allowed_paths object is the single-slice form.
  let specs : Array[LaunchSpec] = []
  match arguments {
    { "slices": Array(entries), .. } => {
      guard !entries.is_empty() else {
        return @agent_tool.ToolAction::respond(
          "error: subtask `slices` must not be empty",
          is_error=true,
        )
      }
      // Refuse rather than silently drop: slots are taken with
      // try_acquire, so entries past the cap would fail as "slots full"
      // while the call still looked accepted.
      guard entries.length() <= max_active_workers else {
        return @agent_tool.ToolAction::respond(
          "error: subtask `slices` accepts at most \{max_active_workers} slices per call (got \{entries.length()}) — send the rest in a follow-up call once these integrate",
          is_error=true,
        )
      }
      for entry in entries {
        match decode_launch(entry) {
          Ok(spec) => specs.push(spec)
          Err(reason) =>
            return @agent_tool.ToolAction::respond(
              "error: \{reason}",
              is_error=true,
            )
        }
      }
    }
    _ =>
      match decode_launch(arguments) {
        Ok(spec) => specs.push(spec)
        Err(reason) =>
          return @agent_tool.ToolAction::respond(
            "error: \{reason}",
            is_error=true,
          )
      }
  }
  subtask_launch_many(
    self_exe, model, workspace_root, budget, api_url, child_session, specs,
  )
}

///|
async fn subtask_lifecycle(
  workspace_root : String,
  action : String,
  name : String,
) -> @agent_tool.ToolAction {
  let geometry = match @subtask.resolve_geometry(workspace_root) {
    Ok(geometry) => geometry
    Err(reason) =>
      return @agent_tool.ToolAction::respond(
        "error: subtask \{action}: \{reason}",
        is_error=true,
      )
  }
  let (entries, _) = @subtask.load_entries(geometry.common_git_dir)
  guard entries.filter(e => e.name == name && !e.state.is_terminal()).last()
    is Some(entry) else {
    return @agent_tool.ToolAction::respond(
      "error: no active subtask named \{name}",
      is_error=true,
      brief="subtask \{action} \{name}",
    )
  }
  match action {
    "discard" =>
      match @subtask.discard(geometry, entry) {
        Ok(_) =>
          @agent_tool.ToolAction::respond(
            "subtask \{name} discarded: worktree and branch removed, paths freed.",
            brief="subtask discarded \{name}",
          )
        Err(reason) =>
          @agent_tool.ToolAction::respond(
            "error: subtask discard: \{reason}",
            is_error=true,
            brief="subtask discard \{name}",
          )
      }
    _ => {
      let outcome = match action {
        "integrate" => @subtask.integrate(geometry, entry)
        "integrate_continue" => @subtask.integrate_continue(geometry, entry)
        _ => @subtask.integrate_abort(geometry, entry)
      }
      let content = "subtask \{name} \{action}: \{outcome.result}\n\{outcome.detail.join("\n")}"
      @agent_tool.ToolAction::respond(
        content,
        is_error=outcome.result == "refused",
        brief="subtask \{action} \{name} (\{outcome.result})",
      )
    }
  }
}

///|
/// One decoded launch request.
priv struct LaunchSpec {
  name : String
  task : String
  context : String?
  allowed_paths : Array[String]
}

///|
/// Decode one launch object (the tool's own arguments, or one element of
/// `slices`). `Err` carries the model-facing message.
fn decode_launch(spec : Json) -> Result[LaunchSpec, String] {
  guard spec is { "name": String(name), .. } && name.trim() != "" else {
    return Err(
      "subtask requires `name` (launch), `slices` (parallel launch), or one of integrate/integrate_continue/integrate_abort/discard",
    )
  }
  guard spec is { "task": String(task), .. } && task.trim() != "" else {
    return Err("subtask launch requires a non-empty `task` for \{name}")
  }
  guard task.length() <= max_task_chars else {
    return Err("subtask task for \{name} exceeds \{max_task_chars} chars")
  }
  let context : String? = match spec {
    { "context": String(context), .. } if context.trim() != "" => Some(context)
    _ => None
  }
  guard !(context is Some(c) && c.length() > max_context_chars) else {
    return Err("subtask context for \{name} exceeds \{max_context_chars} chars")
  }
  let allowed_paths : Array[String] = []
  guard spec is { "allowed_paths": Array(prefixes), .. } && !prefixes.is_empty() else {
    return Err(
      "subtask launch \{name} requires a non-empty `allowed_paths` array — the repo-relative prefixes this slice may change",
    )
  }
  for prefix in prefixes {
    guard prefix is String(prefix) && prefix.trim() != "" else {
      return Err("allowed_paths entries must be non-empty strings (\{name})")
    }
    allowed_paths.push(prefix)
  }
  Ok({ name, task, context, allowed_paths })
}

///|
/// Launch every slice CONCURRENTLY and render one combined result. This is
/// the structural answer to a real dogfood finding: batching several
/// `subtask` calls into one assistant message parallelizes them, but that
/// is advisory — in a production sweep the model serialized 2 of 3 fan-outs
/// and paid ~2.7x the wall-clock. One call carrying N slices cannot be
/// serialized by accident.
async fn subtask_launch_many(
  self_exe : String,
  model : @deepseek.Model,
  workspace_root : String,
  budget : @agent_subrun.SubrunBudget,
  api_url : String?,
  child_session : @agent_subrun.ChildSession?,
  specs : Array[LaunchSpec],
) -> @agent_tool.ToolAction {
  let results : Map[Int, SliceOutcome] = Map([])
  @async.with_task_group(scope => {
    for index, spec in specs {
      scope.spawn_bg(() => {
        results.set(
          index,
          subtask_launch_one(
            self_exe, model, workspace_root, budget, api_url, child_session, spec,
          ),
        )
      })
    }
  })
  // A compact status line PER SLICE comes first: four full reports can
  // exceed the loop's per-tool-result clamp, and a truncated tail would
  // otherwise erase later slices' state and next steps entirely.
  let summary = StringBuilder()
  let detail = StringBuilder()
  let mut any_error = false
  let briefs : Array[String] = []
  for index, spec in specs {
    let (status, errored) = match results.get(index) {
      Some(outcome) =>
        (outcome.status, outcome.action is Respond(output) && output.is_error)
      None => ("no result", true)
    }
    if errored {
      any_error = true
    }
    briefs.push(spec.name)
    summary <+ "- \{spec.name}: \{status}\n"
    detail <+ "## \{spec.name}\n"
    match results.get(index) {
      Some({ action: Respond(output), .. }) => detail <+ "\{output.content}\n\n"
      _ => detail <+ "(no result)\n\n"
    }
  }
  let out = StringBuilder()
  out <+
    "\{specs.length()} slice(s) launched concurrently:\n\{summary.to_string()}\n"
  out <+ "\{detail.to_string()}"
  @agent_tool.ToolAction::respond(
    out.to_string(),
    is_error=any_error,
    brief="subtask \{specs.length()} slices (\{briefs.join(", ")})",
  )
}

///|
/// One finished slice: its rendered result plus the AUTHORITATIVE status
/// the controller derived from git evidence — carried as data so a batch
/// summary can never re-derive it from worker-authored prose.
priv struct SliceOutcome {
  action : @agent_tool.ToolAction
  status : String
}

///|
async fn subtask_launch_one(
  self_exe : String,
  model : @deepseek.Model,
  workspace_root : String,
  budget : @agent_subrun.SubrunBudget,
  api_url : String?,
  child_session : @agent_subrun.ChildSession?,
  spec : LaunchSpec,
) -> SliceOutcome {
  let name = spec.name
  let task = spec.task
  let context = spec.context
  let allowed_paths = spec.allowed_paths
  // Slots and budget are reserved BEFORE any state is created, so every
  // later failure path has exactly one transaction to roll back.
  guard worker_slots.try_acquire() else {
    return {
      action: @agent_tool.ToolAction::respond(
        "subtask worker slots are full (max \{max_active_workers} active) — integrate or await the running slices first.",
        is_error=true,
        brief="subtask (slots full)",
      ),
      status: "not launched: worker slots full",
    }
  }
  // Sync and block-scoped: a cancellation re-raised out of run_subrun still
  // returns the permit — four interrupts must not brick launching for the
  // rest of the process. (The provisioned worktree and its Running registry
  // entry survive a cancel by design: discoverable, discard-able.)
  defer worker_slots.release()
  guard budget.reserve(@agent_worker.default_worker_max_steps)
    is Some(granted_steps) else {
    return {
      action: @agent_tool.ToolAction::respond(
        "subtask budget exhausted for this turn — do the remaining slices yourself or continue next turn.",
        is_error=true,
        brief="subtask (budget exhausted)",
      ),
      status: "not launched: per-turn subtask budget exhausted",
    }
  }
  let nonce = random_salt()
  let provisioned = match
    @subtask.provision(
      workspace_root,
      name~,
      allowed_paths~,
      nonce=if nonce == "" { "n0" } else { nonce },
      parent_session?=child_session.map(session => session.parent),
    ) {
    Ok(provisioned) => provisioned
    Err(reason) =>
      return {
        action: @agent_tool.ToolAction::respond(
          "error: subtask provision: \{reason}",
          is_error=true,
          brief="subtask \{name} (provision refused)",
        ),
        status: "not launched: \{@agent_tool.brief_line(reason, limit=100)}",
      }
  }
  let entry = provisioned.entry
  let input : Json = match context {
    Some(context) =>
      {
        "task": task,
        "context": context,
        "worker_root": entry.worker_root,
        "worker_admin_dir": entry.worker_admin_dir,
        "deny_roots": provisioned.geometry.worktree_roots.to_json(),
        "allowed_paths": entry.allowed_paths.to_json(),
        "base_oid": entry.base_oid,
      }
    None =>
      {
        "task": task,
        "worker_root": entry.worker_root,
        "worker_admin_dir": entry.worker_admin_dir,
        "deny_roots": provisioned.geometry.worktree_roots.to_json(),
        "allowed_paths": entry.allowed_paths.to_json(),
        "base_oid": entry.base_oid,
      }
  }
  let args = [
    "subrun",
    "worker",
    "--model",
    "\{model}",
    "--max-steps",
    "\{granted_steps}",
  ]
  if api_url is Some(url) {
    args.push("--api-url")
    args.push(url)
  }
  let result = @agent_subrun.run_subrun(
    command=self_exe,
    args~,
    input~,
    parse_report=@agent_worker.WorkerReport::parse_validated,
    wall_deadline_ms=@agent_worker.default_worker_deadline_ms,
    kind="worker",
    label=@agent_tool.brief_line("\{name}: \{task}", limit=48),
    cwd=entry.worker_root,
    child_session?,
  )
  // Evidence comes from git regardless of how the child ended.
  let captured = @subtask.capture(provisioned.geometry, entry)
  let out = StringBuilder()
  match result.value() {
    Some(report) =>
      out <+
        "worker report (\{report.status}): \{report.summary}\nverification: \{report.verification}\n"
    None =>
      out <+ "the worker produced no report (\{Repr(result.terminal())}).\n"
  }
  out <+ "\ngit evidence:\n"
  for line in captured.evidence {
    out <+ "- \{line}\n"
  }
  for defect in captured.defects {
    out <+ "DEFECT: \{defect}\n"
  }
  let state_line = match captured.entry.state {
    Committed =>
      "state: committed on \{entry.branch} — review the evidence, then subtask integrate=\{name} (worktree kept at \{entry.worker_root} until then)"
    NoChanges => "state: no changes — the slice's paths are free again"
    _ =>
      "state: NOT mergeable — inspect \{entry.worker_root}, then discard=\{name} or relaunch"
  }
  out <+ "\n\{state_line}"
  let mergeable = captured.entry.state is Committed
  let is_error = !mergeable && !(captured.entry.state is NoChanges)
  {
    action: @agent_tool.ToolAction::respond(
      out.to_string(),
      is_error~,
      brief="subtask \{result.subrun_id()} \{name} (\{Repr(captured.entry.state)}, \{result.steps_used()} step(s))",
    ),
    status: state_line,
  }
}
