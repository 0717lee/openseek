// One file location for Desktop language operations. The frontend supplies
// the exact editor root and a path relative to it; the host keeps both the
// lexical spelling used by Viewer resources and the physical spelling used
// when invoking MoonBit tooling through a symlinked root.

///|
priv struct LanguagePath {
  lexical_root : @pathx.Absolute
  physical_root : @pathx.Absolute
  physical_relative : @pathx.Relative
}

///|
/// Resolve the explicit editor root and relative file path to the physical
/// spellings passed to Moon. Relative components keep their ordinary meaning:
/// `..` and symlinks may address a file outside `root`.
async fn LanguagePath::resolve(root : String, path : String) -> LanguagePath {
  let lexical_root = WirePath::parse(root).absolute
  guard @pathx.Path(path).to_relative() is Some(relative) else {
    raise PayloadError("path must be relative to root")
  }
  let lexical_file = lexical_root.join(relative).normalize()
  let physical_root_text = @fs.realpath(lexical_root.to_string()) catch {
    error if @async.is_being_cancelled() => raise error
    _ => raise HostError("root is unavailable")
  }
  let physical_file_text = @fs.realpath(lexical_file.to_string()) catch {
    error if @async.is_being_cancelled() => raise error
    _ => raise HostError("path is unavailable")
  }
  guard @pathx.Path(physical_root_text).to_absolute() is Some(physical_root) &&
    @pathx.Path(physical_file_text).to_absolute() is Some(physical_file) else {
    raise HostError("root or path is not a host absolute path")
  }
  guard physical_file
    .to_path()
    .relative(base=physical_root.to_path())
    .to_relative()
    is Some(physical_relative) else {
    raise HostError("path cannot be addressed relative to root")
  }
  {
    lexical_root,
    physical_root,
    physical_relative: physical_relative.normalize(),
  }
}

///|
async test "language paths keep traversal and symlink targets relative to root" {
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
  assert_eq(resolved.physical_relative, Relative("src/main.mbt"))
  assert_eq(traversal.physical_relative, Relative("../outside/secret.mbt"))
  assert_eq(symlink.physical_relative, Relative("../outside/secret.mbt"))
}
