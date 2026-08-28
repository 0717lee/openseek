///|
const FrontendEntryPath = "assets/index.html"

///|
const ProtonPackageFrontendEntryPath = "target/proton-package-input/assets/index.html"

///|
const ProtonPackageRipgrepPath = "target/proton-package-input/bin/rg"

///|
const ProtonPackageMoongrepPath = "target/proton-package-input/bin/moongrep"

///|
/// The package resource roots Proton may have placed beside `command_dir`,
/// in probe order. A macOS bundle keeps `package.resources` below
/// `Contents/Resources`, next to `Contents/MacOS`; a Windows package keeps
/// them below a `Resources` directory inside the executable's own directory.
/// Every packaged lookup shares this order rather than consulting the host
/// platform, so each layout stays testable on every host.
fn packaged_resource_roots(
  command_dir : @pathx.Absolute,
) -> Array[@pathx.Absolute] {
  [command_dir.join("..").join("Resources"), command_dir.join("Resources")]
}

///|
/// A packaged tool below each resource root, probing the Windows executable
/// spelling before the bare name so one staged layout serves both hosts.
fn packaged_tool_candidates(
  command_dir : @pathx.Absolute,
  relative : String,
) -> Array[@pathx.Absolute] {
  let candidates = []
  for root in packaged_resource_roots(command_dir) {
    candidates.push(root.join(Relative(relative + ".exe")))
    candidates.push(root.join(Relative(relative)))
  }
  candidates
}

///|
/// The visualizer shell and compiled bundle used for a standalone export.
pub struct VizAssets {
  shell : String
  bundle : String
}

///|
/// Locate the visualizer assets belonging to this exact host build.
///
/// Development uses the recognized Moon build layout. Installed applications
/// load the `viz` directory beside their packaged frontend, so a missing
/// package input fails instead of silently embedding a checkout artifact.
pub async fn HostState::viz_assets(self : HostState) -> VizAssets {
  guard self.executable is Some(executable) else {
    raise HostError(
      "cannot locate session visualizer assets without the host executable",
    )
  }
  let assets = match @development.Layout::detect(executable) {
    Some(layout) => { shell: layout.viz_shell(), bundle: layout.viz_bundle() }
    None => {
      let frontend = frontend_entry_path(executable)
      let viz = @pathx.Path(frontend).dirname().join("viz")
      {
        shell: viz.join("index.html").normalize().to_string(),
        bundle: viz.join("viz_app.js").normalize().to_string(),
      }
    }
  }
  guard @fs.exists(assets.shell) else {
    raise HostError("session visualizer shell does not exist: \{assets.shell}")
  }
  guard @fs.exists(assets.bundle) else {
    raise HostError(
      "session visualizer bundle does not exist: \{assets.bundle}",
    )
  }
  assets
}

///|
/// Read the visualizer shell and bundle selected by `HostState::viz_assets`.
pub async fn VizAssets::read(self : VizAssets) -> (String, String) {
  let shell = @fs.read_file(self.shell).text() catch {
    error =>
      raise HostError("could not read session visualizer shell: \{error}")
  }
  let bundle = @fs.read_file(self.bundle).text() catch {
    error =>
      raise HostError("could not read session visualizer bundle: \{error}")
  }
  (shell, bundle)
}

///|
/// The installed directory containing the Desktop's packaged command-line
/// tools. The value exists only when the pinned ripgrep asset is present, so
/// an incomplete installed bundle cannot shadow the user's PATH with an empty
/// or unrelated directory.
struct PackagedTools {
  bin_dir : String
  ripgrep : String
}

///|
/// Resolve the packaged tools installed with `executable`. Proton packages
/// keep them below the package resource root (`packaged_resource_roots`);
/// the Linux AppImage keeps them beside the Host.
pub async fn PackagedTools::resolve(executable : String) -> PackagedTools? {
  let command_dir = @pathx.Path(executable).dirname().resolve()
  let candidates = packaged_tool_candidates(
    command_dir,
    ProtonPackageRipgrepPath,
  )
  candidates.push(command_dir.join("rg.exe"))
  candidates.push(command_dir.join("rg"))
  for candidate in candidates {
    let path = candidate.normalize()
    if @fs.exists(path.to_string()) {
      return Some({
        bin_dir: path.to_path().dirname().to_string(),
        ripgrep: path.to_string(),
      })
    }
  }
  None
}

///|
/// Put the packaged tools first in this process's PATH. Desktop child
/// processes inherit this environment: OpenSeek's engine passes it to agent
/// shell tools, while Codex app-server passes it to its own tool processes.
/// Keep an already-leading entry unchanged so Linux's AppRun prefix is not
/// duplicated.
pub fn PackagedTools::apply_to_process_env(self : PackagedTools) -> Unit {
  @sys.set_env_var("PATH", self.path_with_precedence(@sys.get_env_var("PATH")))
}

///|
fn PackagedTools::path_with_precedence(
  self : PackagedTools,
  current : String?,
) -> String {
  if current is Some(path) &&
    (path == self.bin_dir || path.has_prefix(self.bin_dir + @env.path_sep)) {
    return path
  }
  @env.prepend_to_path_env(self.bin_dir, current)
}

///|
/// Locate the bundled frontend entry relative to the executable. Proton
/// packages keep the assets below their resource root — on macOS that is
/// `Contents/Resources/`, since `Contents/MacOS/` may only hold code and
/// non-`--deep` codesigning rejects data files there; on Windows it is the
/// `Resources` directory beside the executable. The executable-adjacent
/// layout serves the Linux AppImage. If those installed layouts are absent,
/// a host under Moon's native `_build` layout derives the checked-in
/// development document from the same checkout.
pub async fn frontend_entry_path(framework_command : String) -> String {
  let command_dir = @pathx.Path(framework_command).dirname().resolve()
  let candidates = []
  for root in packaged_resource_roots(command_dir) {
    candidates.push(root.join(ProtonPackageFrontendEntryPath))
  }
  candidates.push(
    command_dir.join("..").join("Resources").join(FrontendEntryPath),
  )
  candidates.push(command_dir.join(FrontendEntryPath))
  for candidate in candidates {
    let path = candidate.normalize().to_string()
    if @fs.exists(path) {
      return path
    }
  }
  if @development.Layout::detect(framework_command) is Some(layout) {
    let path = layout.frontend_entry()
    guard @fs.exists(path) else {
      fail("development frontend does not exist: \{path}")
    }
    return path
  }
  FrontendEntryPath
}

///|
/// Locate the packaged ripgrep installed with the Host: below the Proton
/// package resource root on macOS and Windows, beside the Host in the Linux
/// AppImage. Only a recognized Moon `_build` executable (or an embedding without
/// an executable path, used by development tests) may fall back to `PATH`.
/// An installed bundle with a missing asset fails closed instead of silently
/// running a machine-global ripgrep of an unknown version.
async fn ripgrep_command(executable : String?) -> String? {
  guard executable is Some(executable) else { return Some("rg") }
  if PackagedTools::resolve(executable) is Some(tools) {
    return Some(tools.ripgrep)
  }
  if @development.Layout::detect(executable) is Some(_) {
    Some("rg")
  } else {
    None
  }
}

///|
/// Locate the semantic-search provider beside the installed Host. A packaged
/// `moongrep` binary serves installed bundles, mirroring the ripgrep layout;
/// otherwise the provider resolves through `moonx` from PATH with a pinned
/// mooncakes registry coordinate.
///
/// This is deliberately not fail-closed like ripgrep: moongrep ships no
/// upstream release binaries, so a trial build has no asset to fail back on. A
/// real bundle with a staged `moongrep` binary always wins; the `moonx` PATH
/// fallback stays a documented interim provider until the package vendors a
/// moongrep binary (or a bundled `moongrep.wasm` run through the packaged
/// moonrun). The pinned coordinate keeps the version deterministic instead of
/// silently running an arbitrary machine binary.
async fn moongrep_command(executable : String?) -> String? {
  guard executable is Some(executable) else { return Some("moonx") }
  let command_dir = @pathx.Path(executable).dirname().resolve()
  let candidates = packaged_tool_candidates(
    command_dir,
    ProtonPackageMoongrepPath,
  )
  candidates.push(command_dir.join("moongrep.exe"))
  candidates.push(command_dir.join("moongrep"))
  for candidate in candidates {
    let path = candidate.normalize().to_string()
    if @fs.exists(path) {
      return Some(path)
    }
  }
  Some("moonx")
}

///|
async test "ripgrep resolution uses only packaged or recognized development layouts" {
  let root : @pathx.Path = @fs.tmpdir(prefix="openseek-ripgrep-resolution-")
  defer @fs.rmdir(root.to_string(), recursive=true)
  let installed = root.join("installed")
  @fs.mkdir(installed.to_string(), recursive=true)
  let installed_host = installed.join("openseek-desktop").to_string()
  assert_true(ripgrep_command(Some(installed_host)) is None)
  let adjacent = installed.join("rg").to_string()
  @fs.write_file(adjacent, "rg", create_mode=CreateOrTruncate)
  assert_eq(ripgrep_command(Some(installed_host)), Some(adjacent))
  guard PackagedTools::resolve(installed_host) is Some(installed_tools) else {
    fail("expected adjacent packaged tools")
  }
  let installed_bin = installed.to_string()
  assert_eq(
    installed_tools.path_with_precedence(Some("/usr/bin")),
    "\{installed_bin}\{@env.path_sep}/usr/bin",
  )
  let already_first = "\{installed_bin}\{@env.path_sep}/usr/bin"
  assert_eq(
    installed_tools.path_with_precedence(Some(already_first)),
    already_first,
  )

  let windows = root.join("windows")
  @fs.mkdir(windows.to_string(), recursive=true)
  let windows_host = windows.join("openseek-desktop.exe").to_string()
  let windows_rg = windows.join("rg.exe").to_string()
  @fs.write_file(windows_rg, "rg", create_mode=CreateOrTruncate)
  assert_eq(ripgrep_command(Some(windows_host)), Some(windows_rg))

  let macos = root.join("SeekMoon.app/Contents/MacOS")
  let resources_rg = root
    .join("SeekMoon.app/Contents/Resources")
    .join(ProtonPackageRipgrepPath)
  @fs.mkdir(macos.to_string(), recursive=true)
  @fs.mkdir(resources_rg.dirname().to_string(), recursive=true)
  @fs.write_file(resources_rg.to_string(), "rg", create_mode=CreateOrTruncate)
  assert_eq(
    ripgrep_command(Some(macos.join("openseek-desktop").to_string())),
    Some(resources_rg.normalize().to_string()),
  )

  let development = root.join("_build/native/debug/build/openseek_desktop")
  @fs.mkdir(development.to_string(), recursive=true)
  assert_eq(
    ripgrep_command(Some(development.join("openseek_desktop").to_string())),
    Some("rg"),
  )
}

///|
/// Proton's Windows package keeps `package.resources` in `Resources` beside
/// the executable, and the staged tools carry their Windows suffix there.
/// Both lookups must find that shape before any executable-adjacent fallback.
async test "Proton Windows package tools and frontend are found below Resources" {
  let root : @pathx.Path = @fs.tmpdir(prefix="openseek-windows-package-")
  defer (@fs.rmdir(root.to_string(), recursive=true) catch { _ => () })
  let app = root.join("seekmoon")
  let host = app.join("seekmoon.exe").to_string()
  let resources = app.join("Resources")
  let rg = resources.join(ProtonPackageRipgrepPath + ".exe")
  @fs.mkdir(rg.dirname().to_string(), recursive=true)
  @fs.write_file(rg.to_string(), "rg", create_mode=CreateOrTruncate)
  // Lookups return resolved paths, so compare in that spelling.
  assert_eq(
    ripgrep_command(Some(host)),
    Some(rg.resolve().normalize().to_string()),
  )
  let frontend = resources.join(ProtonPackageFrontendEntryPath)
  @fs.mkdir(frontend.dirname().to_string(), recursive=true)
  @fs.write_file(frontend.to_string(), "packaged", create_mode=CreateOrTruncate)
  assert_eq(
    frontend_entry_path(host),
    frontend.resolve().normalize().to_string(),
  )
}

///|
async test "packaged frontend wins before the matching checkout document" {
  let root : @pathx.Path = @fs.tmpdir(prefix="openseek-development-frontend-")
  let command_dir = root.join("_build/native/debug/build/openseek_desktop")
  @fs.mkdir(command_dir.to_string(), recursive=true)
  let host = command_dir.join("openseek_desktop.exe").to_string()
  let development = root.join("desktop-dev.html").to_string()
  @fs.write_file(development, "development", create_mode=CreateOrTruncate)
  assert_eq(frontend_entry_path(host), development)
  let assets = command_dir.join("assets")
  @fs.mkdir(assets.to_string())
  let packaged = assets.join("index.html").to_string()
  @fs.write_file(packaged, "packaged", create_mode=CreateOrTruncate)
  assert_eq(frontend_entry_path(host), packaged)
  @fs.rmdir(root.to_string(), recursive=true)
}

///|
/// Read the application version written by `proton_cli package`. Development
/// binaries have no package manifest and identify themselves explicitly
/// instead of consulting a second source version constant.
pub async fn package_version(executable : String) -> String {
  let command_dir = @pathx.Path(executable).dirname().resolve()
  // Proton writes the manifest into the macOS bundle's `Contents/Resources`
  // and directly beside the Windows executable.
  let candidates = [
    command_dir.join("..").join("Resources").join("proton-package.json"),
    command_dir.join("proton-package.json"),
  ]
  let mut manifest : String? = None
  for candidate in candidates {
    let path = candidate.normalize().to_string()
    if @fs.exists(path) {
      manifest = Some(path)
      break
    }
  }
  guard manifest is Some(manifest) else { return "development" }
  let text = @fs.read_file(manifest).text() catch { _ => return "development" }
  match @json.parse(text) {
    Object(fields) =>
      match fields.get("version") {
        Some(String(version)) if !version.is_blank() => version
        _ => "development"
      }
    _ => "development"
  }
}

///|
/// The running .app bundle root, when the executable sits in a macOS bundle
/// layout (`…/Name.app/Contents/MacOS/exe`); None anywhere else — dev
/// binaries and other platforms — which disables self-update.
pub fn app_bundle_path(executable : String) -> String? {
  let macos_dir = @pathx.Path(executable).dirname()
  let contents_dir = macos_dir.dirname()
  guard macos_dir.basename() == "MacOS" && contents_dir.basename() == "Contents" else {
    return None
  }
  let bundle = contents_dir.dirname().to_string()
  if bundle.has_suffix(".app") {
    Some(bundle)
  } else {
    None
  }
}
