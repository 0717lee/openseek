///|
/// A compact, sorted, directory-only outline of `root`: one entry per line, two
/// spaces of indent per nesting level (e.g. `lib/` then `  internal/`). Hidden
/// dirs (covers `.git`, `.mooncakes`, `.openseek`, `.github`, …), build output
/// (`_build`, `target`), and vendored deps (`node_modules`) are omitted.
///
/// Bounded to `max_depth` levels and `max_dirs` entries so it stays small on
/// large repositories; a trailing `…` line marks truncation. Returns `""` for an
/// empty or unreadable directory. Symlinks are not followed, so the walk cannot
/// cycle.
pub async fn dir_outline(
  root : String,
  max_depth? : Int = 3,
  max_dirs? : Int = 100,
) -> String {
  let out : Array[String] = []
  collect_dirs(root, 0, max_depth, max_dirs, out)
  if out.is_empty() {
    return ""
  }
  let truncated = if out.length() >= max_dirs { "\n  …" } else { "" }
  out.join("\n") + truncated
}

///|
/// Append `dir`'s child directories to `out` (depth-first, sorted), recursing up
/// to `max_depth` levels and `max_dirs` entries.
async fn collect_dirs(
  dir : String,
  depth : Int,
  max_depth : Int,
  max_dirs : Int,
  out : Array[String],
) -> Unit {
  guard depth < max_depth && out.length() < max_dirs else { return }
  let names = @fs.readdir(dir, sort=true) catch { _ => return }
  for name in names {
    guard out.length() < max_dirs else { return }
    if skip_outline_dir(name) {
      continue
    }
    let child = "\{dir}/\{name}"
    let kind = @fs.kind(child, follow_symlink=false) catch { _ => continue }
    guard kind is Directory else { continue }
    out.push(outline_indent(depth) + name + "/")
    collect_dirs(child, depth + 1, max_depth, max_dirs, out)
  }
}

///|
/// Directories left out of the outline: hidden dirs plus build output and
/// vendored deps.
fn skip_outline_dir(name : String) -> Bool {
  name.has_prefix(".") ||
  name == "node_modules" ||
  name == "_build" ||
  name == "target"
}

///|
fn outline_indent(depth : Int) -> String {
  let sb = StringBuilder()
  for _ in 0..<depth {
    sb.write_string("  ")
  }
  sb.to_string()
}

///|
/// Build the fixture declaratively, then snapshot the outline: directories are
/// listed depth-first and sorted (one nested level shown), while the README
/// file, the hidden `.git`, the vendored `node_modules`, and build output are
/// omitted.
async test "dir_outline lists directories, omitting files and noise" {
  with_tmpdir(root => {
    FileSystem::from_pairs([
      ("src/lib.mbt", "x"),
      ("lib/internal/x.mbt", "x"),
      ("node_modules/pkg/index.js", "x"),
      ("_build/out/x", "x"),
      (".git/objects/o", "x"),
      ("README.md", "x"),
    ]).write_to(root)
    inspect(
      dir_outline(root),
      content=(
        #|lib/
        #|  internal/
        #|src/
      ),
    )
  })
}

///|
async test "dir_outline is empty for an empty directory" {
  with_tmpdir(root => inspect(dir_outline(root), content=""))
}
