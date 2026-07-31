///|
/// The complete browser application directory consumed by openseek-api.
const BrowserDistDir : String = "dist/browser"

///|
/// The release JS bundle emitted by the root MoonBit workspace.
const BrowserBundleArtifact : String = "_build/js/release/build/openseek_desktop/frontend/browser/browser.js"

///|
/// Build and stage every browser asset behind one MoonBit packaging command.
///
/// xterm's standalone esbuild executable must match the machine running this
/// packager. Production runs inside a Linux x64 Docker build; the other
/// selections keep the same command usable by the supported desktop hosts.
async fn main {
  let ws = @packaging.locate_workspace()
  @packaging.remove_path_if_exists(ws.at(BrowserDistDir))
  @packaging.ensure_dir(ws.at(BrowserDistDir))
  @packaging.run_checked(
    "moon",
    ["build", "frontend/browser", "--target", "js", "--release"],
    dir=ws.dir(),
  )
  @packaging.build_viewer_stylesheet(ws)
  // The repository's root moon.work owns `_build` in a normal checkout. The
  // openseek-api image deliberately copies only this desktop module, in which
  // case Moon places the same artifact under the module root instead.
  let repository_bundle = ws.repo_at(BrowserBundleArtifact)
  let browser_bundle = if @asyncfs.exists(repository_bundle) {
    repository_bundle
  } else {
    ws.at(BrowserBundleArtifact)
  }
  let esbuild_target = if @platform.linux {
    @xterm_assets.linux_x64_target()
  } else if @platform.apple_os_mac {
    @xterm_assets.macos_arm64_target()
  } else if @platform.win64 {
    @xterm_assets.windows_x64_target()
  } else {
    raise @packaging.PackageError(
      "browser packaging supports Linux x64, macOS arm64, and Windows x64 hosts",
    )
  }
  let terminal_assets = @xterm_assets.build(ws, esbuild_target)
  @packaging.copy_file(
    ws.at("frontend/browser/index.html"),
    ws.at(BrowserDistDir + "/index.html"),
  )
  @packaging.copy_file(browser_bundle, ws.at(BrowserDistDir + "/browser.js"))
  @packaging.copy_file(ws.at("app.css"), ws.at(BrowserDistDir + "/app.css"))
  @packaging.copy_file(
    ws.at("viewer.css"),
    ws.at(BrowserDistDir + "/viewer.css"),
  )
  @packaging.copy_file(
    ws.at("codicon.ttf"),
    ws.at(BrowserDistDir + "/codicon.ttf"),
  )
  @packaging.copy_file(
    terminal_assets.javascript,
    ws.at(BrowserDistDir + "/xterm.js"),
  )
  @packaging.copy_file(
    terminal_assets.stylesheet,
    ws.at(BrowserDistDir + "/xterm.css"),
  )
  @packaging.copy_tree(ws.at("fonts"), ws.at(BrowserDistDir + "/fonts"))
  println("generated \{ws.at(BrowserDistDir)}")
}
