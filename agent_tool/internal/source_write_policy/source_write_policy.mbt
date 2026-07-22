///|
/// Return whether `target` is lexically inside `lab`, including the lab itself.
///
/// Both paths are normalized before comparison. An empty lab and the
/// filesystem root `/` are rejected so this predicate cannot accidentally
/// authorize every path. No filesystem or symlink resolution is performed.
pub fn path_is_under_lab(target : String, lab : String) -> Bool {
  let lab = @workspace_path.strip_trailing_slash(
    @path.Path(lab).normalize().to_string(),
  )
  guard !lab.is_empty() && lab != "/" else { return false }
  let target = @workspace_path.strip_trailing_slash(
    @path.Path(target).normalize().to_string(),
  )
  target == lab || target.has_prefix("\{lab}/")
}

///|
/// Return whether `target` is a protected MoonBit source path inside the
/// workspace.
///
/// The root and target are lexically normalized, containment is inclusive,
/// protected names are recognized by `is_protected_source_path`, and paths
/// below `_build` or `.mooncakes` are excluded. The root should already be a
/// canonical path when this predicate is used to mirror SBPL behavior.
pub fn is_protected_workspace_source_path(
  real_workspace_root : String,
  target : String,
) -> Bool {
  let root = @workspace_path.strip_trailing_slash(
    @path.Path(real_workspace_root).normalize().to_string(),
  )
  let target = @path.Path(target).normalize().to_string()
  @workspace_path.is_under_workspace_root(root, target) &&
  !is_moon_managed_workspace_path(root, target) &&
  is_protected_source_path(target)
}

///|
/// Return whether `path` is below an `_build` or `.mooncakes` directory within
/// `root`.
///
/// The root itself is never considered Moon-managed. Comparison is
/// case-sensitive and lexical; separators and trailing slashes are normalized,
/// but callers must normalize `.` and `..` components first.
pub fn is_moon_managed_workspace_path(root : String, path : String) -> Bool {
  let root = workspace_compare_path(root)
  let path = workspace_compare_path(path)
  if path == root {
    return false
  }
  if !@workspace_path.is_under_workspace_root(root, path) {
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
/// Return whether `path` has a protected MoonBit source or manifest name.
///
/// Protected names are `*.mbt`, `*.mbti`, `*.mbt.md`, `moon.mod`, `moon.pkg`,
/// `moon.work`, and the legacy JSON manifests. Matching is case-sensitive,
/// purely lexical, and accepts either a basename or a full path.
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
