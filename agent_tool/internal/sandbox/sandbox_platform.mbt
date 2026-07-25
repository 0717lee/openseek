///|
/// The platform shell program used to interpret command text: `pwsh` on
/// Windows and `sh` on other targets. Used by `sandbox_exec_args` and by
/// callers that need the same unsandboxed command semantics.
///
/// A `pub let`, not a `pub const`. A public `#cfg` const bakes whichever value
/// survived into `pkg.generated.mbti`, so regenerating the interface on Windows
/// rewrites it to `"pwsh"` and the committed one no longer matches. A `let`
/// records only `platform_shell_program : String`, which is identical on every
/// platform.
///
/// TODO(upstream): support `declare pub let`, so this note can sit on one
/// declaration the way `platform_shell_args` does instead of on the arms.
// declare pub let platform_shell_program : String

///|
/// `pwsh` on Windows — see the note above.
#cfg(platform="windows")
pub let platform_shell_program : String = "pwsh"

///|
/// `sh` on non-Windows targets — see the note above.
#cfg(not(platform="windows"))
pub let platform_shell_program : String = "sh"

///|
/// Build arguments that make `platform_shell_program` interpret `cmd` as shell
/// text: `-NoProfile -Command` for PowerShell, `-c` for `sh`.
declare pub fn platform_shell_args(cmd : String) -> Array[String]

///|
/// Build arguments that make `platform_shell_program` interpret `cmd` as shell
/// text (`-NoProfile -Command` for PowerShell).
#cfg(platform="windows")
pub fn platform_shell_args(cmd : String) -> Array[String] {
  ["-NoProfile", "-Command", cmd]
}

///|
/// Build arguments that make `platform_shell_program` interpret `cmd` as shell
/// text (`-c` for `sh`).
#cfg(not(platform="windows"))
pub fn platform_shell_args(cmd : String) -> Array[String] {
  ["-c", cmd]
}
