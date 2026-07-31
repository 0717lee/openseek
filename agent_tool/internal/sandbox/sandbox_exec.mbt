///|
/// The standard absolute path of the macOS `sandbox-exec` binary. Its
/// presence alone does not mean sandboxing works in the current process;
/// `sandbox_exec_available` probes that.
const SandboxExecPath : String = "/usr/bin/sandbox-exec"

///|
let sandbox_exec_available_cache : Ref[Bool?] = { val: None }

///|
/// One private SBPL file owned by an execution task group.
///
/// The profile must stay present until `sandbox-exec` exits: removing it just
/// after spawning races the new process opening `-f`. `prepare_for_spawn`
/// therefore registers its removal on the task group before returning its path.
priv struct SandboxProfileFile {
  directory : String
  path : String
}

///|
/// Write `profile` outside argv so a large source tree cannot make process
/// creation fail with `E2BIG`. The containing directory is private and unique;
/// the file itself is created with owner-only permissions.
async fn SandboxProfileFile::create(profile : String) -> SandboxProfileFile {
  let directory = @fs.tmpdir(prefix="openseek-sandbox-profile-")
  let path = "\{directory}/profile.sb"
  try {
    @fs.write_file(path, profile, create_mode=CreateNew, permission=0o600)
    { directory, path }
  } catch {
    error => {
      // Creation may be cancelled after the directory exists. Shield this
      // small removal so a cancelled tool call does not leak profile text.
      @async.protect_from_cancel(() => {
        @fs.rmdir(directory, recursive=true) catch {
          _ => ()
        }
      })
      raise error
    }
  }
}

///|
/// Build the argument vector passed to `SandboxExecPath`.
///
/// `Shell(cmd)` remains shell text, while `Exec(program, args)` stays an
/// already-tokenized invocation. In both cases argv contains only the short
/// profile path, never the potentially megabyte-sized SBPL source.
fn SandboxProfileFile::arguments(
  self : SandboxProfileFile,
  command : Command,
) -> Array[String] {
  match command {
    Shell(cmd) =>
      ["-f", self.path, @platform_shell.program, ..@platform_shell.args(cmd)]
    Exec(program, args) => ["-f", self.path, program, ..args]
  }
}

///|
/// Remove the private profile directory. Removal is idempotent and best-effort
/// because the child has already exited when production callers invoke it.
async fn SandboxProfileFile::remove(self : SandboxProfileFile) -> Unit {
  @async.protect_from_cancel(() => {
    @fs.rmdir(self.directory, recursive=true) catch {
      _ => ()
    }
  })
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
async fn sandbox_exec_available() -> Bool {
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
  let probe_profile =
    $|(version 1)
    $|(allow default)
    $|(deny file-write* (literal "\{sbpl_string_escape(blocked_path)}"))
  @async.with_task_group(probe_group => {
    probe_group.add_defer(() => cleanup_sandbox_probe(probe_dir, blocked_path))
    let profile_file = SandboxProfileFile::create(probe_profile) catch {
      error if @async.is_being_cancelled() => raise error
      _ => return false
    }
    probe_group.add_defer(() => profile_file.remove())
    let noop_exit = run_probe_exit(
      SandboxExecPath,
      profile_file.arguments(Shell(PlatformNoopCommand)),
    )
    if noop_exit != Some(0) {
      return false
    }
    let write_exit = run_probe_exit(
      SandboxExecPath,
      profile_file.arguments(
        Shell("printf probe > \{shell_quote(blocked_path)}"),
      ),
    )
    write_exit != Some(0) && !@fs.exists(blocked_path)
  })
}

///|
/// Exit code of `program args`, or `None` when the spawn (or an unexpected IO
/// error) fails; a cancellation still propagates. A thin wrapper over
/// `@process.collect_output_merged`, which already drains merged stdout+stderr
/// before waiting, so a child that fills the pipe buffer cannot deadlock
/// against `wait`. The sandbox-availability probe only needs the exit status
/// plus a follow-up `@fs.exists` check, so the collected bytes are discarded.
async fn run_probe_exit(program : String, args : Array[String]) -> Int? {
  let (exit_code, _) = @process.collect_output_merged(program, args) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return None
  }
  Some(exit_code)
}

///|
#cfg(platform="windows")
const PlatformNoopCommand : String = "exit 0"

///|
#cfg(not(platform="windows"))
const PlatformNoopCommand : String = ":"

///|
fn shell_quote(text : String) -> String {
  "'\{text.replace_all(old="'", new="'\\''")}'"
}

///|
async fn cleanup_sandbox_probe(
  probe_dir : String,
  blocked_path : String,
) -> Unit {
  @async.protect_from_cancel(() => {
    ignore(@fs.remove(blocked_path) catch { _ => () })
    ignore(@fs.rmdir(probe_dir) catch { _ => () })
  })
}
