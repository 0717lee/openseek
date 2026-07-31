///|
/// A write-containment scope for confined file tools (worker subagents).
///
/// `deny_reason` decides whether a path may be the target of a write-class
/// operation (write, edit, remove): the lexically normalized request AND its
/// symlink-resolved location must both stay under the canonical root, and —
/// when the scope carries `allowed_paths` — both must fall under one of those
/// component-wise prefixes. Resolution realpaths the nearest EXISTING ancestor
/// so a symlinked directory cannot smuggle a write out of the root, and a
/// dangling symlink (final or ancestor) fails closed.
///
/// Callers gate once at path resolution for a good early error, and AGAIN
/// immediately before each write — including revert/rollback writes: the
/// recheck narrows the check-to-use window; on macOS the worker sandbox
/// profile backstops what remains (documented TOCTOU residual elsewhere).
/// Creating parent directories for an admitted target needs no separate gate:
/// ancestors of an allowed path are implied, and a symlinked ancestor is
/// already caught by the resolved-location check on the target itself.
pub struct WriteScope {
  /// Canonical (realpath'd) absolute root every write must stay under.
  root : String
  /// Component-wise relative prefixes; empty means root-only confinement.
  allowed : Array[Array[String]]
  /// Human-readable prefix list for deny messages.
  allowed_display : String
}

///|
/// Build a scope from a root directory and optional relative prefixes.
///
/// The root must exist (it is canonicalized with realpath so comparisons match
/// kernel-resolved paths). Prefixes are validated strictly — relative, no
/// `..`/`.`/empty components, no NUL, and not rooted at `.git` or
/// `.worktrees` — because they arrive from a model-facing schema.
pub async fn WriteScope::create(
  root~ : String,
  allowed_paths? : Array[String] = [],
) -> Result[WriteScope, String] {
  let canonical_root = @fs.realpath(root) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return Err("write scope root does not resolve: \{root}")
  }
  let allowed : Array[Array[String]] = []
  for prefix in allowed_paths {
    match validate_prefix(prefix) {
      Ok(parts) => allowed.push(parts)
      Err(reason) => return Err(reason)
    }
  }
  Ok({
    // Slash-normalized (Windows realpath returns backslashes) so relative
    // slicing in `prefix_admits` sees one separator convention.
    root: @workspace_path.strip_trailing_slash(
      canonical_root.replace_all(old="\\", new="/"),
    ),
    allowed,
    allowed_display: allowed_paths.map(p => p.to_string()).join(", "),
  })
}

///|
/// The canonical root every admitted write stays under.
pub fn WriteScope::root(self : WriteScope) -> String {
  self.root
}

///|
/// `None` when `path` may be written; otherwise the reason to report.
///
/// Two forms of the path are checked against the root and the allowed
/// prefixes: the fully RESOLVED location (every symlink followed — what the
/// kernel will actually write), and the REQUESTED form — the final name as
/// spelled, below its canonicalized parent chain. The dual check means both
/// the name the caller addressed and the bytes' destination must be in
/// scope: a link inside an allowed prefix pointing at an out-of-scope file
/// fails on the resolved side, and an out-of-scope name aliasing an
/// in-scope file fails on the requested side. Canonicalizing the parent
/// chain keeps unresolved root spellings (macOS `/tmp`) working. The
/// verdict depends on live filesystem state, so callers re-run it
/// immediately before the actual write.
pub async fn WriteScope::deny_reason(
  self : WriteScope,
  path : String,
) -> String? {
  let requested = self.absolutize(path)
  guard resolve_existing_prefix(requested) is Some(resolved) else {
    return Some(
      "path does not resolve to a real location under the writable root (dangling or unreadable symlink)",
    )
  }
  let requested_form = match @workspace_path.parent_dir(requested) {
    Some(parent) =>
      match resolve_existing_prefix(parent) {
        Some(real_parent) =>
          @workspace_path.join_child(
            real_parent,
            @workspace_path.path_basename(requested),
          )
        None =>
          return Some(
            "path does not resolve to a real location under the writable root (dangling or unreadable symlink)",
          )
      }
    None => resolved
  }
  guard @workspace_path.is_under_workspace_root(self.root, resolved) else {
    return Some(
      "path resolves outside the writable root \{self.root} (through a symlink or ..)",
    )
  }
  guard @workspace_path.is_under_workspace_root(self.root, requested_form) else {
    return Some("path is outside the writable root \{self.root}")
  }
  if self.allowed.is_empty() {
    return None
  }
  guard self.prefix_admits(requested_form) && self.prefix_admits(resolved) else {
    return Some("path is outside allowed_paths (\{self.allowed_display})")
  }
  None
}

///|
/// Join a relative path onto the canonical root and normalize lexically.
/// Absolute paths only normalize; `..` components collapse here, so the
/// under-root checks that follow see their real ancestry.
fn WriteScope::absolutize(self : WriteScope, path : String) -> String {
  let joined = if @path.Path(path).is_absolute() {
    path
  } else {
    "\{self.root}/\{path}"
  }
  @path.Path(joined).normalize().to_string()
}

///|
/// Whether the root-relative components of `path` sit under one of the
/// allowed prefixes, component-wise (`src` never admits `src2`; a path
/// ABOVE every prefix is not a writable target either).
fn WriteScope::prefix_admits(self : WriteScope, path : String) -> Bool {
  // Slash-normalize before slicing: the root is stored normalized, but a
  // resolved path can arrive backslash-separated on Windows.
  let path = path.replace_all(old="\\", new="/")
  let relative = if path == self.root {
    ""
  } else {
    path.view(start_offset=self.root.length() + 1).to_owned()
  }
  let parts = relative.split("/").map(p => p.to_owned()).collect()
  self.allowed.any(prefix => {
    if parts.length() < prefix.length() {
      return false
    }
    for index in 0..<prefix.length() {
      if parts[index] != prefix[index] {
        return false
      }
    }
    true
  })
}

///|
/// Resolve `path` against the filesystem: realpath the deepest existing
/// ancestor (lstat semantics — an existing final symlink resolves through
/// realpath of the full path) and re-append the not-yet-existing suffix.
/// `None` means resolution failed — a dangling symlink somewhere on the
/// path — and the caller must fail closed.
async fn resolve_existing_prefix(path : String) -> String? {
  let suffix : Array[String] = []
  let mut prefix = path
  while !path_exists_no_follow(prefix) {
    guard @workspace_path.parent_dir(prefix) is Some(parent) else { break }
    guard parent != prefix else { break }
    suffix.push(@workspace_path.path_basename(prefix))
    prefix = parent
  }
  guard path_exists_no_follow(prefix) else { return None }
  let real = @fs.realpath(if suffix.is_empty() { path } else { prefix }) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return None
  }
  let mut resolved = @workspace_path.strip_trailing_slash(real)
  suffix.rev_each(part => resolved = @workspace_path.join_child(resolved, part))
  Some(resolved)
}

///|
async fn path_exists_no_follow(path : String) -> Bool {
  let _ = @fs.kind(path, follow_symlink=false) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return false
  }
  true
}

///|
/// Validate one model-supplied prefix into components. Strict: relative,
/// slash-normalized, no empty/`.`/`..` components, no NUL, and not rooted at
/// git or worktree bookkeeping.
fn validate_prefix(prefix : String) -> Result[Array[String], String] {
  let normalized = @workspace_path.strip_trailing_slash(
    prefix.replace_all(old="\\", new="/"),
  )
  guard normalized != "" else {
    return Err("allowed_paths entries must be non-empty relative paths")
  }
  guard !normalized.contains("\u{0}") else {
    return Err("allowed_paths entry contains a NUL byte")
  }
  guard !@path.Path(normalized).is_absolute() && !normalized.has_prefix("/") else {
    return Err("allowed_paths entries must be relative, got: \{prefix}")
  }
  let parts : Array[String] = []
  for part in normalized.split("/") {
    let part = part.to_owned()
    guard part != "" && part != "." && part != ".." else {
      return Err(
        "allowed_paths entries must not contain empty, `.`, or `..` components: \{prefix}",
      )
    }
    parts.push(part)
  }
  guard parts[0] != ".git" && parts[0] != ".worktrees" else {
    return Err(
      "allowed_paths entries must not target git or worktree bookkeeping: \{prefix}",
    )
  }
  Ok(parts)
}
