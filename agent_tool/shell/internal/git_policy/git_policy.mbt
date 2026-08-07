// Pure git command-line policy for the shell source-write sandbox: parse a git
// invocation's subcommand and classify it. No filesystem, workspace, or
// shell-parse dependencies — just argv/word grammar — so the policy can be read
// and tested in isolation. The `shell` package supplies the workspace-path glue
// and the trusted-command-class wiring.

///|
/// A parsed git invocation: the subcommand and its index in `argv`.
pub struct Invocation {
  subcommand : String
  subcommand_index : Int
}

///|
/// Parse a git invocation starting at `arg_start` (the index just past `git`),
/// skipping global options, and return its subcommand and that subcommand's argv
/// index. Returns `None` for `--help`/`-h`, an explicit `--`, a missing argument
/// to a value option, or an unrecognized `-option` (fail closed). Aliases are not
/// resolved, so e.g. `git co` reports subcommand `co`.
pub fn parse(argv : Array[String], arg_start : Int) -> Invocation? {
  let mut index = arg_start
  while index < argv.length() {
    let arg = argv[index]
    if arg == "--" || arg == "--help" || arg == "-h" {
      return None
    }
    if arg == "-C" || arg == "--work-tree" || global_option_consumes_next(arg) {
      if index + 1 >= argv.length() {
        return None
      }
      index += 2
      continue
    }
    if attached_cwd_option(arg) is Some(_) ||
      attached_work_tree_option(arg) is Some(_) ||
      global_option_with_attached_value(arg) ||
      global_no_arg_option(arg) {
      index += 1
      continue
    }
    if arg.has_prefix("-") && arg != "-" {
      return None
    }
    return Some({ subcommand: arg, subcommand_index: index })
  }
  None
}

///|
/// True for a git global option that repoints config, the exec path, the git
/// dir, the namespace, or the cwd/worktree — a precursor that could make an
/// otherwise object-store subcommand write arbitrary bytes (via a smudge filter
/// or merge driver) or write the workspace from a different repository.
pub fn global_option_reconfigures(arg : String) -> Bool {
  global_option_consumes_next(arg) ||
  global_option_with_attached_value(arg) ||
  arg == "-C" ||
  arg == "--work-tree" ||
  attached_cwd_option(arg) is Some(_) ||
  attached_work_tree_option(arg) is Some(_)
}

///|
/// Git subcommands whose every worktree change either materializes content from
/// git's own object store (HEAD, the index, a commit/tree, or a stash) or removes
/// a tracked file recoverable from it — reviewable through git, never sourced from
/// an external file or stdin. Excluded: `mv` (moves arbitrary worktree bytes onto
/// the destination) and `clean` (deletes UNTRACKED files with no object-store
/// copy — permanent). `rm` stays: it only deletes tracked files. `rebase` also
/// writes from the object store but is trusted only in the argument forms
/// admitted by `rebase_args_are_recoverable`, so it is not listed here.
/// `submodule` is not listed either: its verbs split between recoverable writes
/// (`update`/`deinit` without force, classified per-verb by the sandbox layer),
/// `.gitmodules` writers (`set-url`/`set-branch`/`add`), and command runners
/// (`foreach`), so it is classified per-verb, not by name.
pub fn subcommand_writes_from_object_store(subcommand : String) -> Bool {
  match subcommand {
    "checkout" | "switch" | "restore" | "reset" | "stash" | "rm" => true
    _ => false
  }
}

///|
/// Whether `subcommand` writes the worktree from the object store: the
/// unconditionally recoverable writers plus `rebase`, whose recoverable forms
/// are gated by `rebase_args_are_recoverable`. Used by the custom-environment
/// pre-blocks — any of these, repointed via `GIT_DIR`/`GIT_CONFIG_*`/`env`,
/// could write workspace source from a different repository regardless of its
/// arguments.
pub fn subcommand_is_object_store_writer(subcommand : String) -> Bool {
  subcommand == "rebase" || subcommand_writes_from_object_store(subcommand)
}

///|
/// Whether a `git rebase` invocation's arguments (in `words[start..end)`) keep
/// it a recoverable object-store write: replayed content materializes from
/// commits, the pre-rebase tip stays reachable via `ORIG_HEAD` and the reflog,
/// a dirty tree is refused up front (or stashed recoverably with
/// `--autostash`), and git refuses to overwrite untracked files during replay.
///
/// Unlike the checkout guard this is an ALLOWLIST that fails closed on any
/// unrecognized token: rebase's option surface is large and includes command
/// runners (`--exec`, `-i`, `--edit-todo`, a `--strategy` resolved from the
/// exec path), and git accepts unambiguous long-option abbreviations, so only
/// exact known-safe tokens qualify — the in-progress verbs
/// (`--continue`/`--abort`/`--skip`/`--quit`), base selection
/// (`--onto <ref>`/`--onto=<ref>`/`--keep-base`,
/// `--fork-point`/`--no-fork-point`), `--autostash`/`--no-autostash`, and
/// positional revisions. Everything else falls through to the sandbox.
///
/// `--continue` does resume a rebase started outside the agent, including the
/// remaining todo steps of a user-started interactive rebase; those steps are
/// the user's own, and the agent cannot author any because the interactive
/// forms are pre-blocked (`should_preblock`).
pub fn rebase_args_are_recoverable(
  words : Array[String],
  start : Int,
  end : Int,
) -> Bool {
  let mut index = start
  while index < end {
    match words[index] {
      "--continue"
      | "--abort"
      | "--skip"
      | "--quit"
      | "--keep-base"
      | "--fork-point"
      | "--no-fork-point"
      | "--autostash"
      | "--no-autostash" => index += 1
      // The `--onto` value is a committish resolved from the object store; git
      // consumes the next word whatever it looks like, and a non-revision fails
      // resolution before anything is written.
      "--onto" => {
        if index + 1 >= end {
          return false
        }
        index += 2
      }
      arg =>
        if arg.has_prefix("--onto=") {
          index += 1
        } else if arg.has_prefix("-") && arg != "-" {
          return false
        } else {
          // A positional upstream/branch revision (`-` is the previous branch).
          index += 1
        }
    }
  }
  true
}

///|
/// Whether a `git worktree` invocation (args in `words[start..end)`, starting at
/// the verb) is a recoverable write. `add` qualifies with any flags: git
/// unconditionally refuses an existing non-empty (or file) target — `--force`
/// only relaxes the branch-checked-out-elsewhere and registered-but-missing-path
/// safeguards — so it only creates new paths whose content comes from the object
/// store, and a `-B` branch reset is reflog-recoverable like trusted `reset`.
/// `remove` qualifies only bare: git then refuses a worktree containing
/// modified or untracked files, so everything deleted is tracked and clean
/// (ignored files go silently — the same exposure as trusted `checkout`).
/// Any option before `--` fails closed, not just `-f`/`--force`: git's option
/// parser accepts unambiguous long-option abbreviations, so `--fo` forces the
/// removal too (empirically, git 2.51 destroys a dirty worktree on
/// `remove --fo`). After `--` every word is a path, so a worktree literally
/// named `-f` stays removable. `prune` touches only `$GIT_DIR/worktrees` admin
/// data. Everything else fails closed: `list` is read-only and runs fine
/// sandboxed, `move` relocates arbitrary worktree bytes like the excluded `mv`.
pub fn worktree_args_are_recoverable(
  words : Array[String],
  start : Int,
  end : Int,
) -> Bool {
  guard start < end else { return false }
  match words[start] {
    "add" | "prune" => true
    "remove" => {
      for index in (start + 1)..<end {
        let arg = words[index]
        if arg == "--" {
          break
        }
        if arg.has_prefix("-") {
          return false
        }
      }
      true
    }
    _ => false
  }
}

///|
/// Whether a git invocation must be pre-blocked before execution — the
/// cross-platform guard that does not depend on the runtime sandbox. Conservative
/// by design: block the git that mutates source but is NOT a recoverable
/// object-store write — store feeders (`apply`/`am`/`update-index`/`read-tree`/
/// `fast-import`), `mv` (moves arbitrary worktree bytes), non-dry-run `clean`
/// (permanently deletes untracked files), rebase's command-running forms
/// (`-i`/`--exec`/`--edit-todo`/a merge strategy), and any object-store writer
/// that is reconfigured (`git -c filter=… checkout`, `-C`, `--work-tree`). The
/// recoverable writers (`checkout`/`switch`/`restore`/`reset`/`stash`/`rm`,
/// rebase in its `rebase_args_are_recoverable` forms) and read-only git
/// are not pre-blocked; they run (trusted, or sandboxed where they cannot harm).
pub fn should_preblock(argv : Array[String], arg_start : Int) -> Bool {
  guard parse(argv, arg_start) is Some(invocation) else { return false }
  preblock_for_subcommand(
    argv,
    arg_start,
    invocation.subcommand_index,
    argv.length(),
  )
}

///|
/// The TooComplex text-path counterpart of `should_preblock`, scanning a flat
/// `words` list over `[start, end)`. Returns false when the subcommand requests
/// help.
pub fn text_should_preblock(
  words : Array[String],
  start : Int,
  end : Int,
) -> Bool {
  guard text_subcommand_index(words, start, end) is Some(subcommand_index) else {
    return false
  }
  preblock_for_subcommand(words, start, subcommand_index, end)
}

///|
/// Whether the git subcommand found in `words[start..end)` is an object-store
/// writer (checkout/switch/restore/reset/stash/rm, or rebase). The text path
/// uses this to decide whether a custom environment before `git` (which it cannot
/// see in `words[start..]`) makes the writer unsafe and must be pre-blocked.
pub fn text_invocation_writes_from_object_store(
  words : Array[String],
  start : Int,
  end : Int,
) -> Bool {
  match text_subcommand_index(words, start, end) {
    Some(subcommand_index) =>
      subcommand_is_object_store_writer(words[subcommand_index]) ||
      (
        words[subcommand_index] == "submodule" &&
        submodule_writes_worktree(words, subcommand_index + 1, end)
      )
    None => false
  }
}

///|
fn preblock_for_subcommand(
  words : Array[String],
  global_start : Int,
  subcommand_index : Int,
  end : Int,
) -> Bool {
  let args_start = subcommand_index + 1
  if args_start < end &&
    (words[args_start] == "--help" || words[args_start] == "-h") {
    return false
  }
  match words[subcommand_index] {
    // `apply` writes unless it is a read-only validation/info mode (`--check`,
    // `--stat`, `--numstat`, `--summary`) with no forced application.
    "apply" => apply_writes(words, args_start, end)
    "am" | "update-index" | "read-tree" | "fast-import" | "mv" => true
    // `clean` permanently deletes untracked files unless it is a dry run.
    "clean" => !clean_args_request_dry_run(words, args_start, end)
    // checkout/switch/restore can overwrite an UNTRACKED file at a path when
    // forced or sourced from another tree (`-f`/`--force`/`--source`/`--overlay`/
    // `--ours`/`--theirs`), permanently losing it (git's own untracked guard is
    // bypassed). Plain index restore (`git checkout -- f`) is fine.
    "checkout" | "switch" | "restore" =>
      region_reconfigures(words, global_start, subcommand_index) ||
      overwrites_untracked_from_tree(words, args_start, end)
    // rebase replays object-store commits (recoverable via ORIG_HEAD/reflog),
    // but its command-running forms execute arbitrary commands and must never
    // run; a reconfigured rebase is unsafe like the other writers.
    "rebase" =>
      region_reconfigures(words, global_start, subcommand_index) ||
      rebase_args_run_external_commands(words, args_start, end)
    // `submodule update` checks out commits from the object store (like
    // checkout), but its command-running and data-losing forms are pre-blocked:
    // `foreach` executes arbitrary shell commands in each submodule, and forced
    // `update`/`deinit` permanently lose dirty or untracked content. An
    // unrecognized leading option fails closed too.
    "submodule" =>
      region_reconfigures(words, global_start, subcommand_index) ||
      submodule_verb_is_unsafe(words, args_start, end)
    // The other recoverable writers are only unsafe when reconfigured.
    subcommand =>
      subcommand_writes_from_object_store(subcommand) &&
      region_reconfigures(words, global_start, subcommand_index)
  }
}

///|
/// True when a `checkout`/`switch`/`restore` form can overwrite an untracked file
/// from another tree: a force/overlay/side flag, an explicit source tree-ish
/// (`--source`/`--source=`/`-s`/`-s<tree>`), or a positional tree-ish before
/// `--` (`git checkout <tree-ish> -- <path>`). Plain index restore
/// (`git checkout -- f`, `git restore f`) and bare branch switch are excluded.
fn overwrites_untracked_from_tree(
  words : Array[String],
  start : Int,
  end : Int,
) -> Bool {
  let mut positional_before_paths = false
  for index in start..<end {
    let arg = words[index]
    // Force / overlay / side-pick overwrite regardless of untracked state. `-f`
    // may be clustered (`-fB`, `-fq`), so match it inside a short cluster too.
    if arg == "--force" ||
      arg == "--overlay" ||
      arg == "--ours" ||
      arg == "--theirs" ||
      short_cluster_has(arg, "f") {
      return true
    }
    // Explicit source tree-ish: `--source`, `--source=<t>`, `-s`, `-s<t>`.
    if arg == "--source" ||
      arg.has_prefix("--source=") ||
      arg == "-s" ||
      (arg.has_prefix("-s") && !arg.has_prefix("--")) {
      return true
    }
    // `--`, or `--pathspec-from-file`, ends the tree-ish/pathspec boundary; a
    // positional tree-ish before it (`git checkout HEAD~1 -- f`, or
    // `git checkout HEAD~1 --pathspec-from-file=list`) sources the paths from it.
    if arg == "--" ||
      arg == "--pathspec-from-file" ||
      arg.has_prefix("--pathspec-from-file=") {
      return positional_before_paths
    }
    if !arg.has_prefix("-") {
      positional_before_paths = true
    }
  }
  false
}

///|
/// True when `arg` is a short option cluster (`-…`, not `--…`) containing `flag`.
fn short_cluster_has(arg : String, flag : String) -> Bool {
  arg.has_prefix("-") &&
  !arg.has_prefix("--") &&
  arg != "-" &&
  arg.contains(flag)
}

///|
/// Whether a `git rebase` invocation's arguments (in `words[start..end)`)
/// request running external commands: `-i`/`--interactive` (sequence-editor
/// driven, `exec` todo lines), `--edit-todo` (opens the todo in an editor),
/// `-x`/`--exec` (a shell command per commit), or a merge strategy
/// (`-s`/`--strategy` resolves a `git-merge-<s>` executable from the exec
/// path; `-X`/`--strategy-option` is grouped with it conservatively). These
/// are pre-blocked cross-platform: on a platform without `sandbox-exec` they
/// would otherwise run arbitrary commands. Long options match by prefix
/// because git accepts unambiguous abbreviations (`--exe=cmd` runs the
/// command; an ambiguous prefix such as `--e` just errors in git, so
/// over-matching is harmless in a pre-block); short options match inside
/// clusters and attached-value forms (`-iv`, `-xcmd`). The scan stops at `--`:
/// past it every word is a revision, and a revision cannot begin with a dash.
fn rebase_args_run_external_commands(
  words : Array[String],
  start : Int,
  end : Int,
) -> Bool {
  for index in start..<end {
    let arg = words[index]
    if arg == "--" {
      return false
    }
    if rebase_arg_runs_external_commands(arg) {
      return true
    }
  }
  false
}

///|
fn rebase_arg_runs_external_commands(arg : String) -> Bool {
  if arg.has_prefix("--") {
    return long_option_selects(arg, "--interactive") ||
      long_option_selects(arg, "--exec") ||
      long_option_selects(arg, "--edit-todo") ||
      long_option_selects(arg, "--strategy") ||
      long_option_selects(arg, "--strategy-option")
  }
  short_cluster_has(arg, "i") ||
  short_cluster_has(arg, "x") ||
  short_cluster_has(arg, "s") ||
  short_cluster_has(arg, "X")
}

///|
/// Whether `arg` selects the long option `full`, accepting git's
/// unambiguous-abbreviation forms and an attached value: for
/// `full == "--exec"`, the args `--exec`, `--exe`, and `--exe=cmd` all match.
/// The name must extend past the bare `--` terminator, which never matches.
fn long_option_selects(arg : String, full : String) -> Bool {
  let name = match [..arg.split("=")] {
    [name, _, ..] => name.to_owned()
    _ => arg
  }
  name.length() > 2 && full.has_prefix(name)
}

///|
/// `git apply` writes the worktree/index unless it runs in a read-only
/// validation/info mode (`--check`/`--stat`/`--numstat`/`--summary`) and is not
/// forced to apply (`--apply`/`--cached`/`--index`/`--3way`). Conservative: a
/// read-only flag alongside any forcing flag is treated as writing.
fn apply_writes(words : Array[String], start : Int, end : Int) -> Bool {
  let mut read_only = false
  let mut forced = false
  for index in start..<end {
    match words[index] {
      "--check" | "--stat" | "--numstat" | "--summary" => read_only = true
      "--apply" | "--cached" | "--index" | "--3way" | "-3" => forced = true
      _ => ()
    }
  }
  forced || !read_only
}

///|
fn region_reconfigures(words : Array[String], start : Int, end : Int) -> Bool {
  for index in start..<end {
    if global_option_reconfigures(words[index]) {
      return true
    }
  }
  false
}

///|
/// True when `git clean`'s arguments request a dry run (`-n`, `--dry-run`, or a
/// short cluster such as `-fdn`; in git clean `n` always means dry run). An
/// exclude option (`-e`/`--exclude`/a cluster with `e`) takes a pattern operand
/// that could itself look like `-n` (`git clean -e -n -fd` is destructive), so
/// rather than parse git's getopt clustering this conservatively treats any clean
/// carrying an exclude as NOT a dry run — it stays blocked.
fn clean_args_request_dry_run(
  words : Array[String],
  start : Int,
  end : Int,
) -> Bool {
  let mut dry_run = false
  for index in start..<end {
    let arg = words[index]
    if clean_arg_is_exclude(arg) {
      return false
    }
    if arg == "-n" ||
      arg == "--dry-run" ||
      (arg.has_prefix("-") && !arg.has_prefix("--") && arg.contains("n")) {
      dry_run = true
    }
  }
  dry_run
}

///|
fn clean_arg_is_exclude(arg : String) -> Bool {
  arg == "-e" ||
  arg == "--exclude" ||
  arg.has_prefix("--exclude=") ||
  (arg.has_prefix("-") && !arg.has_prefix("--") && arg.contains("e"))
}

///|
/// Find the git subcommand's index in a flat `words` list (the TooComplex text
/// path), scanning `[start, end)` and skipping global options. Mirrors `parse`.
fn text_subcommand_index(words : Array[String], start : Int, end : Int) -> Int? {
  let mut index = start
  while index < end {
    let arg = words[index]
    if arg == "--help" || arg == "-h" {
      return None
    }
    if arg == "-C" || arg == "--work-tree" || global_option_consumes_next(arg) {
      index += 2
      continue
    }
    if attached_cwd_option(arg) is Some(_) ||
      attached_work_tree_option(arg) is Some(_) ||
      global_option_with_attached_value(arg) ||
      global_no_arg_option(arg) {
      index += 1
      continue
    }
    if arg.has_prefix("-") && arg != "-" {
      return None
    }
    return Some(index)
  }
  None
}

///|
fn global_option_consumes_next(arg : String) -> Bool {
  arg == "-c" ||
  arg == "--config-env" ||
  arg == "--exec-path" ||
  arg == "--git-dir" ||
  arg == "--namespace"
}

///|
fn global_option_with_attached_value(arg : String) -> Bool {
  (arg.has_prefix("-c") && arg != "-c") ||
  arg.has_prefix("--config-env=") ||
  arg.has_prefix("--exec-path=") ||
  arg.has_prefix("--git-dir=") ||
  arg.has_prefix("--namespace=")
}

///|
fn global_no_arg_option(arg : String) -> Bool {
  match arg {
    "--version"
    | "--help"
    | "-p"
    | "--paginate"
    | "-P"
    | "--no-pager"
    | "--no-replace-objects"
    | "--no-optional-locks"
    | "--no-lazy-fetch"
    | "--literal-pathspecs"
    | "--glob-pathspecs"
    | "--noglob-pathspecs"
    | "--icase-pathspecs"
    | "--bare" => true
    _ => false
  }
}

///|
/// Returns a view into `arg` (not an owned copy): every caller only tests
/// `is Some(_)`, so materializing the value would allocate for nothing.
fn attached_cwd_option(arg : String) -> StringView? {
  if arg.strip_prefix("-C") is Some(value) && !value.is_empty() {
    Some(value)
  } else {
    None
  }
}

///|
fn attached_work_tree_option(arg : String) -> StringView? {
  if arg.strip_prefix("--work-tree=") is Some(value) {
    Some(value)
  } else {
    None
  }
}

///|
/// Find the `git submodule` verb in `words[start..end)`, skipping the
/// recognized leading submodule options (`--quiet`/`-q` — the only global
/// submodule options per `git submodule -h`). Returns the verb's index, or
/// `None` for a missing verb or an unrecognized leading option (fail closed).
/// A `--help`/`-h` request also returns `None`; callers decide separately
/// whether the invocation is a help request.
fn submodule_verb_index(words : Array[String], start : Int, end : Int) -> Int? {
  let mut index = start
  while index < end {
    let arg = words[index]
    if arg == "--quiet" || arg == "-q" {
      index += 1
      continue
    }
    if arg.has_prefix("-") && arg != "-" {
      return None
    }
    return Some(index)
  }
  None
}

///|
/// True when `words[start..end)` contains a `--help`/`-h` request — used to let
/// help invocations through the submodule verb scan's fail-closed branches.
fn submodule_args_request_help(
  words : Array[String],
  start : Int,
  end : Int,
) -> Bool {
  for index in start..<end {
    if words[index] == "--help" || words[index] == "-h" {
      return true
    }
  }
  false
}

///|
/// True when a `git submodule update`/`deinit` invocation carries
/// `-f`/`--force` (also inside a short cluster). A forced update replaces
/// untracked files in a dirty submodule with the target commit's contents, and
/// a forced deinit removes a submodule worktree even with local changes — both
/// permanently lose data that has no object-store copy. The scan stops at `--`,
/// past which every word is a path.
fn submodule_forced(words : Array[String], start : Int, end : Int) -> Bool {
  for index in start..<end {
    let arg = words[index]
    if arg == "--" {
      break
    }
    if arg == "--force" || short_cluster_has(arg, "f") {
      return true
    }
  }
  false
}

///|
/// Whether a `git submodule` invocation must be pre-blocked: `foreach` (runs an
/// arbitrary shell command in each submodule — the only exception is a bare
/// `--help` request), `update`/`deinit` with `-f`/`--force` (permanently lose
/// dirty or untracked content), and any form whose leading options the verb
/// scan cannot parse (fail closed; a help request is let through).
fn submodule_verb_is_unsafe(
  words : Array[String],
  start : Int,
  end : Int,
) -> Bool {
  match submodule_verb_index(words, start, end) {
    None => !submodule_args_request_help(words, start, end)
    Some(verb_index) =>
      match words[verb_index] {
        "foreach" => !submodule_args_request_help(words, verb_index + 1, end)
        "update" | "deinit" => submodule_forced(words, verb_index + 1, end)
        _ => false
      }
  }
}

///|
/// Whether a `git submodule` invocation writes the worktree from its own
/// repository state (`update`/`deinit`), for the custom-environment pre-block:
/// repointed via `GIT_DIR`/`GIT_CONFIG_*` it could write source from a
/// different repository. The sandbox layer mirrors this classification in its
/// own private helpers so the public interface of this package stays stable.
fn submodule_writes_worktree(
  words : Array[String],
  start : Int,
  end : Int,
) -> Bool {
  guard submodule_verb_index(words, start, end) is Some(verb_index) else {
    return false
  }
  words[verb_index] == "update" || words[verb_index] == "deinit"
}
