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
/// Git subcommands that can place content from OUTSIDE the object store into
/// git's store or worktree, which a later trusted `checkout`/`restore` would
/// materialize into source: external-patch (`apply`/`am`) and the plumbing
/// feeders `update-index`, `read-tree`, and `fast-import`. Not exhaustive —
/// `replace`/`filter-branch`/`commit-tree` remain a residual channel while `.git`
/// is writable.
pub fn subcommand_is_store_feeder(subcommand : String) -> Bool {
  match subcommand {
    "apply" | "am" | "update-index" | "read-tree" | "fast-import" => true
    _ => false
  }
}

///|
/// Find the git subcommand's index in a flat `words` list (the TooComplex text
/// path), scanning `[start, end)` and skipping global options. Mirrors `parse`.
pub fn text_subcommand_index(
  words : Array[String],
  start : Int,
  end : Int,
) -> Int? {
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
/// True when the git subcommand at `subcommand_index` in `words` is a store
/// feeder that must be pre-blocked in the text path (false when its first
/// argument requests help).
pub fn text_subcommand_is_store_feeder(
  words : Array[String],
  subcommand_index : Int,
  segment_end : Int,
) -> Bool {
  let help_index = subcommand_index + 1
  if help_index < segment_end &&
    (words[help_index] == "--help" || words[help_index] == "-h") {
    return false
  }
  subcommand_is_store_feeder(words[subcommand_index])
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
