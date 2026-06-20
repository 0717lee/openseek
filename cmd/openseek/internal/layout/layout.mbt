///|
/// Depth and count caps for the project-layout outline, to bound prompt size on
/// large repositories.
const MaxDepth : Int = 3

///|
const MaxDirs : Int = 100

///|
/// A compact directory outline of `root` (directories only), so the agent starts
/// with the project's shape without spending a tool call on `ls` or a `tree`
/// binary that may be missing. Build output, vendored deps, and hidden dirs are
/// omitted. Returns `""` for an empty or unreadable directory.
pub async fn outline(root : String) -> String {
  let out : Array[String] = []
  collect(root, 0, out)
  if out.is_empty() {
    return ""
  }
  let truncated = if out.length() >= MaxDirs { "\n  …" } else { "" }
  let body = out.join("\n")
  (
    $|
    $|
    $|Project layout (directories; hidden, build, and vendored dirs omitted):
    $|\{body}\{truncated}
  )
}

///|
/// Append `dir`'s child directories to `out` (depth-first, sorted), recursing up
/// to `MaxDepth` levels and `MaxDirs` entries.
async fn collect(dir : String, depth : Int, out : Array[String]) -> Unit {
  guard depth < MaxDepth && out.length() < MaxDirs else { return }
  let names = @fs.readdir(dir, sort=true) catch { _ => return }
  for name in names {
    guard out.length() < MaxDirs else { return }
    if skip_dir(name) {
      continue
    }
    let child = @workspace_path.resolve(dir, name)
    let kind = @fs.kind(child, follow_symlink=false) catch { _ => continue }
    guard kind is Directory else { continue }
    out.push(indent(depth) + name + "/")
    collect(child, depth + 1, out)
  }
}

///|
/// Directories left out of the outline: hidden dirs (covers `.git`,
/// `.mooncakes`, `.openseek`, `.github`, …) plus build output and vendored deps.
fn skip_dir(name : String) -> Bool {
  name.has_prefix(".") ||
  name == "node_modules" ||
  name == "_build" ||
  name == "target"
}

///|
fn indent(depth : Int) -> String {
  let sb = StringBuilder()
  for _ in 0..<depth {
    sb.write_string("  ")
  }
  sb.to_string()
}
