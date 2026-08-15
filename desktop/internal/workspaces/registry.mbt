// The workspace registry: project directories the user attached to the
// desktop. A workspace conversation runs in the project itself and keeps its
// durable sessions inside it (`<workspace>/.openseek` — the engine CLI's own
// relative default), so the desktop and a TUI launched in that directory
// resume each other's conversations. The registry only remembers which
// directories the user attached; the session files themselves say which
// workspace owns which conversation.

///|
/// Debug is what the host boundary logs: proton renders a failed handler's
/// error through `Repr`, which prints only an opaque `<...: ...>` placeholder
/// for types without it — swallowing the one string that says what failed.
pub(all) suberror WorkspaceError {
  WorkspaceError(String)
} derive(Debug)

///|
impl Show for WorkspaceError with fn output(self, logger) {
  match self {
    WorkspaceError(message) => logger.write_string(message)
  }
}

///|
const WorkspacesFile = "workspaces.json"

///|
/// Registry reads and read-modify-write mutations share one process-wide
/// lock. Remote requests run in independent tasks; without this serialization
/// two concurrent add/remove operations can both read the same old list and
/// let the later write silently erase the earlier one.
let workspace_registry_lock : @async.Mutex = Mutex()

///|
/// The registry file: `<global session root>/workspaces.json`, beside the
/// scratch conversations' session store.
fn workspaces_file() -> @pathx.Absolute? {
  global_store_root().map(root => root.join(WorkspacesFile))
}

///|
/// The canonical (symlink-resolved) spelling of a workspace directory — the
/// registry's one identity per project, so `/tmp/x` and `/private/tmp/x`
/// cannot register as two workspaces holding separate watcher, diagnostics,
/// and session state, and every path the registry hands out matches the
/// canonical paths tools like moonc report. Falls back to the lexical
/// spelling when resolution fails (the directory vanished), keeping a dead
/// entry addressable for removal.
async fn canonical_path(dir : @pathx.Absolute) -> @pathx.Absolute {
  let resolved = @fs.realpath(dir.0) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return dir
  }
  @pathx.Path(resolved).to_absolute().unwrap_or(dir)
}

///|
/// The registered workspace directories, in registration order. A missing or
/// malformed registry reads as "no workspaces". Entries canonicalize on
/// read, so a registry written before symlink resolution (or edited by hand)
/// collapses aliases of one physical directory into its first spelling.
async fn read_registry_unlocked() -> Array[@pathx.Absolute] {
  guard workspaces_file() is Some(file) else { return [] }
  let text = @fsx.try_read_text(file.to_path()) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return []
  }
  guard text is Some(text) else { return [] }
  let json = @json.parse(text) catch { _ => return [] }
  guard json is Object(fields) && fields.get("workspaces") is Some(Array(items)) else {
    return []
  }
  let paths : Array[@pathx.Absolute] = []
  for item in items {
    guard item is String(path) && !path.is_empty() else { continue }
    // Registry JSON is an input boundary. Ignore an edited relative or
    // incomplete spelling rather than letting it enter host state.
    guard @pathx.Path(path).to_absolute() is Some(path) else { continue }
    let canonical = canonical_path(path)
    if !paths.contains(canonical) {
      paths.push(canonical)
    }
  }
  paths
}

///|
pub async fn registered() -> Array[@pathx.Absolute] {
  workspace_registry_lock.acquire()
  defer workspace_registry_lock.release()
  read_registry_unlocked()
}

///|
async fn write_registry(paths : Array[@pathx.Absolute]) -> Unit {
  guard global_store_root() is Some(root) else {
    raise WorkspaceError(
      "cannot determine a session root; set OPENSEEK_SESSION_ROOT",
    )
  }
  @fsx.ensure_dir(root.to_path()) catch {
    error if @async.is_being_cancelled() => raise error
    error => raise WorkspaceError("could not create \{root}: \{error}")
  }
  let registry : Json = { "workspaces": paths.map(path => path.0).to_json() }
  @fsx.write_text(
    root.join(WorkspacesFile).to_path(),
    registry.stringify(indent=2),
  ) catch {
    error if @async.is_being_cancelled() => raise error
    error => raise WorkspaceError("could not save the workspace list: \{error}")
  }
}

///|
/// Register `path` as a workspace and return the updated list. The path must
/// name an existing directory; `~` expands to the home directory. Registering
/// an already-registered directory is a no-op. A git repository gets the
/// in-project session store added to `.git/info/exclude`, so attaching a
/// project never dirties its status.
pub async fn add(
  path : String,
  on_committed : (Array[@pathx.Absolute]) -> Unit raise,
) -> Array[@pathx.Absolute] {
  // A real directory pick never contains control characters. A NUL-padded
  // dialog buffer once slipped through the is_dir check below — C-level
  // filesystem calls truncate at the first NUL while the MoonBit string
  // keeps the rest — and poisoned the registry, so refuse them outright.
  guard !path.iter().any(ch => ch.is_control()) else {
    raise WorkspaceError("workspace path contains control characters")
  }
  let dir = expanded_path(path)
  guard @fsx.is_dir(dir.to_path()) else {
    raise WorkspaceError("\{dir.0} is not a directory")
  }
  // A worktree is not a workspace: registering a linked checkout would root
  // stores and language ops at a directory that can vanish with the
  // worktree. Non-git directories and repository subdirectories stay
  // attachable.
  if @gitx.is_linked_worktree(dir) {
    raise WorkspaceError(
      "\{dir.0} is a linked git worktree; attach the main checkout instead",
    )
  }
  let canonical = canonical_path(dir)
  // Best-effort ancillary work is deliberately before the durable commit:
  // cancellation here changes no registry state and needs no invalidation.
  exclude_from_git(dir, ".openseek")
  workspace_registry_lock.acquire()
  defer workspace_registry_lock.release()
  let paths = read_registry_unlocked()
  // The write and broadcast callback are one finite, cancellation-shielded
  // linearization point while the lock is held. Once disk changes, every
  // client is therefore notified in that same total order even if the
  // requester disconnects before its RPC response.
  @async.protect_from_cancel(() => {
    if !paths.contains(canonical) {
      paths.push(canonical)
      write_registry(paths)
    }
    on_committed(paths)
  })
  paths
}

///|
/// Drop `path` from the registry and return the updated list. Only the
/// registry entry goes away — the directory and any sessions inside it are
/// untouched, so re-adding the workspace brings its conversations back.
pub async fn remove(
  path : String,
  on_committed : (Array[@pathx.Absolute]) -> Unit raise,
) -> Array[@pathx.Absolute] {
  let target = canonical_path(expanded_path(path))
  workspace_registry_lock.acquire()
  defer workspace_registry_lock.release()
  let paths = read_registry_unlocked().filter(p => p != target)
  @async.protect_from_cancel(() => {
    write_registry(paths)
    on_committed(paths)
  })
  paths
}

///|
/// Expand and absolutize a user-supplied workspace path: `~` becomes the home
/// directory, a relative path resolves against the process cwd.
pub fn expanded_path(path : String) -> @pathx.Absolute raise WorkspaceError {
  let trimmed = path.trim().to_owned()
  guard !trimmed.is_empty() else {
    raise WorkspaceError("workspace path must not be empty")
  }
  let expanded : @pathx.Path = if trimmed == "~" {
    guard @home.dir() is Some(home) else {
      raise WorkspaceError("no home directory to expand ~ against")
    }
    home
  } else if trimmed is ['~', '/', .. rest] {
    guard @home.dir() is Some(home) else {
      raise WorkspaceError("no home directory to expand ~ against")
    }
    home.join(rest.to_owned())
  } else {
    Path(trimmed)
  }
  // `resolve` establishes the absolute-path guarantee; normalization keeps
  // that classification while cleaning the final workspace spelling.
  expanded.resolve().normalize()
}

///|
/// A client-supplied workspace path, accepted only when it is registered:
/// op payloads may name a workspace, but the registry — host state — decides
/// which directories the webview may reach. The hint canonicalizes before
/// the comparison, so a client still holding an attach-time symlink spelling
/// keeps matching the registry's physical one.
pub async fn registered_dir(path : @pathx.Absolute) -> @pathx.Absolute? {
  let canonical = canonical_path(path)
  if registered().contains(canonical) {
    Some(canonical)
  } else {
    None
  }
}

///|
/// A workspace's durable session store: the engine CLI's relative default
/// (`.openseek`) inside the project.
pub fn store_root(workspace : @pathx.Absolute) -> @pathx.Absolute {
  workspace.join(".openseek").normalize()
}

///|
/// Keep a desktop-owned directory (`.openseek`, `.worktrees`) out of
/// `git status`: append `<entry>/` to `.git/info/exclude` (repo-local,
/// unlike the user's own `.gitignore`). Only a directory `.git` qualifies —
/// a worktree or submodule keeps its real git dir elsewhere and is left
/// alone. Best-effort: a failure never blocks the caller.
pub async fn exclude_from_git(dir : @pathx.Absolute, entry : String) -> Unit {
  let git_dir = dir.join(".git")
  let is_repo = @fsx.is_dir(git_dir.to_path()) catch {
    error if @async.is_being_cancelled() => raise error
    _ => false
  }
  guard is_repo else { return }
  let exclude = git_dir.join("info").join("exclude")
  let existing = (@fsx.try_read_text(exclude.to_path()) catch {
    error if @async.is_being_cancelled() => raise error
    _ => None
  }).unwrap_or("")
  for line in existing.split("\n") {
    let line = line.trim().to_owned()
    if line == entry || line == "\{entry}/" {
      return
    }
  }
  let updated = if existing.is_empty() || existing.has_suffix("\n") {
    "\{existing}\{entry}/\n"
  } else {
    "\{existing}\n\{entry}/\n"
  }
  @fsx.ensure_dir(git_dir.join("info").to_path()) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return
  }
  @fsx.write_text(exclude.to_path(), updated) catch {
    error if @async.is_being_cancelled() => raise error
    _ => ()
  }
}

// Tests for the workspace registry's pure pieces: user-path expansion and
// the in-project session-store layout. The registry file itself and the
// session→workspace probe depend on the filesystem and are covered by the
// live app.

///|
test "a workspace's session store is the engine's in-project default" {
  assert_eq(
    store_root(@pathx.Path("/home/u/proj").resolve()).to_string(),
    "/home/u/proj/.openseek",
  )
}

///|
test "workspace paths expand ~ against the home directory" {
  guard @home.dir() is Some(home) else {
    // No home in this environment; nothing to expand against.
    return
  }
  assert_eq(expanded_path("~").0, home.to_string())
  assert_eq(
    expanded_path("~/proj").0,
    home.join("proj").normalize().to_string(),
  )
  // Absolute paths pass through (normalized), and surrounding blanks drop.
  assert_eq(expanded_path("  /srv/code//app  ").0, "/srv/code/app")
}

///|
test "blank workspace paths are refused" {
  let _ = expanded_path("   ") catch {
    WorkspaceError(message) => {
      assert_true(message.contains("must not be empty"))
      return
    }
  }
  fail("a blank workspace path was accepted")
}

///|
/// Both spellings of one physical directory canonicalize to the same
/// identity, and a vanished directory keeps its lexical spelling so a dead
/// registry entry stays removable.
async test "workspace identity follows symlinks and survives deletion" {
  let dir = @fs.tmpdir(prefix="openseek-workspace-canon-")
  let real = @pathx.Path(dir).join("real")
  @fs.mkdir(real.to_string())
  let link = @pathx.Path(dir).join("link")
  @fs.symlink(link.to_string(), target=real.to_string())
  let missing = @pathx.Path(dir).join("missing")
  guard real.to_absolute() is Some(real_path) &&
    link.to_absolute() is Some(link_path) &&
    missing.to_absolute() is Some(missing_path) else {
    fail("expected absolute temporary workspace paths")
  }
  let canonical = canonical_path(real_path)
  let linked = canonical_path(link_path)
  let vanished = canonical_path(missing_path)
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
  assert_eq(linked, canonical)
  assert_eq(vanished.0, missing.to_string())
}
