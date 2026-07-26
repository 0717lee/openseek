///|
/// A program-plus-arguments pair ready to hand to `@process.spawn`/`run`.
/// Plain data — `pub(all)` so an unsandboxed launcher can build the same
/// shape this package's wrappers produce.
pub(all) struct ProcessCommand {
  program : String
  args : Array[String]
}

///|
/// The source-write sandbox for one workspace: an opaque capability that wraps
/// commands in a kernel-enforced deny of MoonBit source writes. Obtain one
/// with `SourceWriteSandbox::create_if_available`; everything SBPL-specific
/// stays behind it.
struct SourceWriteSandbox {
  profile : String
  classifier : SourceWriteDenialClassifier
}

///|
/// Recognizes source-write denials in the output of a sandboxed command. It
/// carries the denial subjects of the profile that command ran under, so a
/// caller that judges output later — background jobs, streamed scans — needs
/// no other sandbox state.
struct SourceWriteDenialClassifier {
  denial_subjects : Array[String]
}

///|
/// A wrapped invocation: the command line to spawn, and the classifier for
/// its output. The pair travels together because the classifier is only
/// meaningful for output produced under this command's profile.
pub struct SandboxedCommand {
  command : ProcessCommand
  denial_classifier : SourceWriteDenialClassifier
}

///|
/// Acquire the source-write sandbox for `workspace_root`, or `None` when this
/// process cannot enforce one — `sandbox-exec` missing, the availability probe
/// failing, or a nested sandbox that forbids re-sandboxing. `None` means
/// exactly "enforcement unavailable"; the fallback decision stays with the
/// caller, explicit at the call site. Invalid input — an unresolvable
/// `workspace_root`, or a `writable_subtree` that covers the root — raises
/// instead, so misconfiguration cannot silently disable protection.
///
/// The root is resolved to its real path here, because the kernel matches
/// profile rules against realpaths; callers no longer pre-resolve. The rules
/// are built from the tree as it exists now — renaming the root or the
/// subtree afterwards makes them stale (they deny the old paths), so acquire
/// the sandbox close to where the command runs.
///
/// `writable_subtree` re-allows writes below one directory — a scratch lab, a
/// throwaway build dir — via a last-match-wins allow rule. It is resolved
/// too; when resolution fails the unresolved path is used, which can only
/// under-allow (writes in the subtree denied), never over-allow.
pub async fn SourceWriteSandbox::create_if_available(
  workspace_root : String,
  writable_subtree? : String,
) -> SourceWriteSandbox? {
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
    profile: data.profile,
    // Copied: the profile cache hands out its own array, and a classifier
    // must keep classifying with the subjects its command actually ran under.
    classifier: { denial_subjects: data.denial_subjects.copy() },
  })
}

///|
/// Wrap shell command text: the platform shell runs `cmd` under this
/// sandbox's profile.
pub fn SourceWriteSandbox::wrap_shell_command(
  self : SourceWriteSandbox,
  cmd : String,
) -> SandboxedCommand {
  {
    command: {
      program: SandboxExecPath,
      args: sandbox_exec_args(self.profile, cmd),
    },
    denial_classifier: self.classifier,
  }
}

///|
/// Wrap a program and pre-tokenized argument vector — no shell involved — so
/// runners that build their own argv (e.g. `moon` invocations) get the same
/// profile as shell text does.
pub fn SourceWriteSandbox::wrap_program(
  self : SourceWriteSandbox,
  program : String,
  args : Array[String],
) -> SandboxedCommand {
  {
    command: {
      program: SandboxExecPath,
      args: ["-p", self.profile, program, ..args],
    },
    denial_classifier: self.classifier,
  }
}

///|
/// Build a classifier directly from denial subjects. This exists for tests
/// and fixtures that exercise denial detection without a live sandbox (the
/// wiring must stay covered on platforms where the probe cannot pass);
/// production code receives its classifier from a `SandboxedCommand`.
pub fn SourceWriteDenialClassifier::with_subjects(
  denial_subjects : Array[String],
) -> SourceWriteDenialClassifier {
  { denial_subjects, }
}

///|
/// Whether `output` contains a likely source-write denial from the command
/// this classifier was issued for. Heuristic line-oriented recognition — a
/// `true` is strong evidence, not proof, and unrelated permission errors are
/// deliberately ignored.
pub fn SourceWriteDenialClassifier::output_reports_denial(
  self : SourceWriteDenialClassifier,
  output : String,
) -> Bool {
  source_write_denied_in_text(output, self.denial_subjects)
}
