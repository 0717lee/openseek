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
/// interpretation to stay inside the worker root: the canonicalized base cwd,
/// every statically-spelled `cd` destination (including `--`, wrapper, bare,
/// and `-` forms), and every `git -C`/`--work-tree` operand — resolved
/// against every candidate cwd the chain may be in, since a `cd` may fail at
/// runtime and a `cd` inside a pipeline runs in a subshell. Truly
/// unresolvable operands (substitutions, variables) stay admitted — on macOS
/// the kernel profile is the enforcement; this floor exists for error
/// quality and for platforms without one.
async fn worker_confinement_blocks(
  parsed : @shell_parse.ParseResult,
  base_cwd~ : String,
  worker_root~ : String,
) -> String? {
  // Containment is decided on canonical paths: an in-tree symlink pointing
  // elsewhere, or a lexically-inside `a/../..` spelling, must not pass.
  let canonical_base = canonicalize_existing(base_cwd)
  guard @workspace_path.is_under_workspace_root(worker_root, canonical_base) else {
    return Some("the command runs outside your worker tree (cwd \{base_cwd})")
  }
  worker_cd_escapes(parsed, base_cwd=canonical_base, worker_root~)
}

///|
/// Scan chained commands for static escapes, tracking the SET of candidate
/// cwds along the chain: a plain `cd` adds its destination but keeps the old
/// cwd as a candidate (the `cd` may fail at runtime), and a `cd` that is part
/// of a pipeline contributes nothing (it runs in a subshell). An operand
/// escapes when its resolution against ANY candidate leaves the worker root.
async fn worker_cd_escapes(
  parsed : @shell_parse.ParseResult,
  base_cwd~ : String,
  worker_root~ : String,
) -> String? {
  guard parsed is Simple(commands) else { return None }
  let candidates : Array[String] = [base_cwd]
  for position, command in commands {
    let argv = command.argv
    let in_pipeline = command.separator_before == Some("|") ||
      (
        position + 1 < commands.length() &&
        commands[position + 1].separator_before == Some("|")
      )
    // The effective command name skips wrappers (`command`, `env`), so
    // `command cd ..` is still a cwd change.
    match command.command_index() {
      Some(index) if argv[index] == "cd" => {
        match cd_operand(argv, index) {
          CdTo(operand) => {
            let mut moved : String? = None
            for cwd in candidates {
              match resolve_worker_operand(cwd, operand) {
                Some(resolved) => {
                  let canonical = canonicalize_existing(resolved)
                  if !@workspace_path.is_under_workspace_root(
                      worker_root, canonical,
                    ) {
                    return Some("`cd \{operand}` leaves your worker tree")
                  }
                  moved = Some(canonical)
                }
                None => ()
              }
            }
            // Outside a pipeline the destination becomes a candidate; the
            // pre-cd cwds stay candidates because the cd may fail.
            if !in_pipeline {
              match moved {
                Some(destination) =>
                  if !candidates.contains(destination) {
                    candidates.push(destination)
                  }
                None => ()
              }
            }
          }
          CdHome =>
            // Bare `cd` goes to $HOME — never the worker tree.
            return Some("`cd` (to $HOME) leaves your worker tree")
          CdBack =>
            // `cd -` returns to $OLDPWD, which this scan cannot know; the
            // quantifier is "every interpretation provably inside".
            return Some("`cd -` targets an unknowable directory")
          CdUnresolvable => ()
        }
        continue
      }
      _ => ()
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
          for cwd in candidates {
            match resolve_worker_operand(cwd, op) {
              Some(resolved) =>
                if !@workspace_path.is_under_workspace_root(
                    worker_root,
                    canonicalize_existing(resolved),
                  ) {
                  return Some("`\{arg} \{op}` points outside your worker tree")
                }
              None => ()
            }
          }
        None => ()
      }
    }
  }
  None
}

///|
priv enum CdOperand {
  CdTo(String)
  CdHome
  CdBack
  CdUnresolvable
}

///|
/// The destination of a `cd` at `argv[index]`: skip `-P`/`-L` flags and a
/// `--` separator; a bare `cd` is $HOME; `cd -` is $OLDPWD.
fn cd_operand(argv : Array[String], index : Int) -> CdOperand {
  let mut cursor = index + 1
  while cursor < argv.length() && (argv[cursor] == "-P" || argv[cursor] == "-L") {
    cursor += 1
  }
  if cursor < argv.length() && argv[cursor] == "--" {
    cursor += 1
  }
  if cursor >= argv.length() {
    return CdHome
  }
  let operand = argv[cursor]
  if operand == "-" {
    return CdBack
  }
  if operand.has_prefix("-") {
    // An unrecognized option shape; sh would reject or reinterpret it —
    // nothing this scan can resolve.
    return CdUnresolvable
  }
  CdTo(operand)
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

///|
/// Best-effort canonicalization for containment checks: realpath when the
/// path exists (resolving in-tree symlinks that point elsewhere), the
/// lexically-normalized spelling otherwise (a nonexistent directory cannot
/// be a running process's cwd either).
async fn canonicalize_existing(path : String) -> String {
  @fs.realpath(path) catch {
    error if @async.is_being_cancelled() => raise error
    _ => @path.Path(path).normalize().to_string()
  }
}
