///|
const DefaultEngine = "openseek"

///|
async fn local_engine_path(framework_command : String) -> String? {
  let command_path : @pathx.Path = framework_command
  let command_dir = command_path.dirname().resolve()
  let candidates = match @env.get("OS") {
    Some("Windows_NT") => ["openseek.exe", "openseek"]
    _ => ["openseek", "openseek.exe"]
  }
  // Proton preserves package.resources below the package resource root:
  // `Contents/Resources` beside `Contents/MacOS` in a macOS bundle, and a
  // `Resources` directory beside the Windows executable. Probe those
  // packaged layouts before the executable-adjacent Linux AppImage layout.
  let resource_roots = [
    command_dir.join("..").join("Resources"),
    command_dir.join("Resources"),
  ]
  for root in resource_roots {
    for candidate in candidates {
      let path = root
        .join("target/proton-package-input/bin")
        .join(candidate)
        .normalize()
        .to_string()
      if @fs.exists(path) {
        return Some(path)
      }
    }
  }
  for candidate in candidates {
    let path = command_dir.join(candidate).normalize().to_string()
    if @fs.exists(path) {
      return Some(path)
    }
  }
  // An unbundled `moon run ./desktop/package/dev` host and its engine belong to
  // one validated Moon development layout and native profile.
  if @development.Layout::detect(framework_command) is Some(layout) {
    let engine_dir : @pathx.Path = layout.engine_dir()
    for candidate in candidates {
      let path = engine_dir.join(candidate).normalize().to_string()
      if @fs.exists(path) {
        return Some(path)
      }
    }
  }
  None
}

///|
/// The engine executable to run: the packaged engine, then the engine from the
/// host's matching Moon build directory, and finally `openseek` on PATH for
/// other unbundled layouts.
pub async fn engine_command(framework_command : String) -> String {
  if local_engine_path(framework_command) is Some(path) {
    return path
  }
  DefaultEngine
}

///|
async test "packaged sibling wins before the matching Moon build engine" {
  let root : @pathx.Path = @fs.tmpdir(prefix="openseek-development-engine-")
  let build = root.join("_build/native/debug/build")
  let command_dir = build.join("openseek_desktop")
  let host = command_dir.join("openseek_desktop.exe").to_string()
  let engine_dir = build.join("bobzhang/openseek/cmd/openseek")
  let development = engine_dir.join("openseek.exe").to_string()
  @fs.mkdir(command_dir.to_string(), recursive=true)
  @fs.mkdir(engine_dir.to_string(), recursive=true)
  @fs.write_file(development, "development", create_mode=CreateOrTruncate)
  assert_eq(engine_command(host), development)
  let bundled = command_dir.join("openseek").to_string()
  @fs.write_file(bundled, "bundled", create_mode=CreateOrTruncate)
  assert_eq(engine_command(host), bundled)
  @fs.rmdir(root.to_string(), recursive=true)
}

///|
/// Proton's Windows package keeps `package.resources` in `Resources` beside
/// the executable rather than in a bundle's `Contents/Resources`; the engine
/// staged there must win before any executable-adjacent fallback.
async test "Proton Windows package engine is found below Resources" {
  let root : @pathx.Path = @fs.tmpdir(prefix="openseek-windows-package-engine-")
  defer (@fs.rmdir(root.to_string(), recursive=true) catch { _ => () })
  let command_dir = root.join("seekmoon")
  let host = command_dir.join("seekmoon.exe").to_string()
  let engine_dir = command_dir.join("Resources/target/proton-package-input/bin")
  @fs.mkdir(engine_dir.to_string(), recursive=true)
  let engine_name = if @env.get("OS") is Some("Windows_NT") {
    "openseek.exe"
  } else {
    "openseek"
  }
  let packaged = engine_dir.join(engine_name)
  @fs.write_file(packaged.to_string(), "packaged", create_mode=CreateOrTruncate)
  let adjacent = command_dir.join(engine_name).to_string()
  @fs.write_file(adjacent, "adjacent", create_mode=CreateOrTruncate)
  // Lookups return resolved paths, so compare in that spelling.
  assert_eq(engine_command(host), packaged.resolve().normalize().to_string())
}
