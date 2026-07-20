///|
/// Absolute path to the macOS `sandbox-exec` binary.
pub const SandboxExecPath : String = "/usr/bin/sandbox-exec"

///|
let source_write_profile_cache : Map[String, CachedSourceWriteProfile] = Map([])

///|
let sandbox_exec_available_cache : Ref[Bool?] = { val: None }

///|
priv struct WatchedSourceProfileDir {
  path : String
  mtime_s : Int64
  mtime_ns : Int
}

///|
priv struct SourceWriteProfileScan {
  literal_paths : Array[String]
  watched_dirs : Array[WatchedSourceProfileDir]
  cacheable : Bool
}

///|
priv struct SourceWriteProfileScanBuilder {
  literal_paths : Array[String]
  watched_dirs : Array[WatchedSourceProfileDir]
  mut cacheable : Bool
}

///|
priv struct CachedSourceWriteProfile {
  profile : String
  watched_dirs : Array[WatchedSourceProfileDir]
  denial_subjects : Array[String]
}

///|
/// A built SBPL profile plus the source subjects it denies writes to.
pub(all) struct SourceWriteProfileData {
  profile : String
  denial_subjects : Array[String]
}

///|
/// Argument vector for running `cmd` through `sandbox-exec` under `profile`.
pub fn sandbox_exec_args(profile : String, cmd : String) -> Array[String] {
  ["-p", profile, PlatformShellProgram, ..platform_shell_args(cmd)]
}

///|
/// Whether `sandbox-exec` exists AND can actually apply and enforce a
/// profile here (cached). False inside a nested sandbox that forbids
/// re-sandboxing, so callers fall back to running unsandboxed.
pub async fn sandbox_exec_available() -> Bool {
  match sandbox_exec_available_cache.val {
    Some(value) => value
    None => {
      let value = probe_sandbox_exec_available()
      sandbox_exec_available_cache.val = Some(value)
      value
    }
  }
}

///|
async fn probe_sandbox_exec_available() -> Bool {
  if !@fs.exists(SandboxExecPath) {
    return false
  }
  let probe_dir = @fs.tmpdir(prefix="openseek-sandbox-probe-") catch {
    error if @async.is_being_cancelled() => raise error
    _ => return false
  }
  // sandbox-exec matches `file-write*` rules against the *realpath* of the
  // target. Temp dirs live under symlinked prefixes on macOS (`/tmp` ->
  // `/private/tmp`, `$TMPDIR` under `/private/var/...`), so a deny rule built
  // from the unresolved path never matches the resolved write. That made the
  // probe believe the sandbox was unenforced and disabled it process-wide.
  // Resolve the dir first, exactly like the real source-write profile does for
  // the workspace root.
  let probe_dir = @fs.realpath(probe_dir) catch {
    error if @async.is_being_cancelled() => raise error
    _ => probe_dir
  }
  let blocked_path = @path.Path(probe_dir)
    .join(Path("blocked"))
    .normalize()
    .to_string()
  let probe_profile = sandbox_denial_probe_profile(blocked_path)
  let noop_exit = run_probe_exit(
    SandboxExecPath,
    sandbox_exec_args(probe_profile, PlatformNoopCommand),
  )
  if noop_exit != Some(0) {
    cleanup_sandbox_probe(probe_dir, blocked_path)
    return false
  }
  let write_exit = run_probe_exit(
    SandboxExecPath,
    sandbox_exec_args(
      probe_profile,
      "printf probe > \{shell_quote(blocked_path)}",
    ),
  )
  let denied = write_exit != Some(0) && !@fs.exists(blocked_path)
  cleanup_sandbox_probe(probe_dir, blocked_path)
  denied
}

///|
/// Spawn `program args`, drain merged stdout+stderr so a child that fills the
/// pipe buffer cannot deadlock against `wait`, then wait and return the exit
/// code. Returns `None` when the spawn (or an unexpected IO error) fails; a
/// cancellation still propagates. The sandbox-availability probe only needs the
/// exit status plus a follow-up `@fs.exists` check, so the drained bytes are
/// discarded rather than decoded.
async fn run_probe_exit(program : String, args : Array[String]) -> Int? {
  (@async.with_task_group() <| group => {
    let (reader, writer) = @process.read_from_process()
    defer reader.close()
    let process = @process.spawn(
      group,
      program,
      args,
      stdout=writer,
      stderr=writer,
      cancel_handler=@process.hard_cancel(),
      no_wait=true,
    )
    for ;; {
      match reader.read_some(max_len=1024) {
        None => break
        Some(_) => ()
      }
    }
    Some(process.wait())
  }) catch {
    error if @async.is_being_cancelled() => raise error
    _ => None
  }
}

///|
#cfg(platform="windows")
const PlatformNoopCommand : String = "exit 0"

///|
#cfg(not(platform="windows"))
const PlatformNoopCommand : String = ":"

///|
fn sandbox_denial_probe_profile(blocked_path : String) -> String {
  (
    $|(version 1)
    $|(allow default)
    $|(deny file-write* (literal "\{sbpl_string_escape(blocked_path)}"))
  )
}

///|
fn shell_quote(text : String) -> String {
  "'\{text.replace_all(old="'", new="'\\''")}'"
}

///|
async fn cleanup_sandbox_probe(
  probe_dir : String,
  blocked_path : String,
) -> Unit {
  ignore(@fs.remove(blocked_path) catch { _ => () })
  ignore(@fs.rmdir(probe_dir) catch { _ => () })
}

///|
/// Build (and cache) an SBPL profile that denies writes to protected MoonBit
/// source files under `real_workspace_root` while allowing everything else
/// (reads and non-source writes). Also returns the denied subjects.
pub async fn source_write_readonly_profile_data(
  real_workspace_root : String,
) -> SourceWriteProfileData {
  let real_workspace_root = @workspace_path.strip_trailing_slash(
    @path.Path(real_workspace_root).normalize().to_string(),
  )
  match source_write_profile_cache.get(real_workspace_root) {
    Some(cached) if cached_source_write_profile_valid(cached) =>
      return {
        profile: cached.profile,
        denial_subjects: cached.denial_subjects,
      }
    Some(_) => ()
    None => ()
  }
  let scan = protected_source_tree_profile_scan(real_workspace_root)
  let denial_subjects = source_write_denial_subjects(scan.literal_paths)
  let source_regex = source_write_regex(real_workspace_root)
  let build_carveout_regex = source_write_build_carveout_regex(
    real_workspace_root,
  )
  let profile = StringBuilder()
  profile.write_string("(version 1)\n")
  profile.write_string("(allow default)\n")
  // `file-write*` already covers `file-write-create`, so this single deny blocks
  // both rewriting existing source and creating new source files. SBPL is
  // last-match-wins, so the following carve-out re-allows Moon-managed build and
  // cache trees without the deny regex having to special-case them.
  profile.write_string(
    "(deny file-write* (regex \"\{sbpl_string_escape(source_regex)}\"))\n",
  )
  profile.write_string(
    "(allow file-write* (regex \"\{sbpl_string_escape(build_carveout_regex)}\"))\n",
  )
  for dir in scan.literal_paths {
    profile.write_string(
      "(deny file-write* (literal \"\{sbpl_string_escape(dir)}\"))\n",
    )
  }
  let profile = profile.to_string()
  if scan.cacheable {
    source_write_profile_cache[real_workspace_root] = {
      profile,
      watched_dirs: scan.watched_dirs,
      denial_subjects,
    }
  }
  { profile, denial_subjects }
}

///|
fn source_write_denial_subjects(literal_paths : Array[String]) -> Array[String] {
  let subjects : Array[String] = []
  for path in literal_paths {
    subjects.push(path)
    let base = path_basename(path)
    if base != path {
      subjects.push(base)
    }
  }
  subjects
}

///|
async fn cached_source_write_profile_valid(
  cached : CachedSourceWriteProfile,
) -> Bool {
  for watched in cached.watched_dirs {
    let (mtime_s, mtime_ns) = @fs.mtime(watched.path, follow_symlink=false) catch {
      error if @async.is_being_cancelled() => raise error
      _ => return false
    }
    if mtime_s != watched.mtime_s || mtime_ns != watched.mtime_ns {
      return false
    }
  }
  true
}

///|
fn source_write_regex(real_workspace_root : String) -> String {
  let root = regex_escape(
    @workspace_path.strip_trailing_slash(real_workspace_root),
  )
  let source_file = "([^/]*(\\.mbt\\.md|\\.mbt|\\.mbti)|(moon\\.mod\\.json|moon\\.pkg\\.json|moon\\.mod|moon\\.pkg|moon\\.work))"
  "^\{root}(/|$)(.*/)?\{source_file}$"
}

///|
/// Paths under a Moon-managed `_build` or `.mooncakes` directory, where Moon
/// itself writes generated `.mbt` sources. Emitted as an `allow` rule after the
/// source deny so the sandbox blocks hand-written source rewrites while leaving
/// Moon's own build/cache writes untouched. Mirrors the component names in
/// `is_moon_managed_workspace_path`.
fn source_write_build_carveout_regex(real_workspace_root : String) -> String {
  let root = regex_escape(
    @workspace_path.strip_trailing_slash(real_workspace_root),
  )
  "^\{root}/(.*/)?(_build|\\.mooncakes)(/|$)"
}

///|
async fn protected_source_tree_profile_scan(
  real_workspace_root : String,
) -> SourceWriteProfileScan {
  let root = @workspace_path.strip_trailing_slash(
    @path.Path(real_workspace_root).normalize().to_string(),
  )
  let state : SourceWriteProfileScanBuilder = {
    literal_paths: [],
    watched_dirs: [],
    cacheable: true,
  }
  ignore(collect_protected_source_tree_profile_scan(root, root, state))
  {
    literal_paths: state.literal_paths,
    watched_dirs: state.watched_dirs,
    cacheable: state.cacheable,
  }
}

///|
async fn collect_protected_source_tree_profile_scan(
  root : String,
  dir : String,
  state : SourceWriteProfileScanBuilder,
) -> Bool {
  if dir != root && is_moon_managed_workspace_path(root, dir) {
    return false
  }
  if dir != root && should_prune_profile_scan_path(root, dir) {
    return false
  }
  let (mtime_s, mtime_ns) = @fs.mtime(dir, follow_symlink=false) catch {
    error if @async.is_being_cancelled() => raise error
    _ => {
      state.cacheable = false
      return false
    }
  }
  state.watched_dirs.push({ path: dir, mtime_s, mtime_ns })
  let entries = @fs.readdir(dir, include_hidden=true) catch {
    error if @async.is_being_cancelled() => raise error
    _ => {
      state.cacheable = false
      return false
    }
  }
  let mut contains_protected = false
  for entry in entries {
    let child = @path.Path(dir).join(Path(entry)).normalize().to_string()
    if is_moon_managed_workspace_path(root, child) {
      continue
    }
    if is_protected_workspace_source_path(root, child) {
      contains_protected = true
      continue
    }
    let kind = @fs.kind(child, follow_symlink=false) catch {
      error if @async.is_being_cancelled() => raise error
      _ => {
        state.cacheable = false
        continue
      }
    }
    match kind {
      Directory =>
        if collect_protected_source_tree_profile_scan(root, child, state) {
          contains_protected = true
        }
      _ => ()
    }
  }
  if contains_protected && dir != root {
    state.literal_paths.push(dir)
  }
  contains_protected
}

///|
fn should_prune_profile_scan_path(root : String, path : String) -> Bool {
  guard is_under_workspace_root(root, path) && path != root else {
    return false
  }
  let relative = path[root.length() + 1:].to_owned()
  relative
  .replace_all(old="\\", new="/")
  .split("/")
  .any(part => {
    part == ".git" ||
    part == ".hg" ||
    part == ".svn" ||
    part == ".jj" ||
    part == "node_modules"
  })
}

///|
/// The final path component (trailing slashes stripped, `\\` normalized to `/`).
pub fn path_basename(path : String) -> String {
  let normalized = @workspace_path.strip_trailing_slash(
    path.replace_all(old="\\", new="/"),
  )
  match normalized.rev_find("/") {
    Some(slash) => normalized[slash + 1:].to_owned()
    None => normalized
  }
}

///|
/// Whether `target` is a protected MoonBit source file inside the workspace
/// and not under a Moon-managed `_build`/`.mooncakes` tree.
pub fn is_protected_workspace_source_path(
  real_workspace_root : String,
  target : String,
) -> Bool {
  let root = @workspace_path.strip_trailing_slash(
    @path.Path(real_workspace_root).normalize().to_string(),
  )
  let target = @path.Path(target).normalize().to_string()
  is_under_workspace_root(root, target) &&
  !is_moon_managed_workspace_path(root, target) &&
  is_protected_source_path(target)
}

///|
/// Whether `path` is `root` itself or lies within it.
pub fn is_under_workspace_root(root : String, path : String) -> Bool {
  let root = workspace_compare_path(root)
  let path = workspace_compare_path(path)
  if path == root {
    true
  } else if root == "/" {
    path.has_prefix("/")
  } else {
    path.has_prefix("\{root}/")
  }
}

///|
/// Whether `path` sits under a `_build` or `.mooncakes` component of `root`.
pub fn is_moon_managed_workspace_path(root : String, path : String) -> Bool {
  let root = workspace_compare_path(root)
  let path = workspace_compare_path(path)
  if path == root {
    return false
  }
  if !is_under_workspace_root(root, path) {
    return false
  }
  let relative_start = if root == "/" { 1 } else { root.length() + 1 }
  let relative = path[relative_start:].to_owned()
  for part in relative.split("/") {
    if part == "_build" || part == ".mooncakes" {
      return true
    }
  }
  false
}

///|
fn workspace_compare_path(path : String) -> String {
  @workspace_path.strip_trailing_slash(path.replace_all(old="\\", new="/"))
}

///|
/// Whether `path` names a protected MoonBit source file or manifest by suffix.
pub fn is_protected_source_path(path : String) -> Bool {
  let path = path.replace_all(old="\\", new="/")
  path.has_suffix(".mbt.md") ||
  path.has_suffix(".mbt") ||
  path.has_suffix(".mbti") ||
  path == "moon.mod" ||
  path.has_suffix("/moon.mod") ||
  path == "moon.pkg" ||
  path.has_suffix("/moon.pkg") ||
  path == "moon.mod.json" ||
  path.has_suffix("/moon.mod.json") ||
  path == "moon.pkg.json" ||
  path.has_suffix("/moon.pkg.json") ||
  path == "moon.work" ||
  path.has_suffix("/moon.work")
}

///|
fn regex_escape(text : String) -> String {
  let escaped = StringBuilder()
  for ch in text {
    match ch {
      '\\'
      | '.'
      | '+'
      | '*'
      | '?'
      | '^'
      | '$'
      | '('
      | ')'
      | '['
      | ']'
      | '{'
      | '}'
      | '|'
      | '/' => {
        escaped.write_char('\\')
        escaped.write_char(ch)
      }
      _ => escaped.write_char(ch)
    }
  }
  escaped.to_string()
}

///|
/// Escape a string for use inside an SBPL `"..."` literal (e.g. a `subpath`
/// operand): backslashes, quotes, and control characters.
pub fn sbpl_string_escape(text : String) -> String {
  let escaped = StringBuilder()
  for ch in text {
    match ch {
      '"' | '\\' => {
        escaped.write_char('\\')
        escaped.write_char(ch)
      }
      '\n' => escaped.write_string("\\n")
      '\r' => escaped.write_string("\\r")
      '\t' => escaped.write_string("\\t")
      _ => escaped.write_char(ch)
    }
  }
  escaped.to_string()
}

///|
/// The platform shell program `sandbox_exec_args` runs commands through.
#cfg(platform="windows")
pub const PlatformShellProgram : String = "pwsh"

///|
/// The platform shell program `sandbox_exec_args` runs commands through.
#cfg(not(platform="windows"))
pub const PlatformShellProgram : String = "sh"

///|
/// Shell arguments to run `cmd` through `PlatformShellProgram`.
#cfg(platform="windows")
pub fn platform_shell_args(cmd : String) -> Array[String] {
  ["-NoProfile", "-Command", cmd]
}

///|
/// Shell arguments to run `cmd` through `PlatformShellProgram`.
#cfg(not(platform="windows"))
pub fn platform_shell_args(cmd : String) -> Array[String] {
  ["-c", cmd]
}
