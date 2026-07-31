///|
/// The command to prepare for source-write-sandboxed execution.
///
/// `Shell` runs command text through the platform shell. `Exec` runs a program
/// with an already-tokenized argument vector and introduces no shell.
pub(all) enum Command {
  Shell(String)
  Exec(String, Array[String])
}

///|
/// One prepared source-write-sandboxed invocation. Its process command and
/// denial subjects stay together so output is always classified against the
/// profile that produced it.
struct SandboxedCommand {
  /// Original command, kept tokenized until it is prepared for spawn.
  command : Command
  /// SBPL source. It is deliberately not placed in argv or written yet.
  profile : String
  /// Protected paths and basenames derived from the same profile encoded in
  /// `profile`, retained so denial reporting cannot use metadata from another run.
  denial_subjects : Array[String]
}

///|
/// Prepare `command` under the source-write sandbox for `workspace_root`, or
/// return `None` when this process cannot enforce one — `sandbox-exec` missing,
/// the availability probe failing, or a nested sandbox that forbids
/// re-sandboxing. `None` means exactly "enforcement unavailable"; the fallback
/// decision stays with the caller, explicit at the call site. Invalid input —
/// an unresolvable `workspace_root`, or a `writable_subtree` that covers the
/// root — raises instead, so misconfiguration cannot silently disable
/// protection.
///
/// The root is resolved to its real path here, because the kernel matches
/// profile rules against realpaths. The rules are built from the tree as it
/// exists now — renaming the root or subtree afterwards makes them stale, so
/// prepare the command close to where it runs.
///
/// `writable_subtree` re-allows writes below one directory — a scratch lab or
/// throwaway build directory — via a last-match-wins allow rule. It is resolved
/// too; when resolution fails the unresolved path is used, which can only
/// under-allow, never over-allow.
pub async fn SandboxedCommand::create_if_available(
  workspace_root : String,
  command : Command,
  writable_subtree? : String,
) -> SandboxedCommand? {
  // Inputs are validated BEFORE the availability probe, so a caller bug is
  // reported identically on every platform instead of hiding behind `None`
  // wherever enforcement happens to be unavailable.
  let real_root = @fs.realpath(workspace_root)
  let subtree = match writable_subtree {
    Some(dir) => {
      let real_dir = @fs.realpath(dir) catch {
        error if @async.is_being_cancelled() => raise error
        _ => dir
      }
      let normalized = @workspace_path.strip_trailing_slash(
        @path.Path(real_dir).normalize().to_string(),
      )
      // A subtree at or above the root would re-allow every source write the
      // profile exists to deny. That is never a scratch dir; it is a caller
      // bug, and failing open on it would be invisible.
      if @workspace_path.is_under_workspace_root(normalized, real_root) {
        fail("writable_subtree covers the workspace root")
      }
      Some(normalized)
    }
    None => None
  }
  guard sandbox_exec_available() else { return None }
  let data = source_write_readonly_profile_data(
    real_root,
    writable_lab?=subtree,
  )
  Some({
    command,
    profile: data.profile,
    // Copied: the profile cache hands out its own array, and this command must
    // keep classifying with the subjects of the profile it actually runs under.
    denial_subjects: data.denial_subjects.copy(),
  })
}

///|
/// Prepare this command for one execution owned by `group`.
///
/// The profile file is created only when execution starts, then registered on
/// the same group before its path is returned. The group removes it after every
/// child has terminated, so callers never receive or forward a cleanup action.
pub async fn[X] SandboxedCommand::prepare_for_spawn(
  self : SandboxedCommand,
  group : @async.TaskGroup[X],
) -> (String, Array[String]) {
  let profile_file = SandboxProfileFile::create(self.profile)
  group.add_defer(() => profile_file.remove())
  (SandboxExecPath, profile_file.arguments(self.command))
}

///|
/// Whether `output` contains a likely protected-source write denial from this
/// command. Recognition is heuristic and line-oriented: `true` is strong
/// evidence, not proof, and unrelated permission errors are ignored.
pub fn SandboxedCommand::output_reports_denial(
  self : SandboxedCommand,
  output : String,
) -> Bool {
  source_write_denied_in_text(output, self.denial_subjects)
}
