// Cross-platform path-string comparison. `@path.Path` renders with the
// host separator (backslashes on Windows) while URIs, manifests, and the
// frontend speak forward slashes, so any prefix test between the two worlds
// must normalize first. These path types own that dance; callers never
// hand-roll `replace_all` + `has_prefix` again.

///|
/// A path spelling that has not been classified as absolute or relative.
/// Every string is representable: validation belongs to conversions such as
/// `Path::to_absolute`, not to this transport type.
pub(all) struct Path(String) derive(Debug, Eq)

///|
/// Render the original path spelling at operating-system boundaries.
pub impl Show for Path with fn output(self, logger) {
  logger.write_string(self.0)
}

///|
/// Join two unclassified paths using the current host's path rules.
pub fn Path::join(self : Path, child : Path) -> Path {
  Path(@path.Path(self.0).join(Path(child.0)).to_string())
}

///|
/// Resolve this spelling against the current working directory using the
/// current host's path rules.
pub fn Path::resolve(self : Path) -> Path {
  Path(@path.Path(self.0).resolve().to_string())
}

///|
/// Resolve dot segments and redundant separators using the current host's
/// path rules. This is deliberately separate from `normalize`, whose
/// cross-platform contract only canonicalizes slash direction.
pub fn Path::clean(self : Path) -> Path {
  Path(@path.Path(self.0).normalize().to_string())
}

///|
/// The current host's directory portion of this path.
pub fn Path::dirname(self : Path) -> Path {
  Path(@path.Path(self.0).dirname().to_string())
}

///|
/// The final component according to the current host's path rules.
pub fn Path::basename(self : Path) -> StringView {
  @path.Path(self.0).basename()
}

///|
/// The final component's extension according to the current host's path
/// rules.
pub fn Path::extname(self : Path) -> StringView {
  @path.Path(self.0).extname()
}

///|
/// Whether the spelling is absolute according to the current host. Prefer
/// `to_absolute` when a protocol path may use another platform's syntax.
pub fn Path::is_host_absolute(self : Path) -> Bool {
  @path.Path(self.0).is_absolute()
}

///|
/// The current-host relative path from `base` to this path.
pub fn Path::relative(self : Path, base~ : Path) -> Path {
  Path(@path.Path(self.0).relative(base=Path(base.0)).to_string())
}

///|
/// A lexically complete absolute filesystem path. Other packages may inspect
/// and pattern-match the original spelling, but only this package can construct
/// one after validating a `Path`.
pub struct Absolute(String) derive(Debug, Eq, Hash)

///|
/// Render the validated absolute spelling at operating-system boundaries.
pub impl Show for Absolute with fn output(self, logger) {
  logger.write_string(self.0)
}

///|
/// Forget the absolute classification while retaining the spelling.
pub fn Absolute::to_path(self : Absolute) -> Path {
  Path(self.0)
}

///|
/// Convert a path after checking its lexical form. POSIX paths
/// must begin with `/`; Windows paths must be drive-rooted (`C:/` or `C:\\`)
/// or begin with a UNC/device prefix (`\\\\`). Drive-relative (`C:foo`) and
/// current-drive-rooted (`\\foo`) paths are rejected because they still need
/// process context to identify one absolute location.
pub fn Path::to_absolute(self : Path) -> Absolute? {
  if self.accepts_absolute() {
    Some(Absolute(self.0))
  } else {
    None
  }
}

///|
/// The same unclassified spelling with every backslash turned into a forward
/// slash. Purely lexical: no resolution or separator deduplication occurs.
pub fn Path::normalize(self : Path) -> Path {
  Path(self.0.replace_all(old="\\", new="/"))
}

///|
/// Whether this spelling has a complete POSIX or Windows absolute-path prefix.
fn Path::accepts_absolute(self : Path) -> Bool {
  match self.0[:] {
    ['/', ..] => true
    ['\\', '\\', ..] => true
    [drive, ':', '/', ..] => drive.is_ascii_alphabetic()
    [drive, ':', '\\', ..] => drive.is_ascii_alphabetic()
    _ => false
  }
}

///|
/// A workspace-relative path with forward-slash separators — the form
/// conversations, mention chips, and the file panel name files by. `Relative`
/// asserts provenance rather than validating it: construct it where the path
/// is known relative (a host reply, a tree join), or through
/// `Absolute::relative_to`, the one blessed absolute→relative conversion.
pub(all) struct Relative(String) derive(Debug, Eq, Hash)

///|
/// Render the relative spelling at serialization boundaries.
pub impl Show for Relative with fn output(self, logger) {
  logger.write_string(self.0)
}

///|
/// Forget the relative classification while retaining the spelling.
pub fn Relative::to_path(self : Relative) -> Path {
  Path(self.0)
}

///|
/// The zero-segment relative path: the workspace root itself. Not a sentinel
/// — `""` is the value `relative_to` yields for the root and the parent
/// `child_path`-style joins build from, so it is the root's canonical name.
pub fn Relative::root() -> Relative {
  Relative("")
}

///|
/// Whether this is the workspace root (the zero-segment path).
pub fn Relative::is_root(self : Relative) -> Bool {
  self.0.is_empty()
}

///|
/// The same relative path with forward-slash separators. Purely lexical: no
/// resolution or separator deduplication occurs.
pub fn Relative::normalize(self : Relative) -> Relative {
  Relative(Path(self.0).normalize().0)
}

///|
/// Whether `path` is this relative path or one of its descendants, comparing
/// with normalized separators. Purely lexical — `..` segments are not resolved.
pub fn Relative::contains(self : Relative, path : Relative) -> Bool {
  Path(self.0).contains(Path(path.0))
}

///|
/// The same absolute path with forward-slash separators. Purely lexical: no
/// resolution or separator deduplication occurs.
pub fn Absolute::normalize(self : Absolute) -> Absolute {
  Absolute(Path(self.0).normalize().0)
}

///|
/// Whether `path` is this absolute path or one of its descendants, comparing
/// with normalized separators. Purely lexical — `..` segments are not resolved.
pub fn Absolute::contains(self : Absolute, path : Absolute) -> Bool {
  Path(self.0).contains(Path(path.0))
}

///|
/// This path relative to the absolute directory `root`: `Some(Relative(""))`
/// when they are the same directory, `Some(Relative("a/b"))` for a
/// descendant, `None` for anything outside. Purely lexical — `..` segments
/// are not resolved. The `None` forces callers to decide what a path outside
/// the workspace means instead of letting an absolute string flow on as if
/// it were relative.
pub fn Absolute::relative_to(self : Absolute, root~ : Absolute) -> Relative? {
  let path = self.normalize().0
  let root = root.normalize().0
  if path == root {
    return Some(Relative(""))
  }
  let prefix = if root.has_suffix("/") { root } else { "\{root}/" }
  if path.strip_prefix(prefix) is Some(rest) {
    Some(Relative(rest.to_owned()))
  } else {
    None
  }
}

///|
/// The unclassified implementation shared by the public absolute and relative
/// containment methods. Keeping it private prevents callers from comparing
/// paths whose classifications do not agree.
fn Path::contains(self : Path, path : Path) -> Bool {
  let path = path.normalize().0
  let root = self.normalize().0
  if path == root {
    return true
  }
  let prefix = if root.has_suffix("/") { root } else { "\{root}/" }
  path.strip_prefix(prefix) is Some(_)
}
