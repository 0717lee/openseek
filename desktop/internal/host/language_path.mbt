// One file location for Desktop language operations. The frontend supplies
// the exact editor root and a path relative to it. The host canonicalizes the
// root used as Moon's cwd, but preserves the file spelling recorded in Moon's
// package index — including symlinks below that root.

///|
priv struct LanguagePath {
  lexical_root : @pathx.Absolute
  physical_root : @pathx.Absolute
  relative_path : @pathx.Relative
}

///|
/// Canonicalize the explicit editor root without following the file itself.
/// Moon indexes a symlink below the root by its workspace spelling; replacing
/// that spelling with the target's real path makes Moon look for another
/// package index and breaks navigation for an otherwise valid source file.
async fn LanguagePath::resolve(root : String, path : String) -> LanguagePath {
  let lexical_root = WirePath::parse(root).absolute
  guard @pathx.Path(path).to_relative() is Some(relative) else {
    raise PayloadError("path must be relative to root")
  }
  let physical_root_text = @fs.realpath(lexical_root.to_string()) catch {
    error if @async.is_being_cancelled() => raise error
    _ => raise HostError("root is unavailable")
  }
  guard @pathx.Path(physical_root_text).to_absolute() is Some(physical_root) else {
    raise HostError("root is not a host absolute path")
  }
  { lexical_root, physical_root, relative_path: relative.normalize() }
}

///|
async test "language paths preserve symlink spelling below a canonical root" {
  let fixture = @fs.tmpdir(prefix="openseek-language-path-")
  let root = "\{fixture}/root"
  let outside = "\{fixture}/outside"
  defer (@fs.rmdir(fixture, recursive=true) catch { _ => () })
  @fs.mkdir("\{root}/src", recursive=true)
  @fs.mkdir(outside, recursive=true)
  @fs.write_file(
    "\{root}/src/main.mbt",
    "fn main {}",
    create_mode=CreateOrTruncate,
  )
  @fs.write_file(
    "\{outside}/secret.mbt",
    "fn secret {}",
    create_mode=CreateOrTruncate,
  )
  @fs.symlink(target="\{outside}/secret.mbt", "\{root}/src/link.mbt")
  let resolved = LanguagePath::resolve(root, "src/main.mbt")
  let traversal = LanguagePath::resolve(root, "../outside/secret.mbt")
  let symlink = LanguagePath::resolve(root, "src/link.mbt")
  assert_eq(resolved.relative_path, Relative("src/main.mbt"))
  assert_eq(traversal.relative_path, Relative("../outside/secret.mbt"))
  assert_eq(symlink.relative_path, Relative("src/link.mbt"))
}
