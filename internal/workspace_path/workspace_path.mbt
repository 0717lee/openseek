///|
/// Whether `workspace_root` selects the default (pre-workspace) behavior: both
/// an empty root and "." mean "leave paths as-is".
fn is_default_root(workspace_root : String) -> Bool {
  workspace_root == "" || workspace_root == "."
}

///|
/// Remove trailing `/` separators without collapsing a filesystem root.
pub fn strip_trailing_slash(path : String) -> String {
  for view = path[:] {
    match view {
      [.. rest, '/'] if rest.length() > 0 => continue rest
      _ =>
        break if view.length() == path.length() {
          path
        } else {
          view.to_owned()
        }
    }
  }
}

///|
/// Return the lexical parent of a POSIX or Windows-style path.
pub fn parent_dir(path : String) -> String? {
  let normalized = strip_trailing_slash(path.replace_all(old="\\", new="/"))
  if normalized == "" ||
    normalized == "." ||
    normalized == "/" ||
    (normalized.length() == 2 && normalized[1] == ':') {
    return None
  }
  match normalized.rev_find("/") {
    Some(0) => Some("/")
    Some(cut) => Some(normalized[:cut].to_owned())
    None => Some(".")
  }
}

///|
/// Append one basename to a lexical directory path.
pub fn join_child(dir : String, base : String) -> String {
  if dir == "" || dir == "." {
    base
  } else if dir.has_suffix("/") {
    "\{dir}\{base}"
  } else {
    "\{dir}/\{base}"
  }
}

///|
/// Resolve a tool path against the agent workspace root. Absolute paths are
/// already explicit, and the default root "." intentionally preserves the
/// pre-workspace behavior and output text.
pub fn resolve(workspace_root : String, path : String) -> String {
  if path == "" ||
    is_default_root(workspace_root) ||
    @path.Path(path).is_absolute() {
    path
  } else {
    @path.Path(workspace_root).join(Path(path)).normalize().to_string()
  }
}

///|
/// Resolve an optional cwd. A missing or empty cwd means the workspace root;
/// with the default root "." this remains the old current-directory behavior.
pub fn resolve_cwd(workspace_root : String, cwd : String?) -> String? {
  match cwd {
    Some(cwd) if cwd != "" => Some(resolve(workspace_root, cwd))
    _ if is_default_root(workspace_root) => None
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

///|
test "lexical path helpers preserve roots and normalize separators" {
  assert_eq(strip_trailing_slash("/work///"), "/work")
  assert_eq(strip_trailing_slash("/"), "/")
  assert_true(parent_dir("/") is None)
  assert_true(parent_dir("C:") is None)
  assert_true(parent_dir("C:/") is None)
  assert_true(parent_dir("C:/work") is Some("C:"))
  assert_true(parent_dir("C:\\work\\lib\\") is Some("C:/work"))
  assert_eq(join_child(".", "moon.mod"), "moon.mod")
  assert_eq(join_child("/work/", "moon.mod"), "/work/moon.mod")
}
