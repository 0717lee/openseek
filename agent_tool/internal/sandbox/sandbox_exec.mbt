///|
/// The standard absolute path of the macOS `sandbox-exec` binary.
///
/// The path is exposed so callers can pass it to `@process.spawn` or
/// `@process.run`. Its presence alone does not mean sandboxing works in the
/// current process; call `sandbox_exec_available` before using it.
pub const SandboxExecPath : String = "/usr/bin/sandbox-exec"

///|
let sandbox_exec_available_cache : Ref[Bool?] = { val: None }

///|
/// Build the argument vector passed to `SandboxExecPath` to interpret `cmd`
/// under an inline SBPL `profile`.
///
/// The returned vector has the shape
/// `[-p, profile, PlatformShellProgram, ..platform_shell_args(cmd)]`. Therefore
/// `cmd` is shell text, not an executable path or a pre-tokenized argument
/// vector. This function does not validate the profile or probe availability.
pub fn sandbox_exec_args(profile : String, cmd : String) -> Array[String] {
  ["-p", profile, PlatformShellProgram, ..platform_shell_args(cmd)]
}

///|
/// Return whether `sandbox-exec` can apply and enforce a profile in this
/// process.
///
/// On the first call, the probe runs an allowed no-op and a denied temporary
/// file write. It returns `true` only when the former succeeds and the latter
/// is actually blocked. Missing binaries, spawn failures, and environments
/// that forbid nested sandboxing produce `false`; cancellation still
/// propagates. The result is cached process-wide, so later calls do not probe
/// again.
pub async fn sandbox_exec_available() -> Bool {
  match sandbox_exec_available_cache.val {
    Some(value) => value
    None => {
      let value = probe_sandbox_exec_available()
      sandbox_exec_available_cache.val = Some(value)
      value
    }
  }
}

///|
async fn probe_sandbox_exec_available() -> Bool {
  if !@fs.exists(SandboxExecPath) {
    return false
  }
  let probe_dir = @fs.tmpdir(prefix="openseek-sandbox-probe-") catch {
    error if @async.is_being_cancelled() => raise error
    _ => return false
  }
  // sandbox-exec matches `file-write*` rules against the *realpath* of the
  // target. Temp dirs live under symlinked prefixes on macOS (`/tmp` ->
  // `/private/tmp`, `$TMPDIR` under `/private/var/...`), so a deny rule built
  // from the unresolved path never matches the resolved write. That made the
  // probe believe the sandbox was unenforced and disabled it process-wide.
  // Resolve the dir first, exactly like the real source-write profile does for
  // the workspace root.
  let probe_dir = @fs.realpath(probe_dir) catch {
    error if @async.is_being_cancelled() => raise error
    _ => probe_dir
  }
  let blocked_path = @path.Path(probe_dir)
    .join(Path("blocked"))
    .normalize()
    .to_string()
  let probe_profile = sandbox_denial_probe_profile(blocked_path)
  let noop_exit = run_probe_exit(
    SandboxExecPath,
    sandbox_exec_args(probe_profile, PlatformNoopCommand),
  )
  if noop_exit != Some(0) {
    cleanup_sandbox_probe(probe_dir, blocked_path)
    return false
  }
  let write_exit = run_probe_exit(
    SandboxExecPath,
    sandbox_exec_args(
      probe_profile,
      "printf probe > \{shell_quote(blocked_path)}",
    ),
  )
  let denied = write_exit != Some(0) && !@fs.exists(blocked_path)
  cleanup_sandbox_probe(probe_dir, blocked_path)
  denied
}

///|
/// Spawn `program args`, drain merged stdout+stderr so a child that fills the
/// pipe buffer cannot deadlock against `wait`, then wait and return the exit
/// code. Returns `None` when the spawn (or an unexpected IO error) fails; a
/// cancellation still propagates. The sandbox-availability probe only needs the
/// exit status plus a follow-up `@fs.exists` check, so the drained bytes are
/// discarded rather than decoded.
async fn run_probe_exit(program : String, args : Array[String]) -> Int? {
  (@async.with_task_group() <| group => {
    let (reader, writer) = @process.read_from_process()
    defer reader.close()
    let process = @process.spawn(
      group,
      program,
      args,
      stdout=writer,
      stderr=writer,
      cancel_handler=@process.hard_cancel(),
      no_wait=true,
    )
    for ;; {
      match reader.read_some(max_len=1024) {
        None => break
        Some(_) => ()
      }
    }
    Some(process.wait())
  }) catch {
    error if @async.is_being_cancelled() => raise error
    _ => None
  }
}

///|
#cfg(platform="windows")
const PlatformNoopCommand : String = "exit 0"

///|
#cfg(not(platform="windows"))
const PlatformNoopCommand : String = ":"

///|
fn sandbox_denial_probe_profile(blocked_path : String) -> String {
  (
    $|(version 1)
    $|(allow default)
    $|(deny file-write* (literal "\{sbpl_string_escape(blocked_path)}"))
  )
}

///|
fn shell_quote(text : String) -> String {
  "'\{text.replace_all(old="'", new="'\\''")}'"
}

///|
async fn cleanup_sandbox_probe(
  probe_dir : String,
  blocked_path : String,
) -> Unit {
  ignore(@fs.remove(blocked_path) catch { _ => () })
  ignore(@fs.rmdir(probe_dir) catch { _ => () })
}

///|
/// The platform shell program used to interpret command text.
///
/// This is `pwsh` on Windows and `sh` on other targets. It is used by both
/// `sandbox_exec_args` and callers that need the same unsandboxed command
/// semantics.
#cfg(platform="windows")
pub const PlatformShellProgram : String = "pwsh"

///|
/// The platform shell program used to interpret command text.
///
/// This is `pwsh` on Windows and `sh` on other targets. It is used by both
/// `sandbox_exec_args` and callers that need the same unsandboxed command
/// semantics.
#cfg(not(platform="windows"))
pub const PlatformShellProgram : String = "sh"

///|
/// Build arguments that make `PlatformShellProgram` interpret `cmd` as shell
/// text (`-NoProfile -Command` for PowerShell).
#cfg(platform="windows")
pub fn platform_shell_args(cmd : String) -> Array[String] {
  ["-NoProfile", "-Command", cmd]
}

///|
/// Build arguments that make `PlatformShellProgram` interpret `cmd` as shell
/// text (`-c` for `sh`).
#cfg(not(platform="windows"))
pub fn platform_shell_args(cmd : String) -> Array[String] {
  ["-c", cmd]
}
