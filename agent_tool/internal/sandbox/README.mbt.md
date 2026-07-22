# agent_tool/internal/sandbox

Internal macOS sandbox integration shared by the `shell` and `run_moonbit`
agent tools. The package builds an SBPL (Seatbelt) profile from the separate
source-write policy and runs shell command text through `sandbox-exec` when
enforcement is available.

This package does not own workspace path manipulation or protection-policy
predicates. Generic lexical operations live in `internal/workspace_path`, while
MoonBit source classification lives in `agent_tool/internal/source_write_policy`.

## Implementation layout

The directory is one MoonBit package; the files are organizational boundaries,
not separate namespaces:

- `sandbox_exec.mbt` probes `/usr/bin/sandbox-exec` and constructs its command
  line;
- `source_write_profile.mbt` scans the workspace, caches scan results, and emits
  the SBPL profile;
- `denial_output.mbt` recognizes protection failures in child-process output;
- `sandbox_wbtest.mbt` tests the profile, cache, and diagnostics.

## Execution contract

Callers follow four steps:

1. Resolve the workspace root to an absolute real path.
2. Call `sandbox_exec_available()`. A `false` result means this package cannot
   enforce a profile; callers must choose their own fallback.
3. Build `SourceWriteProfileData` with
   `source_write_readonly_profile_data(real_workspace_root)` and pass its
   `profile` to `sandbox_exec_args`.
4. If the child fails, pass its output and the profile's `denial_subjects` to
   `source_write_denied_in_text` before presenting a more specific diagnostic.

```mbt nocheck
let real_root = @fs.realpath(workspace_root)
if @sandbox.sandbox_exec_available() {
  let data = @sandbox.source_write_readonly_profile_data(real_root)
  let args = @sandbox.sandbox_exec_args(data.profile, command)
  let result = @process.run(@sandbox.SandboxExecPath, args)
  if @sandbox.source_write_denied_in_text(
    result.stdout + result.stderr,
    data.denial_subjects,
  ) {
    // Report that the command attempted to modify protected source.
  }
}
```

`sandbox_exec_args` deliberately accepts shell command text. It inserts
`PlatformShellProgram` and `platform_shell_args(command)` after the inline SBPL
profile; it does not accept an executable plus an already-tokenized argument
vector.

## Source-write profile

The generated profile starts from `(allow default)` and then:

- denies writes to `*.mbt`, `*.mbti`, `*.mbt.md`, `moon.mod`, `moon.pkg`, and
  `moon.work`, including the legacy JSON manifests, under the workspace root;
- re-allows `_build` and `.mooncakes` trees where Moon writes generated sources;
- denies source-containing directories literally, preventing a direct rename or
  removal of those directories.

The base profile is cached by normalized workspace root. Directory mtimes from
the source-tree scan invalidate the cache when the tree changes.

The optional `writable_lab` argument appends a last-match-wins allow rule for an
entire scratch subtree. The builder normalizes that path but does not prove that
it belongs to the workspace. Callers must supply a trusted, narrowly scoped lab
path.

## Policy dependency

The profile builder calls `@source_write_policy` to classify protected source
names and Moon-managed build trees. That package combines the generic
`@workspace_path.is_under_workspace_root` containment helper with
MoonBit-specific naming rules. Callers performing static command preflight use
those packages directly; the sandbox package does not re-export their APIs.

## Availability and limitations

`sandbox_exec_available()` caches a behavioral probe, not just an existence
check. It requires an allowed no-op to succeed and a denied temporary write to
fail. Nested sandboxes that prohibit re-sandboxing therefore report unavailable.

The profile is a best-effort write guard, not a complete process-security
boundary:

- reads and non-source writes remain allowed;
- callers may run unsandboxed when the availability probe returns `false`;
- filesystem aliasing and directory operations can exceed purely path-based
  policy assumptions;
- `shell` supplements the runtime profile with static command preflight, while
  arbitrary code run by `run_moonbit` cannot receive the same analysis.

`sbpl_string_escape` only escapes the contents of an SBPL quoted string. It does
not add quotes or validate a complete SBPL expression.
