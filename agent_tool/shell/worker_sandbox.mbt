///|
/// The write confinement of a worker subagent's shell, carried from the
/// subtask controller (which computes the canonical geometry at provision
/// time) into every launch. When present, shell classification is bypassed:
/// every command — including classes the normal registry trusts to run
/// unsandboxed — launches under the worker write profile, which denies the
/// repository's shared surfaces (`deny_roots`: the canonical common git dir
/// plus every enumerated worktree root) and re-allows only the worker's own
/// tree and its private git admin dir. All paths must be canonical
/// (realpath'd): the kernel matches profile rules against realpaths.
///
/// On platforms without sandbox-exec the kernel layer is absent and the
/// static confinement floor (`worker_confinement_blocks`) is the only guard —
/// the same best-effort posture as the rest of the sandbox stack there.
pub(all) struct WorkerSandbox {
  deny_roots : Array[String]
  worker_root : String
  worker_admin_dir : String
}

///|
/// The static confinement floor for worker mode: block, before launch, the
/// command shapes that OBVIOUSLY leave the worker tree, with an explanation a
/// kernel denial cannot give. Admission requires every resolvable cwd
/// interpretation to stay inside the worker root: the base cwd, every
/// statically-spelled `cd` destination, and every `git -C`/`--work-tree`
/// operand. Anything unresolvable stays admitted — on macOS the kernel
/// profile is the enforcement; this floor exists for error quality and for
/// platforms without one.
fn worker_confinement_blocks(
  parsed : @shell_parse.ParseResult,
  base_cwd~ : String,
  worker_root~ : String,
) -> String? {
  if @workspace_path.is_under_workspace_root(worker_root, base_cwd) {
    worker_cd_escapes(parsed, base_cwd~, worker_root~)
  } else {
    Some("the command runs outside your worker tree (cwd \{base_cwd})")
  }
}

///|
/// Scan chained commands for static escapes: `cd <outside>` and
/// `git -C <outside>` / `--work-tree=<outside>`. Relative operands resolve
/// against the tracked cwd along the chain; unresolvable operands (command
/// substitution, variables) stay admitted for the kernel to judge.
fn worker_cd_escapes(
  parsed : @shell_parse.ParseResult,
  base_cwd~ : String,
  worker_root~ : String,
) -> String? {
  guard parsed is Simple(commands) else { return None }
  let mut cwd = base_cwd
  for command in commands {
    let argv = command.argv
    if argv.length() >= 2 && argv[0] == "cd" && !argv[1].has_prefix("-") {
      let target = resolve_worker_operand(cwd, argv[1])
      match target {
        Some(resolved) => {
          if !@workspace_path.is_under_workspace_root(worker_root, resolved) {
            return Some("`cd \{argv[1]}` leaves your worker tree")
          }
          cwd = resolved
        }
        None => ()
      }
    }
    for index, arg in argv {
      let operand = if arg == "-C" || arg == "--work-tree" {
        if index + 1 < argv.length() {
          Some(argv[index + 1])
        } else {
          None
        }
      } else if arg.has_prefix("--work-tree=") {
        arg.view(start_offset="--work-tree=".length()).to_owned() |> Some
      } else {
        None
      }
      match operand {
        Some(op) =>
          match resolve_worker_operand(cwd, op) {
            Some(resolved) if !@workspace_path.is_under_workspace_root(
                worker_root, resolved,
              ) => return Some("`\{arg} \{op}` points outside your worker tree")
            _ => ()
          }
        None => ()
      }
    }
  }
  None
}

///|
/// Lexically resolve one statically-spelled operand against `cwd`; `None`
/// for shapes only the shell can evaluate (substitutions, variables, `~`).
fn resolve_worker_operand(cwd : String, operand : String) -> String? {
  if operand.contains("$") || operand.contains("`") || operand.has_prefix("~") {
    return None
  }
  let joined = if @path.Path(operand).is_absolute() {
    operand
  } else {
    "\{cwd}/\{operand}"
  }
  Some(@path.Path(joined).normalize().to_string())
}
