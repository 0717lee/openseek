///|
/// Return the effective command name for this simple command.
///
/// This strips leading environment assignments represented in `env`, and also
/// recognizes the common `env NAME=value command ...` wrapper. It deliberately
/// avoids interpreting complex `env` option forms; those remain `env`.
pub fn SimpleCommand::command_name(self : SimpleCommand) -> String? {
  match self.command_index() {
    Some(index) if index < self.argv.length() => Some(self.argv[index])
    _ => None
  }
}

///|
/// Return the index in `argv` of this command's effective command word.
///
/// This is the index-aware counterpart of `command_name()`, so consumers that
/// need to continue scanning command flags do not have to duplicate wrapper
/// grammar.
pub fn SimpleCommand::command_index(self : SimpleCommand) -> Int? {
  effective_command_index(self.argv)
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
fn effective_command_index(argv : Array[String]) -> Int? {
  if argv.length() == 0 {
    return None
  }
  match argv[0] {
    "env" => env_wrapped_command_index(argv)
    "command" => command_wrapped_command_index(argv)
    "builtin" =>
      if argv.length() > 1 {
        let index = if argv[1] == "--" { 2 } else { 1 }
        if index < argv.length() {
          Some(index)
        } else {
          Some(0)
        }
      } else {
        Some(0)
      }
    _ => Some(0)
  }
}

///|
fn command_wrapped_command_index(argv : Array[String]) -> Int? {
  let mut index = 1
  while index < argv.length() {
    let arg = argv[index]
    if arg == "--" {
      index += 1
      break
    }
    if arg == "-p" {
      index += 1
      continue
    }
    if arg == "-v" || arg == "-V" || arg.has_prefix("-") {
      return Some(0)
    }
    return Some(index)
  }
  if index < argv.length() {
    Some(index)
  } else {
    Some(0)
  }
}

///|
fn env_wrapped_command_index(argv : Array[String]) -> Int? {
  let mut index = 1
  let mut scanning_options = true
  while index < argv.length() {
    let arg = argv[index]
    if scanning_options && arg == "--" {
      scanning_options = false
      index += 1
      continue
    }
    if scanning_options && (arg == "-i" || arg == "-") {
      index += 1
      continue
    }
    if scanning_options && arg.has_prefix("-") {
      return Some(0)
    }
    if is_env_assignment_word(arg) {
      scanning_options = false
      index += 1
      continue
    }
    return Some(index)
  }
  if index < argv.length() {
    Some(index)
  } else {
    Some(0)
  }
}
