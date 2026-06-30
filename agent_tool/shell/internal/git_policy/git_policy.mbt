// Pure git command-line policy for the shell source-write sandbox: parse a git
// invocation's subcommand and classify it. No filesystem, workspace, or
// shell-parse dependencies — just argv/word grammar — so the policy can be read
// and tested in isolation. The `shell` package supplies the workspace-path glue
// and the trusted-command-class wiring.

///|
/// A parsed git invocation: the subcommand and its index in `argv`.
pub(all) struct Invocation {
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
/// copy — permanent). `rm` stays: it only deletes tracked files.
pub fn subcommand_writes_from_object_store(subcommand : String) -> Bool {
  match subcommand {
    "checkout" | "switch" | "restore" | "reset" | "stash" | "rm" => true
    _ => false
  }
}

///|
/// Whether a git invocation must be pre-blocked before execution — the
/// cross-platform guard that does not depend on the runtime sandbox. Conservative
/// by design: block the git that mutates source but is NOT a recoverable
/// object-store write — store feeders (`apply`/`am`/`update-index`/`read-tree`/
/// `fast-import`), `mv` (moves arbitrary worktree bytes), non-dry-run `clean`
/// (permanently deletes untracked files), and any object-store writer that is
/// reconfigured (`git -c filter=… checkout`, `-C`, `--work-tree`). The recoverable
/// writers (`checkout`/`switch`/`restore`/`reset`/`stash`/`rm`) and read-only git
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
    // A recoverable object-store writer is only unsafe when reconfigured.
    subcommand =>
      subcommand_writes_from_object_store(subcommand) &&
      region_reconfigures(words, global_start, subcommand_index)
  }
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
fn attached_cwd_option(arg : String) -> String? {
  if arg.has_prefix("-C") && arg != "-C" {
    Some(arg[2:].to_owned())
  } else {
    None
  }
}

///|
fn attached_work_tree_option(arg : String) -> String? {
  if arg.has_prefix("--work-tree=") {
    Some(arg["--work-tree=".length():].to_owned())
  } else {
    None
  }
}
