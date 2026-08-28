///|
/// The desktop shell entry. Its `frontend/browser` sibling is the console
/// bundle served by openseek-api and is not shipped inside the desktop app.
const FrontendPackage : String = "frontend/desktop"

///|
/// The JS bundle's path below MoonBit's target/profile build directory.
const FrontendBundleArtifact : String = "build/openseek_desktop/frontend/desktop/desktop.js"

///|
/// The stable path the host and packagers read the frontend bundle from.
const FrontendBundleOutput : String = "frontend.js"

///|
/// The standalone session visualizer package in the monorepo root module.
const VizFrontendPackage : String = "cmd/viz_app"

///|
/// The visualizer bundle's path below MoonBit's JS target/profile directory.
const VizBundleArtifact : String = "build/bobzhang/openseek-viz-app/openseek-viz-app.js"

///|
/// The generated application stylesheet staged by production packagers.
/// Development keeps loading the checked-in `app.css` import manifest, while
/// packaged layouts receive this single concatenated file under that name.
const AppStyleOutput : String = "app.generated.css"

///|
/// The stylesheet the embedded code viewer needs, assembled from the editor
/// dependency's CSS. `index.html` links it by this name next to `frontend.js`.
const ViewerStyleOutput : String = "viewer.css"

///|
/// Application CSS sources in cascade order, relative to the desktop module.
/// Keep the checked-in `app.css` development imports in the same order.
fn app_css_sources() -> Array[String] {
  [
    "app_font.css", "styles/tokens.css", "styles/base.css", "styles/terminal.css",
    "styles/file_panel.css", "styles/sidebar.css", "styles/main_header.css", "styles/transcript.css",
    "styles/composer.css", "styles/codex.css", "styles/pages.css", "styles/overlays.css",
    "styles/responsive.css",
  ]
}

///|
/// The editor workspace member. The viewer's reusable CSS and font assets are
/// read from the same checkout as the desktop that imports its MoonBit
/// packages. The path is relative to the monorepo root and therefore resolves
/// through `repo_at`, not `at`.
const EditorDepRoot : String = "editor"

///|
/// The published editor package deliberately excludes its reference shell,
/// including that shell's theme. The desktop owns this small theme bridge so
/// the reusable viewer styles still receive their `--vscode-*` variables.
const ViewerThemeSource : String = "viewer_theme.css"

///|
/// The editor CSS files the embedded viewer depends on (relative to
/// `EditorDepRoot`), in cascade order. Re-sync this list on an editor version
/// bump. Reference-shell CSS is deliberately absent from the package; the
/// desktop supplies its own theme, panel layout, and file tree.
fn viewer_css_sources() -> Array[String] {
  [
    "viewer/browser/view/codicon/codicon.css", "viewer/browser/view/editor.css",
    "viewer/ui/scrollbar/scrollable_element.css", "viewer/browser/view_parts/view_lines/view_lines.css",
    "viewer/browser/view_parts/selections/view_overlays.css", "viewer/browser/view_parts/content_widgets/content_widgets.css",
    "viewer/browser/view_parts/overlay_widgets/overlay_widgets.css", "viewer/browser/view_parts/selections/selections.css",
    "viewer/browser/view_parts/current_line_highlight/current_line_highlight.css",
    "viewer/browser/view_parts/decorations/decorations.css", "viewer/browser/view_parts/view_cursors/view_cursors.css",
    "viewer/browser/view_parts/margin/margin.css", "viewer/browser/view_parts/margin/lines_decorations.css",
    "viewer/browser/view_parts/view_lines/tokens.css", "viewer/browser/view_parts/view_lines/markers.css",
    "viewer/browser/diff_editor/diff_editor.css", "viewer/contrib/folding/browser/folding.css",
    "viewer/contrib/contextmenu/browser/contextmenu.css", "viewer/contrib/definition/browser/definition.css",
    "viewer/contrib/references/browser/references.css", "viewer/contrib/hover/hover.css",
    "viewer/contrib/quick_diff/browser/quick_diff.css", "viewer/contrib/agent_feedback/browser/agent_feedback.css",
    "viewer/browser/diagram_viewport/diagram_viewport.css", "viewer/contrib/markdown_comments/browser/markdown_comments.css",
    "internal/viewer/browser/markdown_document/markdown_document.css",
  ]
}

///|
/// The vendored codicon icon font `codicon.css`'s `@font-face` loads at the
/// site root (`url("/codicon.ttf")`), exactly like the editor's own web
/// build serves it. Proton resolves `/codicon.ttf` against the
/// `proton://app/` origin and maps it to the asset directory root, so the
/// desktop ships the upstream CSS unmodified and just places the font next
/// to `viewer.css`.
const CodiconFontSource : String = "viewer/browser/view/codicon/codicon.ttf"

///|
const CodiconFontOutput : String = "codicon.ttf"

///|
/// The verified Mermaid runtime staged by the editor-owned asset builder. The
/// platform packagers copy this tree beside their frontend bundle.
const MermaidAssetOutput : String = "target/vendor-mermaid/dist"

///|
const NativeBinary : String = "build/openseek_desktop/openseek_desktop.exe"

///|
const EnginePackage : String = "cmd/openseek"

///|
const EngineBinary : String = "build/bobzhang/openseek/cmd/openseek/openseek.exe"

///|
/// Raised when a packaging helper cannot complete a filesystem, build, or
/// toolchain step.
///
/// The `Show` impl renders the payload message: an uncaught `PackageError`
/// surfaces through the async runtime's `println(err)` (via the
/// `%error.to_string` intrinsic), which would otherwise print only the
/// qualified constructor name and drop the message.
pub(all) suberror PackageError {
  /// A packaging failure with a human-readable diagnostic.
  PackageError(String)
}

///|
pub impl Show for PackageError with fn output(self, logger) {
  match self {
    PackageError(message) => logger.write_string("package error: \{message}")
  }
}

///|
/// The desktop workspace being packaged. The value is opaque to callers so
/// all path decisions stay centralized here. `root` is absolute, so every
/// path derived from it is absolute too and a subprocess's working directory
/// can never change which file a path names.
struct Workspace {
  // Absolute, normalized path to the desktop workspace directory.
  root : String
}

///|
/// Locate the desktop workspace from either the workspace directory itself or
/// the monorepo root. The matched directory is resolved to an absolute path so
/// later path math is independent of any later working-directory change.
pub async fn locate_workspace() -> Workspace {
  for candidate in [".", "desktop"] {
    if @asyncfs.exists(candidate + "/moon.mod") &&
      @asyncfs.exists(candidate + "/frontend") {
      return { root: absolute_path(candidate) }
    }
  }
  raise PackageError(
    "cannot locate the desktop workspace; run from the desktop directory or the monorepo root",
  )
}

///|
/// Return the absolute desktop workspace directory.
pub fn Workspace::dir(self : Workspace) -> String {
  self.root
}

///|
/// Resolve a path relative to the desktop workspace directory, as an absolute
/// path.
pub fn Workspace::at(self : Workspace, relative : String) -> String {
  join_path(self.root, relative)
}

///|
/// The monorepo root, one level up from the desktop workspace, absolute.
pub fn Workspace::repo(self : Workspace) -> String {
  (self.root : @path.Path).dirname().to_string()
}

///|
/// Resolve a path relative to the monorepo root, as an absolute path.
pub fn Workspace::repo_at(self : Workspace, relative : String) -> String {
  join_path(self.repo(), relative)
}

///|
/// Return the staged local Mermaid runtime directory.
pub fn Workspace::mermaid_assets(self : Workspace) -> String {
  self.at(MermaidAssetOutput)
}

///|
/// Return the generated application stylesheet consumed by package layouts.
pub fn Workspace::app_stylesheet(self : Workspace) -> String {
  self.at(AppStyleOutput)
}

///|
/// Join `relative` onto an absolute `base` using host path rules, yielding an
/// absolute path. Centralizing the join keeps every workspace path absolute.
fn join_path(base : String, relative : String) -> String {
  (base : @path.Path).join((relative : @path.Path)).to_string()
}

///|
/// Return the selected-mode native desktop host binary path under the
/// monorepo root, where the single root moon.work places all build output.
pub fn Workspace::native_binary(self : Workspace, release~ : Bool) -> String {
  let mode = if release { "release" } else { "debug" }
  self.repo_at("_build/native/\{mode}/\{NativeBinary}")
}

///|
/// Return the selected-mode openseek engine binary path under the monorepo
/// root.
pub fn Workspace::engine_binary(self : Workspace, release~ : Bool) -> String {
  let mode = if release { "release" } else { "debug" }
  self.repo_at("_build/native/\{mode}/\{EngineBinary}")
}

///|
/// Return the selected-mode JavaScript frontend artifact emitted by Moon.
/// Development serves this file in place; packagers copy the same artifact
/// into their stable resource layout.
pub fn Workspace::frontend_binary(self : Workspace, release~ : Bool) -> String {
  let mode = if release { "release" } else { "debug" }
  self.repo_at("_build/js/\{mode}/\{FrontendBundleArtifact}")
}

///|
/// Return the selected-mode standalone visualizer bundle emitted by Moon.
pub fn Workspace::viz_bundle(self : Workspace, release~ : Bool) -> String {
  let mode = if release { "release" } else { "debug" }
  self.repo_at("_build/js/\{mode}/\{VizBundleArtifact}")
}

///|
/// Return the checked-in standalone visualizer HTML shell.
pub fn Workspace::viz_shell(self : Workspace) -> String {
  self.repo_at("web/index.html")
}

///|
/// Read the desktop module version used as the package source of truth.
/// Proton writes this value into its package manifest; platform tooling that
/// has not migrated to Proton yet reads the same field instead of keeping a
/// second version constant.
pub async fn Workspace::module_version(self : Workspace) -> String {
  let manifest = self.at("moon.mod")
  let text = @asyncfs.read_file(manifest).text()
  for line in text.split("\n") {
    let line = line.trim().to_owned()
    if line.has_prefix("version = \"") && line.has_suffix("\"") {
      let version = line
        .unsafe_substring(start=11, end=line.length() - 1)
        .to_string()
      if !version.is_empty() {
        return version
      }
    }
  }
  raise PackageError("desktop version not found in \{manifest}")
}

///|
/// Return the openseek engine package path relative to the monorepo root.
pub fn engine_package() -> String {
  EnginePackage
}

///|
/// How the desktop module spells its dependency on the Proton library.
const ProtonPackagePrefix : String = "moonbit-community/proton@"

///|
/// The pinned Proton release, read back from the desktop module's own
/// dependency on the Proton library. `moonbit-community/proton_cli` and
/// `moonbit-community/proton` are published together from one version line,
/// so deriving the CLI from the library pin keeps `moon.mod` the single place
/// a Proton bump is spelled — a second constant here would silently drift.
pub async fn Workspace::proton_version(self : Workspace) -> String {
  let manifest = self.at("moon.mod")
  let text = @asyncfs.read_file(manifest).text()
  for line in text.split("\n") {
    for field in line.split("\"") {
      if field.strip_prefix(ProtonPackagePrefix) is Some(version) &&
        !version.is_empty() {
        return version.to_owned()
      }
    }
  }
  raise PackageError("no \{ProtonPackagePrefix}<version> found in \{manifest}")
}

///|
/// The registry coordinate `moonx` resolves the Proton CLI from.
async fn Workspace::proton_cli_package(self : Workspace) -> String {
  "moonbit-community/proton_cli@\{self.proton_version()}"
}

///|
/// Run the pinned Proton CLI. `moonx` fetches the published executable into
/// the registry cache and runs it straight from there, so there is no install
/// step, no binary of ours to keep fresh, and no per-host path to spell.
/// `args` is the CLI's own grammar, `-C` included: the callers do not agree on
/// one root, since `cef setup` reads the monorepo's resolved dependencies
/// while `package` acts on the desktop workspace.
pub async fn run_proton_cli(
  ws : Workspace,
  args : Array[String],
  extra_env? : Map[String, String] = Map([]),
) -> Unit {
  run_checked(
    "moonx",
    [ws.proton_cli_package(), ..args],
    dir=ws.dir(),
    extra_env~,
  )
}

///|
/// Install the shared Proton CEF runtime and subprocess helper this checkout's
/// Proton pin calls for. Proton 0.2 keeps both in the user-level store
/// (`~/.proton/store` and `~/.proton/helpers`) and skips work that is already
/// present, so the packagers call this unconditionally instead of keeping a
/// second copy of Proton's cache rules. It runs at the monorepo root, where
/// Moon resolves the Proton package that owns the CEF requirement.
pub async fn setup_cef(
  ws : Workspace,
  extra_env? : Map[String, String] = Map([]),
) -> Unit {
  run_proton_cli(ws, ["-C", ws.repo(), "cef", "setup"], extra_env~)
}

///|
/// Recursively copy a directory tree, replacing the destination. The walk
/// uses the async filesystem API rather than the host's `cp -R`, so the
/// packagers behave the same from PowerShell — where no `cp` executable is on
/// `PATH` — as from a POSIX shell. File modes are not preserved; callers that
/// stage executables set them explicitly afterwards.
pub async fn copy_tree(source : String, destination : String) -> Unit {
  remove_path_if_exists(destination)
  copy_tree_into(source, destination)
}

///|
async fn copy_tree_into(source : String, destination : String) -> Unit {
  ensure_dir(destination)
  for entry in @asyncfs.readdir(source, sort=true) {
    let from = join_path(source, entry)
    let to = join_path(destination, entry)
    if @asyncfs.kind(from) is Directory {
      copy_tree_into(from, to)
    } else {
      copy_file(from, to)
    }
  }
}

///|
async test "copy_tree replaces the destination with the full source tree" {
  let root = @asyncfs.tmpdir(prefix="openseek-copy-tree-")
  defer (remove_path_if_exists(root) catch { _ => () })
  let source = join_path(root, "source")
  let nested = join_path(source, "nested/deeper")
  ensure_dir(nested)
  write_text(join_path(source, "top.txt"), "top")
  write_text(join_path(nested, "leaf.txt"), "leaf")
  let destination = join_path(root, "destination")
  ensure_dir(destination)
  write_text(join_path(destination, "stale.txt"), "stale")
  copy_tree(source, destination)
  assert_eq(@asyncfs.read_file(join_path(destination, "top.txt")).text(), "top")
  assert_eq(
    @asyncfs.read_file(join_path(destination, "nested/deeper/leaf.txt")).text(),
    "leaf",
  )
  assert_false(@asyncfs.exists(join_path(destination, "stale.txt")))
}

///|
/// Resolve a path to an absolute path using the host filesystem rules.
pub fn absolute_path(path : String) -> String {
  (path : @path.Path).resolve().to_string()
}

///|
/// Run a subprocess in `dir`, inherit the current environment, and raise
/// `PackageError` when the command exits with a non-zero status.
pub async fn run_checked(
  command : String,
  args : Array[String],
  dir~ : String,
  extra_env? : Map[String, String] = Map([]),
) -> Unit {
  let joined_args = args.join(" ")
  println("$ [\{dir}] \{command} \{joined_args}")
  let code = @process.run(
    command,
    args,
    inherit_env=true,
    extra_env~,
    cwd=dir.view(),
  )
  if code != 0 {
    raise PackageError("command failed with exit code \{code}: \{command}")
  }
}

///|
/// Build the frontend package in the selected mode. Moon owns the artifact and
/// its dependency graph, so repeated development launches get its normal
/// incremental build without copying or rewriting the result.
pub async fn build_frontend(ws : Workspace, release~ : Bool) -> Unit {
  let release_args = if release { ["--release"] } else { [] }
  run_checked(
    "moon",
    ["build", FrontendPackage, "--target", "js", ..release_args],
    dir=ws.dir(),
  )
  let frontend = ws.frontend_binary(release~)
  if !@asyncfs.exists(frontend) {
    raise PackageError("desktop frontend artifact not found: \{frontend}")
  }
}

///|
/// Build the standalone visualizer bundle that Desktop embeds into exported
/// conversation documents.
pub async fn build_viz_frontend(ws : Workspace, release~ : Bool) -> Unit {
  let release_args = if release { ["--release"] } else { [] }
  run_checked(
    "moon",
    ["build", VizFrontendPackage, "--target", "js", ..release_args],
    dir=ws.repo(),
  )
  let bundle = ws.viz_bundle(release~)
  if !@asyncfs.exists(bundle) {
    raise PackageError("session visualizer artifact not found: \{bundle}")
  }
}

///|
/// Copy the visualizer shell and bundle into one package asset directory.
pub async fn Workspace::stage_viz_assets(
  self : Workspace,
  destination : String,
  release~ : Bool,
) -> Unit {
  ensure_dir(destination)
  copy_file(self.viz_shell(), join_path(destination, "index.html"))
  copy_file(self.viz_bundle(release~), join_path(destination, "viz_app.js"))
}

///|
/// Build the frontend package and copy the generated JS bundle to the stable
/// `frontend.js` path consumed by packaged layouts. Development calls
/// `build_frontend` directly and serves Moon's artifact in place.
pub async fn build_frontend_bundle(ws : Workspace, release~ : Bool) -> Unit {
  build_frontend(ws, release~)
  build_viz_frontend(ws, release~)
  copy_file(ws.frontend_binary(release~), ws.at(FrontendBundleOutput))
  build_app_stylesheet(ws)
  build_viewer_stylesheet(ws)
  build_mermaid_assets(ws)
}

///|
/// Download, verify, and stage the editor's pinned official Mermaid ESM
/// distribution for packaging beside the frontend bundle.
pub async fn build_mermaid_assets(ws : Workspace) -> Unit {
  @mermaid_assets.stage(
    ws.repo_at("\{EditorDepRoot}/target/vendor-mermaid/cache"),
    ws.mermaid_assets(),
    ws.dir(),
  )
}

///|
/// Concatenate the application CSS sources into the single stylesheet shipped
/// by every production layout. Development loads the same sources through the
/// checked-in `app.css` import manifest, so editing CSS needs no Moon rebuild.
pub async fn build_app_stylesheet(ws : Workspace) -> Unit {
  write_text(ws.app_stylesheet(), assembled_app_stylesheet(ws))
}

///|
/// Read the application CSS in cascade order without rewriting declarations or
/// resource URLs. `app_font.css` stays at the desktop root so its `fonts/` URL
/// resolves identically before and after concatenation.
async fn assembled_app_stylesheet(ws : Workspace) -> String {
  let css = StringBuilder()
  for source in app_css_sources() {
    let absolute = ws.at(source)
    if !@asyncfs.exists(absolute) {
      raise PackageError("application stylesheet not found: \{absolute}")
    }
    let text = @asyncfs.read_file(absolute).text()
    css.write_string(text)
    if !text.has_suffix("\n") {
      css.write_string("\n")
    }
  }
  css.to_string()
}

///|
async test "development app stylesheet imports every production source" {
  let ws = locate_workspace()
  let development = @asyncfs.read_file(ws.at("app.css")).text()
  let imports : Array[String] = []
  for line in development.split("\n") {
    if line.has_prefix("@import ") {
      imports.push(line.to_owned())
    }
  }
  let expected : Array[String] = []
  for source in app_css_sources() {
    expected.push("@import url(\"./" + source + "\");")
  }
  assert_eq(imports, expected)
}

///|
/// Concatenate the embedded viewer's CSS into a single `viewer.css` next to the
/// frontend bundle, mirroring the editor's own `scripts/build-web` step. The
/// viewer ships its styles as many files, none of which are loaded unless
/// assembled here; without them the viewer paints its raw measurement probes
/// over the panel instead of a styled editor.
pub async fn build_viewer_stylesheet(ws : Workspace) -> Unit {
  write_text(ws.at(ViewerStyleOutput), assembled_viewer_stylesheet(ws))
  copy_file(
    ws.repo_at("\{EditorDepRoot}/\{CodiconFontSource}"),
    ws.at(CodiconFontOutput),
  )
}

///|
/// Read and concatenate the desktop-owned theme followed by every editor
/// workspace stylesheet. Keeping assembly separate from the output write lets
/// tests exercise the real member files without mutating the checkout.
async fn assembled_viewer_stylesheet(ws : Workspace) -> String {
  let css = StringBuilder()
  let theme_path = ws.at(ViewerThemeSource)
  if !@asyncfs.exists(theme_path) {
    raise PackageError("viewer theme not found: \{theme_path}")
  }
  let theme = @asyncfs.read_file(theme_path).text()
  css.write_string("/* " + ViewerThemeSource + " */\n")
  css.write_string(theme)
  if !theme.has_suffix("\n") {
    css.write_string("\n")
  }
  css.write_string("\n")
  for source in viewer_css_sources() {
    let absolute = ws.repo_at("\{EditorDepRoot}/\{source}")
    if !@asyncfs.exists(absolute) {
      raise PackageError("viewer stylesheet not found: \{absolute}")
    }
    css.write_string("/* " + source + " */\n")
    let text = @asyncfs.read_file(absolute).text()
    css.write_string(text)
    if !text.has_suffix("\n") {
      css.write_string("\n")
    }
    css.write_string("\n")
  }
  css.to_string()
}

///|
async test "development viewer stylesheet imports every production source" {
  let ws = locate_workspace()
  let development = @asyncfs.read_file(ws.at("dev/viewer.css")).text()
  for source in viewer_css_sources() {
    assert_true(development.contains("../../editor/" + source))
  }
}

///|
/// Build the openseek engine from the monorepo source so the bundled engine
/// always matches the checkout instead of whatever happens to be on PATH.
pub async fn build_engine(
  ws : Workspace,
  release~ : Bool,
  extra_env? : Map[String, String] = Map([]),
) -> Unit {
  let release_args = if release { ["--release"] } else { [] }
  run_checked(
    "moon",
    ["build", EnginePackage, "--target", "native", ..release_args],
    dir=ws.repo(),
    extra_env~,
  )
  let engine_binary = ws.engine_binary(release~)
  if !@asyncfs.exists(engine_binary) {
    raise PackageError("openseek engine binary not found: \{engine_binary}")
  }
}

///|
/// Copy a file, replacing the destination if it already exists.
pub async fn copy_file(source : String, destination : String) -> Unit {
  @asyncfs.write_file(
    destination,
    @asyncfs.read_file(source),
    create_mode=CreateOrTruncate,
  )
}

///|
/// Write UTF-8 text to a file, replacing the file if it already exists.
pub async fn write_text(path : String, content : String) -> Unit {
  @asyncfs.write_file(path, content, create_mode=CreateOrTruncate)
}

///|
/// Create a directory and any missing parents if the path does not exist.
pub async fn ensure_dir(path : String) -> Unit {
  if @asyncfs.exists(path) {
    return
  }
  @asyncfs.mkdir(path, recursive=true) catch {
    // A concurrent caller can win the creation race on this directory or a
    // shared ancestor between the existence check and mkdir.
    @os_error.OSError(_) as error if error.is_EEXIST() => ()
    error => raise error
  }
}

///|
/// Remove a file or directory tree if it already exists.
pub async fn remove_path_if_exists(path : String) -> Unit {
  if !@asyncfs.exists(path) {
    return
  }
  if @asyncfs.kind(path) is Directory {
    @asyncfs.rmdir(path, recursive=true)
  } else {
    @asyncfs.remove(path)
  }
}

///|
/// The workspace derives every path from an absolute root, so the results are
/// absolute and independent of any later working-directory change. These pin
/// the join/parent math the packagers rely on.
test "workspace derives absolute paths from an absolute root" {
  let ws : Workspace = { root: "/abs/repo/desktop" }
  assert_eq(ws.dir(), "/abs/repo/desktop")
  assert_eq(ws.at("dist/app"), "/abs/repo/desktop/dist/app")
  assert_eq(ws.repo(), "/abs/repo")
  assert_eq(ws.repo_at("cmd/openseek"), "/abs/repo/cmd/openseek")
}

///|
// The bundle names carry no spaces, but a checkout path still can, so the
// space this pins is in the workspace root.
test "workspace path join preserves spaces and nested segments" {
  let ws : Workspace = { root: "/My Checkouts/w" }
  assert_eq(
    ws.at("dist/SeekMoon.app/Contents/Resources/toolchains/moonbit/macos-arm64"),
    "/My Checkouts/w/dist/SeekMoon.app/Contents/Resources/toolchains/moonbit/macos-arm64",
  )
}

///|
test "package build paths select debug or release" {
  let ws : Workspace = { root: "/abs/repo/desktop" }
  assert_eq(ws.app_stylesheet(), "/abs/repo/desktop/app.generated.css")
  assert_eq(
    ws.native_binary(release=false),
    "/abs/repo/_build/native/debug/build/openseek_desktop/openseek_desktop.exe",
  )
  assert_eq(
    ws.engine_binary(release=false),
    "/abs/repo/_build/native/debug/build/bobzhang/openseek/cmd/openseek/openseek.exe",
  )
  assert_eq(
    ws.native_binary(release=true),
    "/abs/repo/_build/native/release/build/openseek_desktop/openseek_desktop.exe",
  )
}

///|
async test "workspace module version reads moon.mod" {
  let ws = locate_workspace()
  assert_eq(ws.module_version(), "0.1.5")
}

///|
/// The Proton CLI coordinate must track the library pin, not a copy of it:
/// `cef setup` installs the CEF release and helper that this exact
/// `moonbit-community/proton` version links against, so a CLI from a
/// different release would install something the packaged host cannot use.
async test "proton CLI version follows the moon.mod library pin" {
  let ws = locate_workspace()
  assert_eq(
    ws.proton_cli_package(),
    "moonbit-community/proton_cli@\{ws.proton_version()}",
  )
  assert_true(ws.proton_version().has_prefix("0.2."))
}

///|
async test "viewer stylesheet assembles from the editor workspace member" {
  let ws = locate_workspace()
  let css = assembled_viewer_stylesheet(ws)
  assert_true(css.contains("/* viewer_theme.css */"))
  assert_true(css.contains(":root[data-theme=\"light\"] .moonbit-source"))
  assert_true(
    css.contains(
      "/* viewer/contrib/markdown_comments/browser/markdown_comments.css */",
    ),
  )
  assert_true(css.contains("/* viewer/browser/diff_editor/diff_editor.css */"))
  let font = ws.repo_at("\{EditorDepRoot}/\{CodiconFontSource}")
  guard @asyncfs.exists(font) else {
    fail("missing workspace viewer font: \{font}")
  }
}

///|
async test "application stylesheet assembles without development imports" {
  let ws = locate_workspace()
  let css = assembled_app_stylesheet(ws)
  assert_true(css.has_prefix("/* Geist Mono is bundled"))
  assert_true(css.contains("/* ---------- terminal panel ---------- */"))
  assert_true(css.contains("/* ---------- narrow (phone) layout ---------- */"))
  assert_true(!css.contains("@import"))
  // Prose and code deliberately use separate system stacks. Keeping the exact
  // token declarations here prevents a later all-mono shortcut from merging
  // the two responsibilities again.
  assert_true(
    css.contains(
      "--font-family-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas,",
    ),
  )
  assert_true(css.contains("\"Liberation Mono\", \"Courier New\", monospace;"))
  assert_true(
    css.contains("--font-family-sans: ui-sans-serif, system-ui, -apple-system,"),
  )
  assert_true(css.contains("BlinkMacSystemFont, \"Segoe UI\", sans-serif;"))
  assert_true(css.contains("font-family: var(--font-family-sans);"))
  assert_true(css.contains("font-family: var(--font-family-mono);"))
  assert_true(css.contains("--font-weight-regular: 450;"))
  assert_true(css.contains("font-weight: var(--font-weight-regular);"))
  assert_false(css.contains("--font-family-ui"))
  // Keep the semantic-token migration closed over every packaged source. This
  // catches a new component copied from an older stylesheet before undefined
  // custom properties silently erase its colors, borders, or shadows.
  for
    retired in [
      "mono", "paper", "surface", "surface-2", "ink", "ink-2", "ink-3", "line", "line-2",
      "accent", "accent-ink", "on-accent-ink", "accent-soft", "accent-line", "add",
      "add-bg", "add-line", "del", "del-bg", "del-line", "warn", "tool", "tool-bg",
      "tool-line", "code", "radius", "shadow", "shadow-pop",
    ] {
    assert_false(css.contains("--\{retired}:"))
    assert_false(css.contains("var(--\{retired})"))
    assert_false(css.contains("var(--\{retired},"))
  }
}

///|
async test "application stylesheet preserves pinned VS Code Git graph palette" {
  let ws = locate_workspace()
  let css = assembled_app_stylesheet(ws)
  for
    declaration in [
      "--git-graph-current: #1A5CFF;", "--git-graph-upstream: #652D90;", "--git-graph-base: #EA5C00;",
      "--git-graph-foreground-1: #FFB000;", "--git-graph-foreground-2: #DC267F;",
      "--git-graph-foreground-3: #994F00;", "--git-graph-foreground-4: #40B0A6;",
      "--git-graph-foreground-5: #B66DFF;",
    ] {
    assert_eq(css.split(declaration).length(), 2)
  }
  assert_true(
    css.contains(
      "@media (prefers-color-scheme: dark) {\n" +
      "  :root:not([data-theme=\"light\"]) .git-graph-section {\n" +
      "    --git-graph-current: #57A3F8;\n" +
      "    --git-graph-upstream: #AD80D7;\n" +
      "  }\n" +
      "}",
    ),
  )
  assert_true(
    css.contains(
      ":root[data-theme=\"dark\"] .git-graph-section {\n" +
      "  --git-graph-current: #57A3F8;\n" +
      "  --git-graph-upstream: #AD80D7;\n" +
      "}",
    ),
  )
  for property in ["--git-graph-current:", "--git-graph-upstream:"] {
    assert_eq(css.split(property).length(), 4)
  }
  for
    property in [
      "--git-graph-base:", "--git-graph-foreground-1:", "--git-graph-foreground-2:",
      "--git-graph-foreground-3:", "--git-graph-foreground-4:", "--git-graph-foreground-5:",
    ] {
    assert_eq(css.split(property).length(), 2)
  }
}

///|
async test "form field focus styling stays in the base stylesheet" {
  let ws = locate_workspace()
  let base = @asyncfs.read_file(ws.at("styles/base.css")).text()
  assert_true(base.contains("[data-focus-owner]:focus"))
  assert_true(
    base.contains("[data-focus-owner]:has([data-focus-target]:focus)"),
  )
  assert_true(base.contains("[data-focus-target]:focus"))
  // Discrete actions may use :focus-visible in their component stylesheet.
  // Form fields and composite wrappers go through the marker contract above;
  // keeping these older patterns out prevents a second border from returning.
  for source in app_css_sources() {
    if source != "styles/base.css" {
      let component = @asyncfs.read_file(ws.at(source)).text()
      guard !component.contains("input:focus") &&
        !component.contains("textarea:focus") &&
        !component.contains("select:focus") &&
        !component.contains(":focus-within") &&
        !component.contains(":focus {") else {
        fail("form field focus styling must stay in styles/base.css: " + source)
      }
    }
  }
}

///|
/// An uncaught `PackageError` reaches the user through the async runtime's
/// `println(err : Error)`; this pins that the message survives that path
/// (the intrinsic falls back to the bare constructor name without the Show
/// impl).
test "a PackageError shown as an Error keeps its message" {
  let error : Error = PackageError("viewer stylesheet not found: /x.css")
  assert_eq(
    error.to_string(),
    "package error: viewer stylesheet not found: /x.css",
  )
}

///|
pub extend PackageError with Show::{output, to_string}
