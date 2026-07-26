# agent_tool/internal/sandbox

The source-write sandbox as a capability. `shell`, `run_moonbit`, `bgjobs`,
and `shell_output` share one macOS `sandbox-exec` integration through two
opaque types and two command records: acquire a `SourceWriteSandbox` for a
workspace, wrap a command in it, and judge that command's output with the
classifier it came with.
Everything SBPL-specific — profile text, escaping, the `sandbox-exec` path,
the availability probe — stays behind the API.

This package does not own workspace path manipulation or protection-policy
predicates. Generic lexical operations live in `internal/workspace_path`,
MoonBit source classification lives in
`agent_tool/internal/source_write_policy`, and the platform shell pair lives
in `agent_tool/internal/platform_shell`.

## The contract

Acquire, wrap, run, classify:

```mbt nocheck
match @sandbox.SourceWriteSandbox::create_if_available(workspace_root) {
  None =>
    // Enforcement unavailable here (not macOS, or a nested sandbox).
    // The fallback is the CALLER's decision, made explicitly.
    run_unsandboxed(cmd)
  Some(sandbox) => {
    let wrapped = sandbox.wrap_shell_command(cmd)
    let output = run(wrapped.command.program, wrapped.command.args)
    if wrapped.denial_classifier.output_reports_denial(output) {
      // The kernel denied a protected source write: explain it rather than
      // letting the model debug a bare "Operation not permitted".
    }
  }
}
```

`None` means exactly "enforcement unavailable". Invalid input — an
unresolvable workspace root, or a `writable_subtree` at or above the root —
raises instead, on every platform, so a caller bug cannot silently disable
protection where the probe happens to fail. The root is realpath'd inside the
constructor, because the kernel matches profile rules against real paths.

The profile is built from the tree as it exists at acquisition; renaming the
root or subtree afterwards makes the rules stale. Acquire close to where the
command runs.

## Wrapping

`wrap_shell_command(cmd)` runs shell text through the platform shell under
the profile. `wrap_program(program, args)` wraps a pre-tokenized argv with no
shell involved — the shape `run_moonbit` uses to run `moon` directly. Both
return a `SandboxedCommand`: the `ProcessCommand` to spawn plus the
`SourceWriteDenialClassifier` for its output. The pair travels together
because the classifier is only meaningful for output produced under that
command's profile.

`writable_subtree` re-allows one directory tree — a scratch lab for a
read-only subagent, `run_moonbit`'s throwaway build dir — via a
last-match-wins SBPL allow rule. A subtree covering the workspace root is
rejected outright: it would re-allow every write the profile exists to deny.

## Classifying denials

A denial surfaces as an "Operation not permitted" line in the child's output.
The classifier recognizes the shapes the tools actually produce, and only on
a line that also names a protected source path:

```mbt check
///|
test "a denial line must also name protected source" {
  let classifier = @sandbox.SourceWriteDenialClassifier::with_subjects([])
  inspect(
    classifier.output_reports_denial("sh: main.mbt: Operation not permitted\n"),
    content="true",
  )
  // A generic denial, and a mere mention of a source file, both miss.
  inspect(
    classifier.output_reports_denial("Permission denied\n"),
    content="false",
  )
  inspect(
    classifier.output_reports_denial("compiled keep.mbt: ok\n"),
    content="false",
  )
}
```

A denied *directory* has no protected suffix, so it is recognized only
through the subjects the profile scan discovered — which is why classifiers
are issued per command rather than shared globally:

```mbt check
///|
test "directory denials need the profile's own subjects" {
  let denial = "PermissionError: [Errno 1] Operation not permitted: 'pkg'\n"
  inspect(
    @sandbox.SourceWriteDenialClassifier::with_subjects([]).output_reports_denial(
      denial,
    ),
    content="false",
  )
  inspect(
    @sandbox.SourceWriteDenialClassifier::with_subjects(["pkg"]).output_reports_denial(
      denial,
    ),
    content="true",
  )
}
```

`with_subjects` exists for exactly this kind of platform-independent test;
production code takes its classifier from a `SandboxedCommand`. The
exhaustive line-shape pins live in `denial_output_test.mbt`, and the
end-to-end kernel tests — a real denied write, a real subtree allow — in
`capability_test.mbt`.

## The profile underneath

The generated profile starts from `(allow default)` and then:

- denies writes to `*.mbt`, `*.mbti`, `*.mbt.md`, `moon.mod`, `moon.pkg`, and
  `moon.work`, including the legacy JSON manifests, under the workspace root;
- re-allows `_build` and `.mooncakes` trees where Moon writes generated
  sources;
- denies source-containing directories literally, preventing a direct rename
  or removal of those directories.

The base profile is cached by normalized workspace root; directory mtimes
from the source-tree scan invalidate the cache when the tree changes. The
`writable_subtree` variant is composed per acquisition and never cached.
`sandbox_wbtest.mbt` pins the emitted SBPL byte for byte.

The profile builder classifies names through `@source_write_policy`; callers
performing static command preflight (the `shell` tool) use those packages
directly, so the static and kernel layers agree on what counts as source.

## Availability and limitations

The constructor's availability gate is a cached behavioral probe, not an
existence check: it requires an allowed no-op to succeed and a denied
temporary write to fail. Nested sandboxes that prohibit re-sandboxing
therefore yield `None`, and the result is cached for the process — a probe
that failed transiently stays failed, deliberately, because in the
environments where it genuinely cannot pass (nested sandboxes), re-probing
on every command would cost two spawns each and never succeed.

The profile is a best-effort write guard, not a complete process-security
boundary:

- reads and non-source writes remain allowed;
- callers may run unsandboxed when acquisition returns `None`;
- filesystem aliasing and directory operations can exceed purely path-based
  policy assumptions;
- `shell` supplements the runtime profile with static command preflight,
  while arbitrary code run by `run_moonbit` cannot receive the same analysis.
