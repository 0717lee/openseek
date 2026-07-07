///|
/// Default retained-output budget for a background job's inline preview, in
/// characters. Matches the `shell` tool's foreground default so a command reads
/// the same whether it runs in the foreground or the background. Full output
/// beyond this spills to the job's file (see `ShellOutputSink`).
let default_max_output_chars : Int = 12000

///|
/// Terminal or live state of a background job.
///
/// - `Running`: still executing (a detached-but-running execution also reads as
///   `Running` — a poller has no separate "detached" state).
/// - `Exited(code)`: exited on its own with `code`.
/// - `Stopped`: cancelled (`stop`, a reader error, or teardown) before exit.
pub(all) enum BgJobStatus {
  Running
  Exited(Int)
  Stopped
} derive(Eq)

///|
/// Session-scoped registry of background ("detached") jobs, each backed by one
/// shared `@shell_exec.ShellExecution` (a process on `scope.group()`, a
/// file-backed output sink, and a status flag). Every child is spawned on the
/// session group, so its process is cancelled when the session's task group ends.
///
/// Cancellation reaches only the directly spawned process: the process library
/// exposes no process-group kill, so a command that daemonizes its own children
/// can leave descendants running after the job is reported terminal.
///
/// One `BgJobRuntime` is created per session and shared by the `shell`
/// (`run_in_background`), `shell_output`, and `shell_stop` tools. `new` captures
/// the session group in a spawn closure, so the runtime is not generic and can be
/// an optional tool argument.
pub struct BgJobRuntime {
  // Spawn a `ShellExecution` on the captured session group: (program, args, cwd,
  // inline-preview budget, spill path) -> execution. Captured so the runtime type
  // is not generic.
  priv spawn_exec : async (String, Array[String], String?, Int, String?) -> @shell_exec.ShellExecution
  // Spawn a *foreground* execution on the same session group: memory-only output
  // capped at the budget and killed if it fills, so the shell tool's foreground
  // path shares the execution model (and can be detached on timeout) without
  // re-deriving generic spawning at each call site.
  priv spawn_foreground_exec : async (String, Array[String], String?, Int) -> @shell_exec.ShellExecution
  // Spawn a per-job watcher task on that same group.
  priv spawn_watcher : (async () -> Unit) -> Unit
  // Directory for per-job spill files (full output beyond the inline preview).
  // None → memory-only jobs (no full-output file).
  priv spill_dir : String?
  // Called once, with the terminal snapshot, when a job exits on its own (not on
  // `stop`/teardown) — e.g. to push a completion notice into the agent loop.
  priv on_job_exit : ((BgJobSnapshot) -> Unit)?
  priv jobs : Map[String, BgJob]
  priv mut next_index : Int
  // Separate counter for the spill files of detachable foreground executions
  // (which are not registered until adopted), so their `fg-<n>.out` files never
  // collide with a job's `bg-<n>.out`.
  priv mut fg_index : Int
}

///|
/// One background job: session-visible metadata plus the shared execution that
/// owns the process, output, and status. Fully private — callers see only a
/// `BgJobSnapshot`.
priv struct BgJob {
  id : String
  command : String
  cwd : String?
  exec : @shell_exec.ShellExecution
  // Sandbox metadata carried from the launch (opaque to bgjobs) so a reader can
  // apply the same source-write-denial detection the foreground path does.
  source_write_sandboxed : Bool
  sandbox_denial_subjects : Array[String]
}

///|
/// An immutable view of a job's current state. `output` is the inline preview
/// (the first inline-budget characters); the *full* output — when `over_inline_cap`
/// — is read with `BgJobRuntime::read_output`.
pub struct BgJobSnapshot {
  id : String
  command : String
  cwd : String?
  status : BgJobStatus
  output : String
  output_truncated : Bool
  over_inline_cap : Bool
  size : Int
  seq : Int
  exit_code : Int?
  // Preserved so a reader can match the foreground path's error semantics: mark
  // binary output as an error, and detect a sandboxed source-write denial.
  had_invalid_utf8 : Bool
  source_write_sandboxed : Bool
  sandbox_denial_subjects : Array[String]
}

///|
/// Create an empty runtime whose jobs are owned by `scope.group()`. Jobs spill
/// full output into `spill_dir` (per-job files); omit it for memory-only jobs.
pub fn[X] BgJobRuntime::new(
  scope : @agent_runtime.AgentTaskScope[X],
  spill_dir? : String,
  on_job_exit? : (BgJobSnapshot) -> Unit,
) -> BgJobRuntime {
  let group = scope.group()
  {
    spawn_exec: (program, args, cwd, max_output_chars, spill_path) => {
      @shell_exec.ShellExecution::start(
        scope,
        program~,
        args~,
        cwd?,
        inline_cap=max_output_chars,
        spill_path?,
      )
    },
    spawn_foreground_exec: (program, args, cwd, max_output_chars) => {
      // Foreground output-limit semantics: cap at exactly `max_output_chars`
      // (inline == hard) and kill on overflow, so exceeding it is reported as the
      // output-limit error, never silently dropped. Foreground is memory-only (no
      // spill) — full output is a background-job feature.
      @shell_exec.ShellExecution::start(
        scope,
        program~,
        args~,
        cwd?,
        inline_cap=max_output_chars,
        hard_cap=max_output_chars,
        kill_when_full=true,
      )
    },
    spawn_watcher: task => {
      group.spawn_bg(task, no_wait=true, allow_failure=true)
    },
    spill_dir,
    on_job_exit,
    jobs: {},
    next_index: 1,
    fg_index: 1,
  }
}

///|
fn BgJobRuntime::next_id(self : BgJobRuntime) -> String {
  let id = "bg-\{self.next_index}"
  self.next_index += 1
  id
}

///|
/// Spawn a *foreground* execution on the session group: memory-only output
/// capped at `max_output_chars` and killed if it fills. The shell tool's
/// foreground path uses this so foreground and background share one execution
/// model — and a timed-out foreground command can be `adopt`-ed (detached)
/// rather than killed. Positional to match the shell tool's spawner type.
pub async fn BgJobRuntime::spawn_foreground(
  self : BgJobRuntime,
  program : String,
  args : Array[String],
  cwd : String?,
  max_output_chars : Int,
) -> @shell_exec.ShellExecution {
  (self.spawn_foreground_exec)(program, args, cwd, max_output_chars)
}

///|
/// Spawn a foreground execution that may be *detached* (adopted) on timeout: it
/// uses the background retention config — file-backed (spill), a large hard cap,
/// no output-limit kill — so that if it is detached and keeps producing output,
/// `shell_output` still sees it. The foreground output-limit (over
/// `max_output_chars`) is enforced by the caller at display time, not by killing;
/// the caller's `timeout_ms` bounds the wait. Reuses the background spawn with a
/// distinct `fg-<n>.out` spill file.
pub async fn BgJobRuntime::spawn_foreground_retained(
  self : BgJobRuntime,
  program : String,
  args : Array[String],
  cwd : String?,
  max_output_chars : Int,
) -> @shell_exec.ShellExecution {
  let spill_path = self.spill_dir.map(dir => {
    let index = self.fg_index
    self.fg_index += 1
    "\{dir}/fg-\{index}.out"
  })
  (self.spawn_exec)(program, args, cwd, max_output_chars, spill_path)
}

///|
/// Spawn `program args` as a background job on the session group and return its
/// id. The job keeps running after this returns; `command` is the human-readable
/// command line shown to the model.
pub async fn BgJobRuntime::start(
  self : BgJobRuntime,
  program~ : String,
  args~ : Array[String],
  command~ : String,
  cwd? : String,
  max_output_chars? : Int = default_max_output_chars,
  source_write_sandboxed? : Bool = false,
  sandbox_denial_subjects? : Array[String] = [],
) -> String {
  // Reserve one id and use it for both the spill file and the registry entry, so
  // the job id and its `<id>.out` file never diverge.
  let id = self.next_id()
  let spill_path = self.spill_dir.map(dir => "\{dir}/\{id}.out")
  let exec = (self.spawn_exec)(program, args, cwd, max_output_chars, spill_path)
  self.register(
    id,
    exec,
    command~,
    cwd?,
    source_write_sandboxed~,
    sandbox_denial_subjects~,
  )
  id
}

///|
/// Register an already-running `ShellExecution` as a background job and return
/// its id. Used by detach-on-timeout: a foreground command that outlived its
/// timeout is `background()`-ed and adopted here, so `shell_output`/`shell_stop`
/// and the completion notice see it like any explicit background job.
pub fn BgJobRuntime::adopt(
  self : BgJobRuntime,
  exec : @shell_exec.ShellExecution,
  command~ : String,
  cwd? : String,
  source_write_sandboxed? : Bool = false,
  sandbox_denial_subjects? : Array[String] = [],
) -> String {
  let id = self.next_id()
  self.register(
    id,
    exec,
    command~,
    cwd?,
    source_write_sandboxed~,
    sandbox_denial_subjects~,
  )
  id
}

///|
/// Add a job to the registry under `id` and start its exit watcher.
fn BgJobRuntime::register(
  self : BgJobRuntime,
  id : String,
  exec : @shell_exec.ShellExecution,
  command~ : String,
  cwd? : String,
  source_write_sandboxed~ : Bool,
  sandbox_denial_subjects~ : Array[String],
) -> Unit {
  self.jobs[id] = {
    id,
    command,
    cwd,
    exec,
    source_write_sandboxed,
    sandbox_denial_subjects,
  }
  // Watch for a natural exit and fire `on_job_exit` once. The job entry is set
  // above before the watcher runs (the watcher first awaits the exit, ≥ one tick
  // later), so `snapshot(id)` always resolves.
  (self.spawn_watcher)(() => {
    exec.wait()
    guard self.on_job_exit is Some(callback) else { return }
    guard self.snapshot(id) is Some(snapshot) else { return }
    guard snapshot.status is Exited(_) else { return }
    callback(snapshot)
  })
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
    output: self.exec.head(),
    output_truncated: self.exec.output_truncated(),
    over_inline_cap: self.exec.over_inline_cap(),
    size: self.exec.size(),
    seq: self.exec.seq(),
    exit_code: self.exec.exit_code(),
    had_invalid_utf8: self.exec.had_invalid_utf8(),
    source_write_sandboxed: self.source_write_sandboxed,
    sandbox_denial_subjects: self.sandbox_denial_subjects,
  }
}

///|
/// The current state of one job (inline preview), or `None` for an unknown id.
pub fn BgJobRuntime::snapshot(
  self : BgJobRuntime,
  id : String,
) -> BgJobSnapshot? {
  self.jobs.get(id).map(job => job.to_snapshot())
}

///|
/// The full output of one job (reads the spill file for a large job), or `None`
/// for an unknown id.
pub async fn BgJobRuntime::read_output(
  self : BgJobRuntime,
  id : String,
) -> String? {
  match self.jobs.get(id) {
    Some(job) => Some(job.exec.read_all())
    None => None
  }
}

///|
/// The last `n` characters of one job's output — a bounded window onto recent
/// output — or `None` for an unknown id. Used by `shell_output` so a poll cannot
/// flood the conversation with a large job's full log.
pub async fn BgJobRuntime::read_output_tail(
  self : BgJobRuntime,
  id : String,
  n : Int,
) -> String? {
  match self.jobs.get(id) {
    Some(job) => Some(job.exec.read_tail(n))
    None => None
  }
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
  let _ = job.exec.stop()
  true
}
