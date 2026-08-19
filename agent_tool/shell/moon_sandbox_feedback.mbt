///|
/// The standalone Moon writer that lost its trusted classification because it
/// was combined with a pipeline or unsupported companion command. `None` also
/// covers trusted Moon-only chains: those already run with source-write access
/// and must not receive decomposition advice if a different sandbox denies
/// them (for example, a worker sandbox).
fn downgraded_moon_source_writer(parsed : @shell_parse.ParseResult) -> String? {
  guard parsed is Simple(commands) else { return None }
  if commands_are_trusted_source_writes(commands) {
    return None
  }
  for command in commands {
    guard command.command_index() is Some(command_index) else { continue }
    guard command_index < command.argv.length() else { continue }
    guard command.argv[command_index] == "moon" else { continue }
    guard trusted_moon_command_class(command, command_index)
      is TrustedCommandWrite else {
      continue
    }
    guard parse_moon_invocation(command.argv, command_index, ".")
      is Some(invocation) else {
      continue
    }
    return Some("moon \{command.argv[invocation.subcommand_index]}")
  }
  None
}

///|
/// `moon info` builds interfaces under `_build`, then copies them to tracked
/// `pkg.generated.mbti` files. This stable diagnostic identifies that final
/// copy being denied even when shell expansion (such as `$?`) made the command
/// too complex for policy parsing.
fn output_has_moon_info_copy_denial(output : String) -> Bool {
  output.contains("Failed to copy generated mbti file") &&
  output.contains("pkg.generated.mbti: Operation not permitted")
}

///|
/// More actionable feedback for the whole-command sandbox limitation. This
/// replaces the generic "use edit" advice: generated interfaces must be
/// written by Moon, and manually editing them would be the wrong recovery.
fn shell_sandbox_denial_feedback(
  parsed : @shell_parse.ParseResult,
  output : String,
) -> String {
  let moon_writer = match downgraded_moon_source_writer(parsed) {
    Some(command) => Some(command)
    None if parsed is TooComplex(_) && output_has_moon_info_copy_denial(output) =>
      Some("moon info")
    None => None
  }
  match moon_writer {
    None => SandboxSourceWriteFeedback
    Some(command) =>
      (
        $|shell sandbox: the `\{command}` invocation was combined with a pipeline or
        $|unsupported companion command, so the whole shell request ran read-only and
        $|Moon's generated source writes were blocked. Run the Moon invocation in its own
        $|shell call. If its output needs filtering, redirect it to a temporary file outside
        $|the workspace source tree in that call, then inspect the file in a second shell
        $|call. For example:
        $|
        $|  moon info >/tmp/moon-info.log 2>&1
        $|  grep "pattern" /tmp/moon-info.log
        $|
        $|Do not retry the same compound command or edit generated interface files manually.
      )
  }
}
