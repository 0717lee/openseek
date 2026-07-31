///|
/// One command to spawn, either plain or backed by a prepared source-write
/// sandbox command.
///
/// Keeping these together ensures the task group that prepares a sandbox
/// profile also owns the process that uses it.
struct ProcessCommand {
  command : ProcessCommandKind
}

///|
priv enum ProcessCommandKind {
  Plain(String, Array[String])
  Sandboxed(@sandbox.SandboxedCommand)
}

///|
/// Construct an ordinary process command with no sandbox profile to own.
pub fn ProcessCommand::plain(
  program : String,
  args : Array[String],
) -> ProcessCommand {
  { command: Plain(program, args) }
}

///|
/// Construct the exact process command represented by `sandboxed_command`.
pub fn ProcessCommand::sandboxed(
  sandboxed_command : @sandbox.SandboxedCommand,
) -> ProcessCommand {
  { command: Sandboxed(sandboxed_command) }
}

///|
/// Prepare program and argv inside the task group that will own the process.
pub async fn[X] ProcessCommand::prepare_for_spawn(
  self : ProcessCommand,
  group : @async.TaskGroup[X],
) -> (String, Array[String]) {
  match self.command {
    Plain(program, args) => (program, args.copy())
    Sandboxed(command) => command.prepare_for_spawn(group)
  }
}

///|
/// Prepared sandbox command, when this process owns a temporary SBPL file.
pub fn ProcessCommand::sandboxed_command(
  self : ProcessCommand,
) -> @sandbox.SandboxedCommand? {
  match self.command {
    Plain(_, _) => None
    Sandboxed(command) => Some(command)
  }
}
