///|
/// The canonical git geometry every subtask operation is decided against.
/// Resolved ONCE per operation from `git rev-parse` and `git worktree list`
/// output — never constructed from names (private admin dirs can carry
/// numeric suffixes; worktrees can live anywhere).
pub struct Geometry {
  /// Canonical origin toplevel — must be the MAIN worktree (v1 precondition).
  origin_root : String
  /// Canonical common git dir (shared objects/refs/config).
  common_git_dir : String
  /// Every registered worktree root, canonicalized, origin included.
  worktree_roots : Array[String]
}

///|
/// Resolve and validate the geometry for `workspace_root`. `Err` names the
/// violated precondition: the workspace must be a git repository's MAIN
/// worktree toplevel — a linked worktree's private/common split breaks the
/// deny-root reasoning, so v1 rejects it outright.
pub async fn resolve_geometry(
  workspace_root : String,
) -> Result[Geometry, String] {
  let probe = git_run(
    ["rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-common-dir"],
    cwd=workspace_root,
  )
  guard probe.exit_code == 0 else {
    return Err("subtask needs a git repository: \{probe.output.trim()}")
  }
  let lines = probe.output
    .trim()
    .to_owned()
    .split("\n")
    .map(l => l.to_owned())
    .collect()
  guard lines.length() == 3 else {
    return Err("unexpected rev-parse output: \{probe.output}")
  }
  let toplevel = canonical(lines[0])
  let git_dir = canonical(lines[1])
  let common = canonical(absolutize_against(lines[2], toplevel))
  let workspace = canonical(workspace_root)
  guard workspace == toplevel else {
    return Err(
      "subtask needs the repository toplevel as its workspace (got \{workspace}, toplevel \{toplevel})",
    )
  }
  guard git_dir == common else {
    return Err(
      "subtask needs the MAIN worktree — this workspace is a linked worktree (git dir \{git_dir}, common \{common})",
    )
  }
  let listing = git_run(["worktree", "list", "--porcelain", "-z"], cwd=toplevel)
  guard listing.exit_code == 0 else {
    return Err("git worktree list failed: \{listing.output.trim()}")
  }
  let worktree_roots : Array[String] = []
  for record in listing.output.split("\u{0}") {
    let record = record.to_owned()
    if record.has_prefix("worktree ") {
      worktree_roots.push(
        canonical(record.view(start_offset="worktree ".length()).to_owned()),
      )
    }
  }
  guard !worktree_roots.is_empty() else {
    return Err("git worktree list reported no worktrees")
  }
  Ok({ origin_root: toplevel, common_git_dir: common, worktree_roots })
}

///|
/// realpath when possible; lexical normalization otherwise (a nonexistent
/// path cannot be part of live geometry, but error messages still read).
async fn canonical(path : String) -> String {
  let real = @fs.realpath(path) catch {
    error if @async.is_being_cancelled() => raise error
    _ => path
  }
  @workspace_path.strip_trailing_slash(real)
}

///|
/// `--git-common-dir` may print a path relative to the cwd of the probe.
fn absolutize_against(path : String, base : String) -> String {
  if @path.Path(path).is_absolute() {
    path
  } else {
    "\{base}/\{path}"
  }
}
