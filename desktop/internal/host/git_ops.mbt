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
/// Extract gitlinks from `git ls-files --stage -z`. Index metadata keeps
/// submodules identifiable even when a sparse checkout has no directory to
/// inspect. Paths remain byte-exact after the first tab separator.
fn parse_gitlink_paths(
  output : String,
  workspace_prefix : String,
) -> Array[String] {
  let paths : Array[String] = []
  for record in output.split("\u{0}") {
    guard record.has_prefix("160000 ") && record.find("\t") is Some(tab) else {
      continue
    }
    let path = record.view(start_offset=tab + 1).to_owned()
    if git_path_relative_to_workspace(path, workspace_prefix) is Some(relative) &&
      !paths.contains(relative) {
      paths.push(relative)
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
  indexed_gitlink : Bool,
) -> GitChange {
  match path_kind {
    SymLink => { ..change, kind: "symlink" }
    Directory if change.kind != "untracked" => { ..change, kind: "submodule" }
    Unknown if indexed_gitlink => { ..change, kind: "submodule" }
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
    return { repository: false, changes: [] }
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
  let indexed_gitlinks = parse_gitlink_paths(
    index_stdout.text() catch {
      _ => raise HostError("Git returned a non-UTF-8 index path")
    },
    workspace_prefix,
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
  let changes = @async.all(
    [
      for change in changes => {
        () => {
          // Deleted rows have no current kind. A trailing-slash untracked row
          // is Git's collapsed nested checkout/directory spelling, not a
          // symlink. Avoid filesystem work for both common inert cases.
          if change.kind == "deleted" ||
            (change.kind == "untracked" && change.path.has_suffix("/")) {
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
              indexed_gitlinks.contains(change.path),
            )
          }
        }
      }
    ],
    max_concurrent=32,
  )
  { repository: true, changes }
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
  // `./` makes the tree path relative to Git's current directory, which is
  // the conversation workspace even when that workspace is a repository
  // subdirectory.
  let object = "HEAD:./\{relative.0}"
  // Resolve the symbolic `HEAD:path` name once. All following checks and the
  // read use the immutable object ID, so a concurrent checkout cannot swap in
  // different content after it passes the size limit.
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
test "Git non-file changes are classified without following symlinks" {
  let change : GitChange = {
    path: "vendor/library",
    original_path: None,
    index_status: " ",
    worktree_status: "M",
    kind: "modified",
  }
  assert_eq(git_change_with_path_kind(change, Directory, false), {
    ..change,
    kind: "submodule",
  })
  assert_eq(git_change_with_path_kind(change, Unknown, true), {
    ..change,
    kind: "submodule",
  })
  assert_eq(git_change_with_path_kind(change, Regular, false), change)
  assert_eq(git_change_with_path_kind(change, SymLink, false), {
    ..change,
    kind: "symlink",
  })
  assert_eq(
    git_change_with_path_kind(
      { ..change, index_status: "?", worktree_status: "?", kind: "untracked" },
      Directory,
      false,
    ),
    { ..change, index_status: "?", worktree_status: "?", kind: "untracked" },
  )
}

///|
test "Git index parser finds sparse gitlinks relative to a nested workspace" {
  let output = "100644 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 0\tdesktop/src/main.mbt\u{0}160000 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 0\tdesktop/vendor/lib\u{0}160000 cccccccccccccccccccccccccccccccccccccccc 2\tdesktop/vendor/lib\u{0}160000 dddddddddddddddddddddddddddddddddddddddd 0\toutside/lib\u{0}"
  assert_eq(parse_gitlink_paths(output, "desktop/"), ["vendor/lib"])
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
