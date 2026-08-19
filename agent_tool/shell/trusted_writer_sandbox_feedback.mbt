///|
/// A concise label for a trusted source writer. Arguments are intentionally
/// omitted: reconstructing shell quoting from parsed argv would produce advice
/// that looks executable but may not preserve the original command.
fn trusted_source_writer_label(
  command : @shell_parse.SimpleCommand,
  command_index : Int,
) -> String? {
  match command.argv[command_index] {
    "moon" =>
      match parse_moon_invocation(command.argv, command_index, ".") {
        Some(invocation) =>
          Some("moon \{command.argv[invocation.subcommand_index]}")
        None => None
      }
    "git" =>
      match @git_policy.parse(command.argv, command_index + 1) {
        Some(invocation) => Some("git \{invocation.subcommand}")
        None => None
      }
    _ => None
  }
}

///|
/// The trusted source writers that lost their classification because they were
/// combined with a pipeline or unsupported companion command. An empty result
/// also covers trusted writer-only chains: those already run with source-write
/// access and must not receive decomposition advice if a different sandbox
/// denies them (for example, a worker sandbox).
fn downgraded_trusted_source_writers(
  parsed : @shell_parse.ParseResult,
) -> Array[String] {
  guard parsed is Simple(commands) else { return [] }
  if commands_are_trusted_source_writes(commands) {
    return []
  }
  let writers : Array[String] = []
  for index, command in commands {
    guard command.command_index() is Some(command_index) else { continue }
    guard command_index < command.argv.length() else { continue }
    guard trusted_command_class(command, commands, index) is TrustedCommandWrite else {
      continue
    }
    guard trusted_source_writer_label(command, command_index) is Some(writer) else {
      continue
    }
    if !writers.contains(writer) {
      writers.push(writer)
    }
  }
  writers
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
/// replaces the generic "use edit" advice when the correct recovery is to run
/// each normally trusted source writer as a separate shell call.
fn shell_sandbox_denial_feedback(
  parsed : @shell_parse.ParseResult,
  output : String,
) -> String {
  let source_writers = downgraded_trusted_source_writers(parsed)
  if source_writers.length() == 0 &&
    parsed is TooComplex(_) &&
    output_has_moon_info_copy_denial(output) {
    source_writers.push("moon info")
  }
  if source_writers.length() == 0 {
    SandboxSourceWriteFeedback
  } else {
    let writer_list = source_writers.map(writer => "  - `\{writer}`").join("\n")
    (
      $|shell sandbox: trusted source-writing commands were combined with a pipeline or
      $|unsupported companion command, so the whole shell request ran read-only and
      $|their source-tree writes were blocked. Run each detected writer in its own
      $|shell call:
      $|
      $|\{writer_list}
      $|
      $|Use the original arguments for each invocation. If output needs filtering,
      $|redirect it to a temporary file outside the workspace source tree in that call,
      $|then inspect the file in a second shell call. Do not retry the same compound
      $|command or route around the sandbox with shell rewrites.
    )
  }
}
