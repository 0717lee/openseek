// The topbar's branch chip: report the git branch of a conversation's
// working directory. Display only — a missing repository (or a machine
// without git) simply reads as "no branch", never an error.

///|
async fn git_branch_op(payload : GitBranchPayload) -> GitBranchReply {
  // A live run hands us its cwd; a resumed conversation has none, so fall
  // back to the directory the session's engine runs in (mirrors
  // `host.open_path`).
  let base = match payload.cwd {
    Some(cwd) => @pathx.Absolute::from_uri_path(cwd)
    None => @engine.session_cwd(payload.session)
  }
  guard base is Some(base) else { return { branch: None } }
  { branch: git_branch(base.0) }
}

///|
/// The branch checked out at `dir` (`git rev-parse --abbrev-ref HEAD`), with
/// a detached HEAD named by its short hash instead of the literal "HEAD".
/// None when `dir` is not a git repository or git is unavailable.
async fn git_branch(dir : String) -> String? {
  let name = git_output(dir, ["rev-parse", "--abbrev-ref", "HEAD"])
  let name = if name == "HEAD" {
    git_output(dir, ["rev-parse", "--short", "HEAD"])
  } else {
    name
  }
  if name.is_empty() {
    None
  } else {
    Some(name)
  }
}

///|
/// Remove Git subprocess overrides while retaining PATH, identity, locale, and
/// the user's ordinary Git configuration through HOME/XDG_CONFIG_HOME. Hooks
/// and nested Git commands export repository-local variables, and explicit
/// config/quarantine overrides can redirect object and hook lookup too. The
/// desktop host must instead discover everything from its validated workspace
/// `cwd`. Matching is case-insensitive because Windows preserves arbitrary key
/// casing; removing the whole namespace also covers future Git overrides.
fn sanitize_git_environment(env : Map[String, String]) -> Unit {
  let remove : Array[String] = []
  for name, _ in env {
    if name.to_upper().has_prefix("GIT_") {
      remove.push(name)
    }
  }
  for name in remove {
    env.remove(name)
  }
}

///|
fn git_environment() -> Map[String, String] {
  let env = @sys.get_env_vars()
  sanitize_git_environment(env)
  env
}

///|
async fn git_output(dir : String, args : Array[String]) -> String {
  let (code, stdout, _) = @process.collect_output(
    "git",
    args,
    cwd=dir,
    extra_env=git_environment(),
    inherit_env=false,
  ) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return ""
  }
  guard code == 0 else { return "" }
  (stdout.text() catch { _ => "" }).trim().to_owned()
}

///|
/// The presentation category for Git's two porcelain status columns.
fn git_change_kind(index_status : String, worktree_status : String) -> String {
  let pair = index_status + worktree_status
  if ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(pair) {
    "unmerged"
  } else if pair == "??" {
    "untracked"
  } else if index_status == "R" || worktree_status == "R" {
    "renamed"
  } else if index_status == "C" || worktree_status == "C" {
    "copied"
  } else if index_status == "D" || worktree_status == "D" {
    "deleted"
  } else if index_status == "A" || worktree_status == "A" {
    "added"
  } else if index_status == "T" || worktree_status == "T" {
    "type-changed"
  } else {
    "modified"
  }
}

///|
/// Parse `git status --porcelain=v1 -z`. In `-z` mode rename/copy rows spell
/// the destination in the status record and consume the following NUL field
/// as their source, without the human-facing ` -> ` separator.
fn parse_git_status_z(output : String) -> Array[GitChange] {
  let fields = output.split("\u{0}").map(field => field.to_owned()).collect()
  let changes : Array[GitChange] = []
  let mut index = 0
  while index < fields.length() {
    let record = fields[index]
    if record.length() < 4 {
      index += 1
      continue
    }
    let index_status = record.view(end_offset=1).to_owned()
    let worktree_status = record.view(start_offset=1, end_offset=2).to_owned()
    let path = record.view(start_offset=3).to_owned()
    let has_source = index_status == "R" ||
      worktree_status == "R" ||
      index_status == "C" ||
      worktree_status == "C"
    let original_path = if has_source &&
      index + 1 < fields.length() &&
      !fields[index + 1].is_empty() {
      index += 1
      Some(fields[index])
    } else {
      None
    }
    changes.push({
      path,
      original_path,
      index_status,
      worktree_status,
      kind: git_change_kind(index_status, worktree_status),
    })
    index += 1
  }
  changes.sort_by((left, right) => left.path.lexical_compare(right.path))
  changes
}

///|
/// Porcelain v1 always spells paths from the repository root. Convert one
/// row back to the conversation workspace, which may itself be an attached
/// repository subdirectory. `git status -- .` guarantees the current path is
/// inside that prefix; defensively drop any row that violates that boundary.
/// A rename source outside the attached subdirectory is not addressable by
/// the workspace-scoped baseline endpoint, so omit only that source metadata.
fn git_change_relative_to_workspace(
  change : GitChange,
  workspace_prefix : String,
) -> GitChange? {
  guard git_path_relative_to_workspace(change.path, workspace_prefix)
    is Some(path) else {
    return None
  }
  let original_path = match change.original_path {
    Some(original) => git_path_relative_to_workspace(original, workspace_prefix)
    _ => None
  }
  Some({ ..change, path, original_path })
}

///|
fn git_path_relative_to_workspace(
  path : String,
  workspace_prefix : String,
) -> String? {
  let path = if workspace_prefix.is_empty() {
    path
  } else {
    guard path.has_prefix(workspace_prefix) else { return None }
    path.view(start_offset=workspace_prefix.length()).to_owned()
  }
  if path.is_empty() {
    None
  } else {
    Some(path)
  }
}

///|
/// Extract one entry mode from `git ls-files --stage -z` or `git ls-tree -z`.
/// Index/HEAD metadata keeps gitlinks and symlinks identifiable even when a
/// sparse checkout or deletion leaves no path to inspect. Both formats start
/// with the six-digit mode and keep the byte-exact path after a tab.
fn parse_git_mode_paths(
  output : String,
  workspace_prefix : String,
  mode : String,
) -> Set[String] {
  let paths : Set[String] = Set([])
  let prefix = mode + " "
  for record in output.split("\u{0}") {
    guard record.has_prefix(prefix) && record.find("\t") is Some(tab) else {
      continue
    }
    let path = record.view(start_offset=tab + 1).to_owned()
    if git_path_relative_to_workspace(path, workspace_prefix) is Some(relative) {
      paths.add(relative)
    }
  }
  paths
}

///|
/// Keep targeted `ls-tree` argv comfortably below Windows' command-line limit
/// (and every supported Unix ARG_MAX). An individually over-limit path asks
/// the caller to use one recursive workspace tree walk instead.
const MaxGitTreePathBatchBytes = 16_384

///|
/// Targeted HEAD mode discovery is cheaper than walking the full workspace
/// tree only while it needs a small, bounded number of Git subprocesses.
/// Beyond this cap one recursive `ls-tree` has lower fixed overhead.
const MaxTargetedGitTreeQueries = 8

///|
fn git_tree_path_batches(paths : Array[String]) -> Array[Array[String]] {
  let batches : Array[Array[String]] = []
  let mut batch : Array[String] = []
  let mut bytes = 0
  for path in paths {
    // Git argv is UTF-8 on Unix and the byte bound is deliberately also
    // conservative for Windows' UTF-16 command line. Character count would
    // under-budget non-ASCII repository paths by up to four times.
    let path_bytes = @utf8.encode(path).length() + 1
    if path_bytes > MaxGitTreePathBatchBytes {
      return []
    }
    if !batch.is_empty() && bytes + path_bytes > MaxGitTreePathBatchBytes {
      if batches.length() >= MaxTargetedGitTreeQueries {
        return []
      }
      batches.push(batch)
      batch = []
      bytes = 0
    }
    batch.push(path)
    bytes += path_bytes
  }
  if !batch.is_empty() {
    if batches.length() >= MaxTargetedGitTreeQueries {
      return []
    }
    batches.push(batch)
  }
  batches
}

///|
/// Collect each deleted status path once without repeatedly scanning the
/// growing result during a bulk deletion.
fn deleted_change_paths(changes : Array[GitChange]) -> Array[String] {
  let paths : Array[String] = []
  let seen : Set[String] = Set([])
  for change in changes {
    if change.kind == "deleted" && !seen.contains(change.path) {
      seen.add(change.path)
      paths.push(change.path)
    }
  }
  paths
}

///|
/// Git's ordinary porcelain columns do not distinguish a changed gitlink from
/// a changed regular file or expose the working tree's symlink kind. Preserve
/// the raw columns while keeping both non-file kinds out of ordinary readers.
fn git_change_with_path_kind(
  change : GitChange,
  path_kind : @fs.FileKind,
  known_gitlink : Bool,
  known_symlink : Bool,
) -> GitChange {
  match path_kind {
    SymLink => { ..change, kind: "symlink" }
    Directory if change.kind != "untracked" => { ..change, kind: "submodule" }
    Unknown if known_gitlink => { ..change, kind: "submodule" }
    Unknown if known_symlink => { ..change, kind: "symlink" }
    _ => change
  }
}

///|
/// Git's textual plumbing commands terminate their single-line output with a
/// line ending. Remove only that terminator: leading or trailing spaces can be
/// significant in repository paths.
fn git_single_line(output : String) -> String {
  output.trim_end(chars="\r\n").to_owned()
}

///|
/// Validate an untrusted Git tree path lexically. Unlike ordinary file reads,
/// this must not follow the current working-tree symlink: `HEAD:path` reads a
/// repository object and is safe even when that symlink now points outside.
fn git_tree_relative(path : String) -> @pathx.Relative? {
  guard @pathx.Path(path).to_relative() is Some(relative) else { return None }
  let relative = relative.normalize()
  guard relative.0 != ".." && !relative.0.has_prefix("../") else { return None }
  Some(relative)
}

///|
/// Run Git without trimming or merging stdout: porcelain `-z` and blob bytes
/// are byte-sensitive. Cancellation remains observable to the connection;
/// other spawn failures become ordinary request errors.
async fn git_collect(
  dir : String,
  args : Array[String],
) -> (Int, &@io.Data, &@io.Data) {
  @process.collect_output(
    "git",
    args,
    cwd=dir,
    extra_env=git_environment(),
    inherit_env=false,
  ) catch {
    error if @async.is_being_cancelled() => raise error
    error => raise HostError("failed to run Git: \{error}")
  }
}

///|
/// Resolve one revision to an immutable commit identity. A missing revision is
/// ordinary (an unborn HEAD or an object that disappeared); malformed command
/// output is a host failure rather than an ambiguous missing baseline.
async fn git_revision_commit(dir : String, revision : String) -> String? {
  let (code, stdout, _) = git_collect(dir, [
    "rev-parse",
    "--verify",
    "\{revision}^{commit}",
  ])
  if code != 0 {
    return None
  }
  let commit = git_single_line(
    stdout.text() catch {
      _ => raise HostError("Git returned a non-UTF-8 revision identity")
    },
  )
  if commit.is_empty() {
    None
  } else {
    Some(commit)
  }
}

///|
fn valid_commit_identity(revision : String) -> Bool {
  if revision.length() != 40 && revision.length() != 64 {
    return false
  }
  for character in revision {
    let code = character.to_int()
    let digit = code >= '0'.to_int() && code <= '9'.to_int()
    let lower = code >= 'a'.to_int() && code <= 'f'.to_int()
    let upper = code >= 'A'.to_int() && code <= 'F'.to_int()
    if !(digit || lower || upper) {
      return false
    }
  }
  true
}

///|
test "Git review revisions accept only full hexadecimal object identities" {
  assert_true(valid_commit_identity("0123456789abcdef0123456789abcdef01234567"))
  assert_true(
    valid_commit_identity(
      "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
    ),
  )
  assert_false(valid_commit_identity("HEAD"))
  assert_false(valid_commit_identity("--all"))
  assert_false(
    valid_commit_identity("0123456789abcdef0123456789abcdef0123456g"),
  )
}

///|
/// Read the index and porcelain status while HEAD remains the same. Git has no
/// single porcelain-v1 command that also reports the full commit identity, so
/// bracket the snapshot with two revision reads and retry a concurrent
/// commit/checkout. The returned rows and baseline identity therefore describe
/// the same HEAD instead of relying on the next frontend poll to self-heal.
async fn git_change_snapshot(
  dir : String,
  workspace_prefix : String,
  retries_left : Int,
) -> (String?, Set[String], Set[String], Array[GitChange]) {
  let head = git_revision_commit(dir, "HEAD")
  let (index_code, index_stdout, index_stderr) = git_collect(dir, [
    "ls-files", "--full-name", "--stage", "-z", "--", ".",
  ])
  guard index_code == 0 else {
    let detail = (index_stderr.text() catch { _ => "" }).trim().to_owned()
    raise HostError(
      if detail.is_empty() {
        "failed to inspect Git index"
      } else {
        detail
      },
    )
  }
  let index_metadata = index_stdout.text() catch {
    _ => raise HostError("Git returned a non-UTF-8 index path")
  }
  let known_gitlinks = parse_git_mode_paths(
    index_metadata, workspace_prefix, "160000",
  )
  let known_symlinks = parse_git_mode_paths(
    index_metadata, workspace_prefix, "120000",
  )
  let (code, stdout, stderr) = git_collect(dir, [
    "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", ".",
  ])
  guard code == 0 else {
    let detail = (stderr.text() catch { _ => "" }).trim().to_owned()
    raise HostError(
      if detail.is_empty() {
        "failed to read Git changes"
      } else {
        detail
      },
    )
  }
  let raw = stdout.text() catch {
    _ => raise HostError("Git returned a non-UTF-8 changed path")
  }
  let changes = parse_git_status_z(raw).filter_map(change => {
    git_change_relative_to_workspace(change, workspace_prefix)
  })
  // Staged deletions no longer exist in the index. Query only those changed
  // paths in the pinned HEAD tree instead of walking every tracked file on
  // each three-second review poll; the old mode keeps deleted gitlinks and
  // symlinks inert without repository-size-proportional work.
  let deleted_paths = deleted_change_paths(changes)
  if head is Some(commit) && !deleted_paths.is_empty() {
    let path_batches = git_tree_path_batches(deleted_paths)
    let full_tree = path_batches.is_empty()
    let batches = if full_tree { [["."]] } else { path_batches }
    for batch in batches {
      let tree_args = ["--literal-pathspecs", "ls-tree"]
      if full_tree {
        tree_args.push("-r")
      }
      tree_args.push("--full-name")
      tree_args.push("-z")
      tree_args.push(commit)
      tree_args.push("--")
      for path in batch {
        tree_args.push(path)
      }
      let (tree_code, tree_stdout, tree_stderr) = git_collect(dir, tree_args)
      guard tree_code == 0 else {
        let detail = (tree_stderr.text() catch { _ => "" }).trim().to_owned()
        raise HostError(
          if detail.is_empty() {
            "failed to inspect Git HEAD tree"
          } else {
            detail
          },
        )
      }
      let head_metadata = tree_stdout.text() catch {
        _ => raise HostError("Git returned a non-UTF-8 HEAD tree path")
      }
      let head_gitlinks = parse_git_mode_paths(
        head_metadata, workspace_prefix, "160000",
      )
      for path in head_gitlinks {
        known_gitlinks.add(path)
      }
      let head_symlinks = parse_git_mode_paths(
        head_metadata, workspace_prefix, "120000",
      )
      for path in head_symlinks {
        known_symlinks.add(path)
      }
    }
  }
  let confirmed_head = git_revision_commit(dir, "HEAD")
  if confirmed_head != head {
    if retries_left > 0 {
      return git_change_snapshot(dir, workspace_prefix, retries_left - 1)
    }
    raise HostError("HEAD kept changing while Git changes were read")
  }
  (head, known_gitlinks, known_symlinks, changes)
}

///|
async fn git_changes_op(payload : GitChangesPayload) -> GitChangesReply {
  guard @engine.resolve_in_workspace(
      payload.session,
      "",
      workspace?=payload.workspace,
    )
    is Some(root) else {
    raise HostError("could not resolve the conversation workspace")
  }
  let dir = root.to_string()
  if git_output(dir, ["rev-parse", "--is-inside-work-tree"]) != "true" {
    return { repository: false, head: None, changes: [] }
  }
  let (prefix_code, prefix_stdout, prefix_stderr) = git_collect(dir, [
    "rev-parse", "--show-prefix",
  ])
  guard prefix_code == 0 else {
    let detail = (prefix_stderr.text() catch { _ => "" }).trim().to_owned()
    raise HostError(
      if detail.is_empty() {
        "failed to resolve Git workspace prefix"
      } else {
        detail
      },
    )
  }
  let workspace_prefix = git_single_line(
    prefix_stdout.text() catch {
      _ => raise HostError("Git returned a non-UTF-8 workspace prefix")
    },
  )
  let (head, known_gitlinks, known_symlinks, changes) = git_change_snapshot(
    dir, workspace_prefix, 2,
  )
  let changes = @async.all(
    [
      for change in changes => {
        () => {
          // Deleted rows have no current kind. A trailing-slash untracked row
          // is Git's collapsed nested checkout/directory spelling, not a
          // symlink. Avoid filesystem work for both common inert cases.
          if change.kind == "deleted" {
            git_change_with_path_kind(
              change,
              Unknown,
              known_gitlinks.contains(change.path),
              known_symlinks.contains(change.path),
            )
          } else if change.kind == "untracked" && change.path.has_suffix("/") {
            change
          } else {
            let path = root.join((change.path : @pathx.Relative)).to_string()
            let path_kind = @fs.kind(path, follow_symlink=false) catch {
              error if @async.is_being_cancelled() => raise error
              _ => Unknown
            }
            git_change_with_path_kind(
              change,
              path_kind,
              known_gitlinks.contains(change.path),
              known_symlinks.contains(change.path),
            )
          }
        }
      }
    ],
    max_concurrent=32,
  )
  { repository: true, head, changes }
}

///|
async fn git_original_file_at(
  dir : String,
  relative : @pathx.Relative,
  revision : String,
) -> GitOriginalFileReply {
  // Resolve the requested revision to an immutable commit before addressing
  // its path. The caller has already validated the workspace and tree path.
  guard git_revision_commit(dir, revision) is Some(commit) else {
    return Missing
  }
  // `./` makes the tree path relative to Git's current directory, which is
  // the conversation workspace even when that workspace is a repository
  // subdirectory. Resolve the commit:path name once; all following checks and
  // the read use the immutable blob ID.
  let object = "\{commit}:./\{relative.0}"
  let (oid_code, oid_stdout, _) = git_collect(dir, [
    "rev-parse", "--verify", object,
  ])
  if oid_code != 0 {
    return Missing
  }
  let oid = git_single_line(oid_stdout.text() catch { _ => return Missing })
  if oid.is_empty() {
    return Missing
  }
  let (type_code, type_stdout, type_stderr) = git_collect(dir, [
    "cat-file", "-t", oid,
  ])
  guard type_code == 0 else {
    let detail = (type_stderr.text() catch { _ => "" }).trim().to_owned()
    raise HostError(
      if detail.is_empty() {
        "failed to inspect Git baseline"
      } else {
        detail
      },
    )
  }
  let object_type = git_single_line(type_stdout.text() catch { _ => "" })
  if object_type != "blob" {
    return BinaryOriginal
  }
  let (size_code, size_stdout, size_stderr) = git_collect(dir, [
    "cat-file", "-s", oid,
  ])
  guard size_code == 0 else {
    let detail = (size_stderr.text() catch { _ => "" }).trim().to_owned()
    raise HostError(
      if detail.is_empty() {
        "failed to size Git baseline"
      } else {
        detail
      },
    )
  }
  let size_text = git_single_line(size_stdout.text() catch { _ => "" })
  let size : Int64 = @string.parse_int64(size_text) catch {
    _ => raise HostError("Git returned an invalid blob size")
  }
  if size > MaxReadFileBytes.to_int64() {
    return OversizedOriginal
  }
  let (content_code, content, stderr) = git_collect(dir, ["cat-file", "-p", oid])
  guard content_code == 0 else {
    let detail = (stderr.text() catch { _ => "" }).trim().to_owned()
    raise HostError(
      if detail.is_empty() {
        "failed to read Git baseline"
      } else {
        detail
      },
    )
  }
  let raw = content.binary()
  if raw.find(b"\x00") is Some(_) {
    return BinaryOriginal
  }
  let text = content.text() catch { _ => return BinaryOriginal }
  OriginalContent(text)
}

///|
async fn git_original_file_op(
  payload : GitOriginalFilePayload,
) -> GitOriginalFileReply {
  guard @engine.resolve_in_workspace(
      payload.session,
      "",
      workspace?=payload.workspace,
    )
    is Some(root) &&
    git_tree_relative(payload.path) is Some(relative) else {
    raise HostError("path is outside the conversation workspace")
  }
  let dir = root.to_string()
  if git_output(dir, ["rev-parse", "--is-inside-work-tree"]) != "true" {
    return Missing
  }
  // New clients pass the exact HEAD identity returned with their change
  // snapshot; the fallback keeps older clients compatible.
  let revision = match payload.revision {
    Some(revision) => {
      guard valid_commit_identity(revision) else {
        raise HostError("invalid Git revision identity")
      }
      revision
    }
    None => "HEAD"
  }
  git_original_file_at(dir, relative, revision)
}

///|
test "Git porcelain parser keeps status columns and rename source" {
  let changes = parse_git_status_z(
    " M src/modified.mbt\u{0}A  src/added.mbt\u{0}R  src/new.mbt\u{0}src/old.mbt\u{0}?? src/untracked.mbt\u{0}",
  )
  assert_eq(changes, [
    {
      path: "src/added.mbt",
      original_path: None,
      index_status: "A",
      worktree_status: " ",
      kind: "added",
    },
    {
      path: "src/modified.mbt",
      original_path: None,
      index_status: " ",
      worktree_status: "M",
      kind: "modified",
    },
    {
      path: "src/new.mbt",
      original_path: Some("src/old.mbt"),
      index_status: "R",
      worktree_status: " ",
      kind: "renamed",
    },
    {
      path: "src/untracked.mbt",
      original_path: None,
      index_status: "?",
      worktree_status: "?",
      kind: "untracked",
    },
  ])
}

///|
test "Git change categories cover conflicts deletions and type changes" {
  assert_eq(git_change_kind("U", "U"), "unmerged")
  assert_eq(git_change_kind(" ", "D"), "deleted")
  assert_eq(git_change_kind("T", " "), "type-changed")
  assert_eq(git_change_kind("C", " "), "copied")
}

///|
test "Git subprocess environment cannot redirect the workspace repository" {
  let env : Map[String, String] = {
    "PATH": "/usr/bin",
    "Git_Dir": "/elsewhere/.git",
    "git_work_tree": "/elsewhere",
    "GIT_CONFIG_COUNT": "1",
    "GIT_CONFIG_GLOBAL": "/elsewhere/gitconfig",
    "GIT_QUARANTINE_PATH": "/elsewhere/quarantine",
    "HOME": "/home/test",
  }
  sanitize_git_environment(env)
  assert_eq(env.get("PATH"), Some("/usr/bin"))
  assert_eq(env.get("HOME"), Some("/home/test"))
  assert_false(env.contains("Git_Dir"))
  assert_false(env.contains("git_work_tree"))
  assert_false(env.contains("GIT_CONFIG_COUNT"))
  assert_false(env.contains("GIT_CONFIG_GLOBAL"))
  assert_false(env.contains("GIT_QUARANTINE_PATH"))
}

///|
test "Git tree paths are lexically contained without resolving symlinks" {
  assert_eq(git_tree_relative("src/link"), Some(Relative("src/link")))
  assert_eq(git_tree_relative("src/../link"), Some(Relative("link")))
  assert_true(git_tree_relative("../secret") is None)
  assert_true(git_tree_relative("src/../../secret") is None)
}

///|
test "Git single-line output preserves significant path whitespace" {
  assert_eq(git_single_line(" spaced/\n"), " spaced/")
  assert_eq(git_single_line("trailing /\r\n"), "trailing /")
  assert_eq(git_single_line("\n"), "")
}

///|
async fn git_test_run(dir : String, args : Array[String]) -> Unit {
  let (code, _, stderr) = git_collect(dir, args)
  guard code == 0 else {
    let detail = (stderr.text() catch { _ => "non-UTF-8 stderr" }).trim()
    fail("Git fixture command failed: \{detail}")
  }
}

///|
async test "Git snapshots pair status with HEAD and supplied revisions stay pinned" {
  let dir = @fs.tmpdir(prefix="openseek-git-review-")
  async fn cleanup() {
    @fs.rmdir(dir, recursive=true) catch {
      error if @async.is_being_cancelled() => raise error
      _ => ()
    }
  }
  try {
    git_test_run(dir, ["init", "--quiet"])
    assert_eq(git_revision_commit(dir, "HEAD"), None)
    @fs.mkdir("\{dir}/desktop", recursive=true)
    @fs.write_file("\{dir}/review.txt", "first\n", create_mode=CreateOrTruncate)
    @fs.write_file(
      "\{dir}/desktop/keep.txt",
      "keep\n",
      create_mode=CreateOrTruncate,
    )
    git_test_run(dir, ["add", "review.txt", "desktop/keep.txt"])
    git_test_run(dir, [
      "-c", "user.name=OpenSeek Test", "-c", "user.email=openseek@example.invalid",
      "commit", "--quiet", "-m", "first",
    ])
    let first = git_revision_commit(dir, "HEAD").unwrap()
    @fs.write_file(
      "\{dir}/review.txt",
      "working\n",
      create_mode=CreateOrTruncate,
    )
    let (snapshot_head, _, _, changes) = git_change_snapshot(dir, "", 2)
    assert_eq(snapshot_head, Some(first))
    assert_true(changes is [{ path: "review.txt", kind: "modified", .. }])
    git_test_run(dir, ["add", "review.txt"])
    git_test_run(dir, [
      "-c", "user.name=OpenSeek Test", "-c", "user.email=openseek@example.invalid",
      "commit", "--quiet", "-m", "second",
    ])
    let second = git_revision_commit(dir, "HEAD").unwrap()
    assert_true(second != first)
    assert_eq(git_revision_commit(dir, first), Some(first))
    assert_eq(git_revision_commit(dir, "missing-review-revision"), None)
    assert_eq(
      git_original_file_at(dir, Relative("review.txt"), first),
      OriginalContent("first\n"),
    )
    assert_eq(
      git_original_file_at(dir, Relative("review.txt"), second),
      OriginalContent("working\n"),
    )
    // Populate a gitlink directly so the test stays offline, add a symlink,
    // then stage both deletions from a workspace rooted below the repository.
    // Targeted HEAD discovery must retain the repository-root path spelling
    // emitted by --full-name and both non-text entry modes.
    git_test_run(dir, [
      "update-index",
      "--add",
      "--cacheinfo",
      "160000,\{second},desktop/vendor/lib",
    ])
    @fs.symlink(target="keep.txt", "\{dir}/desktop/link")
    git_test_run(dir, ["add", "desktop/link"])
    git_test_run(dir, [
      "-c", "user.name=OpenSeek Test", "-c", "user.email=openseek@example.invalid",
      "commit", "--quiet", "-m", "gitlink",
    ])
    let gitlink_head = git_revision_commit(dir, "HEAD").unwrap()
    @fs.remove("\{dir}/desktop/link")
    git_test_run(dir, [
      "update-index", "--force-remove", "desktop/link", "desktop/vendor/lib",
    ])
    let (nested_head, known_gitlinks, known_symlinks, nested_changes) = git_change_snapshot(
      "\{dir}/desktop",
      "desktop/",
      2,
    )
    assert_eq(nested_head, Some(gitlink_head))
    assert_eq(known_gitlinks.length(), 1)
    assert_true(known_gitlinks.contains("vendor/lib"))
    assert_eq(known_symlinks.length(), 1)
    assert_true(known_symlinks.contains("link"))
    assert_true(
      nested_changes
      is [
        { path: "link", index_status: "D", kind: "deleted", .. },
        { path: "vendor/lib", index_status: "D", kind: "deleted", .. },
      ],
    )
    let classified = nested_changes.map(change => {
      git_change_with_path_kind(
        change,
        Unknown,
        known_gitlinks.contains(change.path),
        known_symlinks.contains(change.path),
      )
    })
    assert_true(
      classified
      is [
        { path: "link", kind: "symlink", .. },
        { path: "vendor/lib", kind: "submodule", .. },
      ],
    )
  } catch {
    error => {
      cleanup()
      raise error
    }
  } noraise {
    _ => cleanup()
  }
}

///|
test "Git non-file changes are classified without following symlinks" {
  let change : GitChange = {
    path: "vendor/library",
    original_path: None,
    index_status: " ",
    worktree_status: "M",
    kind: "modified",
  }
  assert_eq(git_change_with_path_kind(change, Directory, false, false), {
    ..change,
    kind: "submodule",
  })
  assert_eq(git_change_with_path_kind(change, Unknown, true, false), {
    ..change,
    kind: "submodule",
  })
  let deleted = {
    ..change,
    index_status: "D",
    worktree_status: " ",
    kind: "deleted",
  }
  assert_eq(git_change_with_path_kind(deleted, Unknown, true, false), {
    ..deleted,
    kind: "submodule",
  })
  assert_eq(git_change_with_path_kind(deleted, Unknown, false, true), {
    ..deleted,
    kind: "symlink",
  })
  assert_eq(git_change_with_path_kind(change, Regular, false, false), change)
  assert_eq(git_change_with_path_kind(change, SymLink, false, false), {
    ..change,
    kind: "symlink",
  })
  assert_eq(
    git_change_with_path_kind(
      { ..change, index_status: "?", worktree_status: "?", kind: "untracked" },
      Directory,
      false,
      false,
    ),
    { ..change, index_status: "?", worktree_status: "?", kind: "untracked" },
  )
}

///|
test "duplicate deletion and recreation rows keep their own path kinds" {
  let deleted : GitChange = {
    path: "same",
    original_path: None,
    index_status: "D",
    worktree_status: " ",
    kind: "deleted",
  }
  let untracked : GitChange = {
    path: "same",
    original_path: None,
    index_status: "?",
    worktree_status: "?",
    kind: "untracked",
  }
  // Production classifies deletion rows with Unknown plus the pinned HEAD
  // modes, and classifies every untracked row from the working filesystem.
  // An old symlink recreated as a regular file therefore keeps both sides.
  assert_eq(git_change_with_path_kind(deleted, Unknown, false, true), {
    ..deleted,
    kind: "symlink",
  })
  assert_eq(
    git_change_with_path_kind(untracked, Regular, false, true),
    untracked,
  )
  // The inverse transition is likewise side-specific.
  assert_eq(git_change_with_path_kind(deleted, Unknown, false, false), deleted)
  assert_eq(git_change_with_path_kind(untracked, SymLink, false, false), {
    ..untracked,
    kind: "symlink",
  })
}

///|
test "Git full-name metadata finds entry modes in a nested workspace" {
  let output = "100644 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 0\tdesktop/src/main.mbt\u{0}120000 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 0\tdesktop/link\u{0}160000 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 0\tdesktop/vendor/lib\u{0}160000 cccccccccccccccccccccccccccccccccccccccc 2\tdesktop/vendor/lib\u{0}160000 commit dddddddddddddddddddddddddddddddddddddddd\tdesktop/vendor/tree\u{0}160000 eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee 0\toutside/lib\u{0}"
  let gitlinks = parse_git_mode_paths(output, "desktop/", "160000")
  assert_eq(gitlinks.length(), 2)
  assert_true(gitlinks.contains("vendor/lib"))
  assert_true(gitlinks.contains("vendor/tree"))
  let symlinks = parse_git_mode_paths(output, "desktop/", "120000")
  assert_eq(symlinks.length(), 1)
  assert_true(symlinks.contains("link"))
}

///|
test "Git HEAD path queries stay in bounded argument batches" {
  let first = "a".repeat(9_000)
  let second = "b".repeat(9_000)
  let batches = git_tree_path_batches([first, second, "short"])
  assert_eq(batches.length(), 2)
  for batch in batches {
    let mut bytes = 0
    for path in batch {
      bytes += @utf8.encode(path).length() + 1
    }
    assert_true(bytes <= MaxGitTreePathBatchBytes)
  }
  // One path that cannot fit the conservative cross-platform command-line
  // budget selects the recursive workspace-tree fallback.
  assert_true(
    git_tree_path_batches(["x".repeat(MaxGitTreePathBatchBytes + 1)]).is_empty(),
  )
  // The limit is a byte limit, not a Unicode scalar-value limit.
  assert_true(
    git_tree_path_batches(["界".repeat(MaxGitTreePathBatchBytes / 3 + 1)]).is_empty(),
  )
  // Enough individually valid batches to exceed the subprocess budget also
  // select one recursive tree walk.
  let many : Array[String] = []
  for index in 0..<(MaxTargetedGitTreeQueries + 1) {
    many.push(
      index.to_string() + "-" + "x".repeat(MaxGitTreePathBatchBytes / 2),
    )
  }
  assert_true(git_tree_path_batches(many).is_empty())
}

///|
test "bulk deleted-path collection deduplicates in first-seen order" {
  let deleted : GitChange = {
    path: "first.mbt",
    original_path: None,
    index_status: "D",
    worktree_status: " ",
    kind: "deleted",
  }
  assert_eq(
    deleted_change_paths([
      deleted,
      { ..deleted, path: "kept.mbt", kind: "modified" },
      { ..deleted, path: "second.mbt" },
      deleted,
    ]),
    ["first.mbt", "second.mbt"],
  )
}

///|
test "Git changes are relative to an attached repository subdirectory" {
  let renamed : GitChange = {
    path: "desktop/src/new.mbt",
    original_path: Some("desktop/src/old.mbt"),
    index_status: "R",
    worktree_status: " ",
    kind: "renamed",
  }
  assert_eq(
    git_change_relative_to_workspace(renamed, "desktop/"),
    Some({ ..renamed, path: "src/new.mbt", original_path: Some("src/old.mbt") }),
  )
  assert_eq(git_change_relative_to_workspace(renamed, ""), Some(renamed))
  assert_true(
    git_change_relative_to_workspace(
      { ..renamed, path: "outside/new.mbt" },
      "desktop/",
    )
    is None,
  )
  assert_eq(
    git_change_relative_to_workspace(
      { ..renamed, original_path: Some("outside/old.mbt") },
      "desktop/",
    ),
    Some({ ..renamed, path: "src/new.mbt", original_path: None }),
  )
}

///|
test "Git porcelain parser accepts clean, conflicted, and UTF-8 paths" {
  assert_eq(parse_git_status_z(""), [])
  assert_eq(
    parse_git_status_z(
      "UU src/with space.mbt\u{0} M src/你好.mbt\u{0}R  src/new name.mbt\u{0}src/old name.mbt\u{0}",
    ),
    [
      {
        path: "src/new name.mbt",
        original_path: Some("src/old name.mbt"),
        index_status: "R",
        worktree_status: " ",
        kind: "renamed",
      },
      {
        path: "src/with space.mbt",
        original_path: None,
        index_status: "U",
        worktree_status: "U",
        kind: "unmerged",
      },
      {
        path: "src/你好.mbt",
        original_path: None,
        index_status: " ",
        worktree_status: "M",
        kind: "modified",
      },
    ],
  )
}
