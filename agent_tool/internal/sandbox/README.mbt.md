# agent_tool/internal/sandbox

Shared macOS **sandbox** machinery for the agent's tools. It builds an SBPL
(Seatbelt) "source-write read-only" profile, probes whether `sandbox-exec` can
actually enforce it on this host, and exposes the workspace path predicates the
profile scan needs.

Both the `shell` tool and the `run_moonbit` tool run their child process under
this profile so a command or snippet can read the workspace and write non-source
outputs, but cannot overwrite or delete protected MoonBit sources.

## What it protects

`source_write_readonly_profile_data(real_workspace_root)` returns an SBPL profile
that, under `(allow default)`:

- **denies** writes to protected source files anywhere under the workspace root —
  `*.mbt`, `*.mbti`, `*.mbt.md`, and the manifests `moon.mod`, `moon.pkg`,
  `moon.work`, plus the legacy `moon.mod.json` / `moon.pkg.json`;
- **re-allows** `_build` / `.mooncakes` trees (Moon writes generated sources
  there);
- emits **literal denies for source-containing directories**, so moving or
  deleting a whole directory (`rename`/`unlink`) cannot smuggle sources out.

The result is cached per normalized workspace root and invalidated by directory
mtime changes.

## Availability probe

`sandbox_exec_available()` (cached) returns true only when `/usr/bin/sandbox-exec`
exists **and** a trivial profile actually applies and enforces a deny here — so a
process already running inside a sandbox (where re-sandboxing is refused) reports
false and callers fall back to running unsandboxed. On non-macOS hosts it is
always false; cross-platform containment is the planned wasm backend's job.

## Usage

```mbt nocheck
if @sandbox.sandbox_exec_available() {
  let profile = @sandbox.source_write_readonly_profile_data(workspace_root).profile
  // run under: sandbox-exec -p <profile> <program> <args...>
  @process.run(@sandbox.SandboxExecPath, ["-p", profile, program, ..args])
}
```

The path predicates (`is_protected_workspace_source_path`, `is_under_workspace_root`,
`is_moon_managed_workspace_path`, `is_protected_source_path`, `path_basename`) are
also exported for callers that need to reason about protected paths directly.
