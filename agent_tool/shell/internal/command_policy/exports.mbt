// Deliberate exports with no in-repo production consumer (see
// shrink_package.md): test seams, round-trip/protocol surface, and
// future-proof API kept on purpose. Each entry documents its reason.

///|
/// Policy gate for agent shell commands: returns the error to feed back to
/// the model when `cmd` must not run, or `None` when it may.
///
/// `moon check` (and every other `moon` subcommand) runs through shell; the
/// only redirection left is the tool name `moon_cmd` typed as a shell command,
/// which is pointed back at running `moon ...` directly. `sed -i` (in-place file
/// editing) is also blocked: it silently misapplies edits often enough to be
/// untrustworthy, so the model is sent to targeted edit tools instead. The
/// error wording tells the model what to do, because the model is the caller who
/// reads it.
pub fn moonbit_command_policy_error(cmd : String) -> String? {
  let parsed = @shell_parse.parse_for_policy(cmd)
  moonbit_command_policy_error_for_parse(cmd, parsed)
}
