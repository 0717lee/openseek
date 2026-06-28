///|
/// Whether a single parsed command is a source-mutating `moon` invocation
/// (fmt / info / install / test --update / ...). Unlike
/// `auto_check_cwd_for_moon_command`, this does NOT skip env-prefixed commands
/// or depend on cwd: read-only enforcement must err toward blocking, so e.g.
/// `FOO=bar moon fmt` is still caught.
fn command_is_mutating_moon(command : @shell_parse.SimpleCommand) -> Bool {
  match moon_command_start(command) {
    Some(index) =>
      match parse_moon_invocation(command.argv, index, ".") {
        Some(invocation) =>
          !invocation.dry_run &&
          is_auto_check_moon_subcommand(
            command.argv,
            invocation.subcommand_index,
          )
        None => false
      }
    None => false
  }
}

///|
/// Whether read-only (review) mode should refuse this parsed command. This is a
/// best-effort guard, not an airtight guarantee: it blocks the obvious bulk
/// source-rewriters — a source-mutating moon command (fmt / info / test
/// --update / ...) anywhere in a `Simple` parse, including `&&`/`;` chains,
/// pipes, and env prefixes — so a review does not reformat or regenerate the
/// tree wholesale. Opaque commands (`TooComplex`: subshells, command
/// substitution) are allowed: a review that runs `moon check`/`moon test` can
/// already trigger pre-build source generation, so chasing every last mutation
/// is not worth crippling the review's ability to investigate.
fn review_read_only_blocks(parsed : @shell_parse.ParseResult) -> Bool {
  match parsed {
    Simple(commands) => {
      for command in commands {
        if command_is_mutating_moon(command) {
          return true
        }
      }
      false
    }
    _ => false
  }
}
