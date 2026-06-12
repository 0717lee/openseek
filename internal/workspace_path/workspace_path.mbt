///|
/// Resolve a tool path against the agent workspace root. Absolute paths are
/// already explicit, and the default root "." intentionally preserves the
/// pre-workspace behavior and output text.
pub fn resolve(workspace_root : String, path : String) -> String {
  if path == "" ||
    workspace_root == "" ||
    workspace_root == "." ||
    is_absolute_path(path) {
    path
  } else if use_native_path_join(workspace_root) {
    @path.Path(workspace_root).join(Path(path)).normalize().to_string()
  } else {
    normalize_slash_path("\{workspace_root}/\{path}")
  }
}

///|
fn is_absolute_path(path : String) -> Bool {
  @path.Path(path).is_absolute() ||
  path.has_prefix("/") ||
  path.has_prefix("\\") ||
  is_windows_drive_absolute(path)
}

///|
fn is_windows_drive_absolute(path : String) -> Bool {
  path.length() >= 3 && path[1] == ':' && (path[2] == '/' || path[2] == '\\')
}

///|
fn use_native_path_join(workspace_root : String) -> Bool {
  workspace_root.contains("\\") || is_windows_drive_absolute(workspace_root)
}

///|
fn normalize_slash_path(path : String) -> String {
  let absolute = path.has_prefix("/")
  let parts : Array[StringView] = []
  for part in path.split("/") {
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      match parts.last() {
        Some("..") => parts.push(part)
        Some(_) => ignore(parts.pop())
        None => if !absolute { parts.push(part) }
      }
    } else {
      parts.push(part)
    }
  }
  let body = parts.join("/")
  if absolute {
    if body == "" {
      "/"
    } else {
      "/\{body}"
    }
  } else if body == "" {
    "."
  } else {
    body
  }
}

///|
/// Resolve an optional cwd. A missing or empty cwd means the workspace root;
/// with the default root "." this remains the old current-directory behavior.
pub fn resolve_cwd(workspace_root : String, cwd : String?) -> String? {
  match cwd {
    Some(cwd) if cwd != "" => Some(resolve(workspace_root, cwd))
    _ if workspace_root == "" || workspace_root == "." => None
    _ => Some(workspace_root)
  }
}

///|
test "workspace path keeps default and absolute paths unchanged" {
  assert_eq(resolve(".", "src/main.mbt"), "src/main.mbt")
  assert_eq(resolve("/tmp/work", "/var/log/file"), "/var/log/file")
  assert_true(resolve_cwd(".", None) is None)
}

///|
test "workspace path resolves relative paths under a non-default root" {
  assert_eq(resolve("/tmp/work", "src/../README.md"), "/tmp/work/README.md")
  assert_true(resolve_cwd("/tmp/work", None) is Some("/tmp/work"))
  assert_true(
    resolve_cwd("/tmp/work", Some("subdir")) is Some("/tmp/work/subdir"),
  )
}
