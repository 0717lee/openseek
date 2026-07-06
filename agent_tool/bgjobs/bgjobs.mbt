///|
/// Default retained-output budget for a background job, in characters. Matches
/// the `shell` tool's foreground default so a command reads the same whether it
/// runs in the foreground or the background.
let default_max_output_chars : Int = 12000

///|
/// Terminal or live state of a background job.
///
/// - `Running`: the child is still executing (a detached-but-running execution
///   also reads as `Running` here — a background job has no separate "detached"
///   state to a poller).
/// - `Exited(code)`: the child exited on its own with `code`.
/// - `Stopped`: the child was cancelled (`stop`, a reader error, or session
///   teardown) before a natural exit — no exit code is available.
pub(all) enum BgJobStatus {
  Running
  Exited(Int)
  Stopped
} derive(Eq)

///|
/// Session-scoped registry of background ("detached") jobs, each backed by one
/// shared `@shell_exec.ShellExecution` (a process on `scope.group()`, a single
/// output sink, and a status flag). Since every child is spawned on the session
/// group, each job's process is cancelled when the agent session's task group
/// ends.
///
/// Cancellation reaches only the directly spawned process (via
/// `@process.hard_cancel`): the process library exposes no process-group /
/// job-object kill, so a command that daemonizes or backgrounds its own children
/// can leave those descendants running after the job is reported terminal.
/// `stop`/teardown therefore guarantee the launched process is gone, not its
/// entire process tree.
///
/// One `BgJobRuntime` is created per session and shared by the `shell`
/// (`run_in_background`), `shell_output`, and `shell_stop` tools, so a job
/// started by one is visible to the others.
///
/// `new` captures the session group at construction, so `BgJobRuntime` itself is
/// not parameterised by the group's return type — it can be an optional tool
/// argument without leaking an unresolved type variable to callers that never
/// start background jobs.
pub struct BgJobRuntime {
  // Spawn a `ShellExecution` on the captured session group. Captured so the
  // runtime type is not generic. The `Int` is the retained-output budget.
  priv spawn_exec : async (String, Array[String], String?, Int) -> @shell_exec.ShellExecution
  // Spawn a per-job watcher task on that same group.
  priv spawn_watcher : (async () -> Unit) -> Unit
  // Called once, with the terminal snapshot, when a job reaches a terminal
  // status on its own (not on `stop`/teardown) — e.g. to push a completion
  // notice back into the agent loop.
  priv on_job_exit : ((BgJobSnapshot) -> Unit)?
  priv jobs : Map[String, BgJob]
  priv mut next_index : Int
}

///|
/// One background job: session-visible metadata plus the shared execution that
/// owns the process, output, and status. Fully private — callers only ever see a
/// `BgJobSnapshot` via `snapshot`/`list`.
priv struct BgJob {
  id : String
  command : String
  cwd : String?
  exec : @shell_exec.ShellExecution
}

///|
/// An immutable view of a job's current state, returned by `snapshot`/`list` so
/// callers never hold a live reference into the registry.
pub struct BgJobSnapshot {
  id : String
  command : String
  cwd : String?
  status : BgJobStatus
  output : String
  output_truncated : Bool
  seq : Int
  exit_code : Int?
}

///|
/// Create an empty runtime whose jobs are owned by `scope.group()`. The group is
/// captured into spawn closures, so the returned runtime is not generic.
pub fn[X] BgJobRuntime::new(
  scope : @agent_runtime.AgentTaskScope[X],
  on_job_exit? : (BgJobSnapshot) -> Unit,
) -> BgJobRuntime {
  let group = scope.group()
  {
    // A background job retains a prefix of exactly its budget: cap the sink's
    // inline and hard limits together at `max_output_chars`, so `output` stays
    // bounded (and `output_truncated` latches) exactly as a poller expects.
    spawn_exec: (program, args, cwd, max_output_chars) => {
      @shell_exec.ShellExecution::start(
        scope,
        program~,
        args~,
        cwd?,
        inline_cap=max_output_chars,
        hard_cap=max_output_chars,
      )
    },
    spawn_watcher: task => {
      group.spawn_bg(task, no_wait=true, allow_failure=true)
    },
    on_job_exit,
    jobs: {},
    next_index: 1,
  }
}

///|
fn BgJobRuntime::next_id(self : BgJobRuntime) -> String {
  let id = "bg-\{self.next_index}"
  self.next_index += 1
  id
}

///|
/// Spawn `program args` as a background job on the session group and return its
/// id. Merged stdout+stderr streams into the job's retained-output buffer; the
/// job keeps running after this returns. `command` is the human-readable command
/// line shown to the model (e.g. the original shell `cmd`).
pub async fn BgJobRuntime::start(
  self : BgJobRuntime,
  program~ : String,
  args~ : Array[String],
  command~ : String,
  cwd? : String,
  max_output_chars? : Int = default_max_output_chars,
) -> String {
  let id = self.next_id()
  // A non-positive budget is clamped by the sink; pass through as-is.
  let exec = (self.spawn_exec)(program, args, cwd, max_output_chars)
  self.jobs[id] = { id, command, cwd, exec }
  // Watch for a natural exit and fire `on_job_exit` once. The job entry is set
  // above before the watcher runs (the watcher first awaits the exit, ≥ one
  // tick later), so `snapshot(id)` always resolves.
  (self.spawn_watcher)(() => {
    exec.wait()
    guard self.on_job_exit is Some(callback) else { return }
    guard self.snapshot(id) is Some(snapshot) else { return }
    guard snapshot.status is Exited(_) else { return }
    callback(snapshot)
  })
  id
}

///|
/// Map an execution status onto the background-job status a poller sees. A
/// detached-but-running execution reads as `Running`; a killed one as `Stopped`.
fn bg_status(status : @shell_exec.ExecStatus) -> BgJobStatus {
  match status {
    Running | Backgrounded => Running
    Exited(code) => Exited(code)
    Killed => Stopped
  }
}

///|
fn BgJob::to_snapshot(self : BgJob) -> BgJobSnapshot {
  {
    id: self.id,
    command: self.command,
    cwd: self.cwd,
    status: bg_status(self.exec.status()),
    output: self.exec.output(),
    output_truncated: self.exec.output_truncated(),
    seq: self.exec.seq(),
    exit_code: self.exec.exit_code(),
  }
}

///|
/// The current state of one job, or `None` for an unknown id.
pub fn BgJobRuntime::snapshot(
  self : BgJobRuntime,
  id : String,
) -> BgJobSnapshot? {
  self.jobs.get(id).map(job => job.to_snapshot())
}

///|
/// Snapshots of every job the session has started.
pub fn BgJobRuntime::list(self : BgJobRuntime) -> Array[BgJobSnapshot] {
  let out = []
  for _, job in self.jobs {
    out.push(job.to_snapshot())
  }
  out
}

///|
/// Cancel a running job and return once it is terminal. Idempotent: an
/// already-terminal known job returns `true`; an unknown id returns `false`.
pub async fn BgJobRuntime::stop(self : BgJobRuntime, id : String) -> Bool {
  guard self.jobs.get(id) is Some(job) else { return false }
  // `ShellExecution::stop` returns false for an already-terminal execution, but
  // a `stop` of a known job is idempotent-true here — the caller only needs to
  // know the job is (now) gone.
  let _ = job.exec.stop()
  true
}
