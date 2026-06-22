///|
/// Return the effective command name for this simple command.
///
/// This strips leading environment assignments represented in `env`, and also
/// recognizes the common `env NAME=value command ...` wrapper. It deliberately
/// avoids interpreting complex `env` option forms; those remain `env`.
pub fn SimpleCommand::command_name(self : SimpleCommand) -> String? {
  effective_command_name(self.argv)
}

///|
/// True when the parsed result contains a simple command with the requested
/// effective command name.
pub fn contains_command(result : ParseResult, name : String) -> Bool {
  match result {
    Simple(commands) =>
      commands.any(command => command.command_name() == Some(name))
    _ => false
  }
}

///|
/// True when the parsed result contains a statically visible directory-changing
/// command (`cd`, `pushd`, or `popd`).
pub fn has_cd(result : ParseResult) -> Bool {
  match result {
    Simple(commands) =>
      commands.any(command => {
        match command.command_name() {
          Some("cd" | "pushd" | "popd") => true
          _ => false
        }
      })
    _ => false
  }
}

///|
/// True when the parsed result contains both a directory-changing command and a
/// command with the requested effective name.
pub fn has_cd_and_command(result : ParseResult, name : String) -> Bool {
  has_cd(result) && contains_command(result, name)
}

///|
fn effective_command_name(argv : Array[String]) -> String? {
  if argv.length() == 0 {
    return None
  }
  match argv[0] {
    "env" => env_wrapped_command_name(argv)
    "command" | "builtin" =>
      if argv.length() > 1 {
        Some(argv[1])
      } else {
        Some(argv[0])
      }
    command => Some(command)
  }
}

///|
fn env_wrapped_command_name(argv : Array[String]) -> String? {
  let mut index = 1
  while index < argv.length() {
    let arg = argv[index]
    if arg == "--" {
      index += 1
      break
    }
    if is_env_assignment_word(arg) {
      index += 1
      continue
    }
    if arg == "-i" || arg == "-" {
      index += 1
      continue
    }
    if arg.has_prefix("-") {
      return Some("env")
    }
    return Some(arg)
  }
  if index < argv.length() {
    Some(argv[index])
  } else {
    Some("env")
  }
}
