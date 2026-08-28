///|
const PackageInputRoot : String = "target/proton-package-input"

///|
const PackageAssetDir : String = PackageInputRoot + "/assets"

///|
const PackageBinDir : String = PackageInputRoot + "/bin"

///|
const RipgrepLicenseDir : String = PackageInputRoot + "/licenses/ripgrep"

///|
/// Build the application-specific inputs Proton cannot infer from
/// `proton.project.json`. Proton builds the native host during `package`; this
/// phase prepares only OpenSeek's generated frontend, embedded tools, and
/// engine, plus the shared CEF installation that both builds require.
async fn @packaging.Workspace::build_package_inputs(
  self : @packaging.Workspace,
  release~ : Bool,
) -> (@xterm_assets.Assets, @ripgrep_assets.Assets) {
  @packaging.setup_cef(self)
  @packaging.build_frontend_bundle(self, release~)
  let terminal_assets = @xterm_assets.build(
    self,
    @xterm_assets.linux_x64_target(),
  )
  let ripgrep_assets = @ripgrep_assets.build(
    self,
    @ripgrep_assets.linux_x64_target(),
  )
  @packaging.build_engine(self, release~)
  (terminal_assets, ripgrep_assets)
}

///|
/// Rebuild the declarative resource tree consumed by `package.resources`.
/// Proton preserves this project-relative tree below its package resource
/// directory; the host's runtime lookups deliberately know this one stable
/// prefix.
async fn @packaging.Workspace::stage_package_inputs(
  self : @packaging.Workspace,
  terminal_assets : @xterm_assets.Assets,
  ripgrep_assets : @ripgrep_assets.Assets,
  release~ : Bool,
) -> Unit {
  @packaging.remove_path_if_exists(self.at(PackageInputRoot))
  @packaging.ensure_dir(self.at(PackageAssetDir))
  @packaging.ensure_dir(self.at(PackageBinDir))
  @packaging.ensure_dir(self.at(RipgrepLicenseDir))
  @packaging.copy_file(
    self.app_stylesheet(),
    self.at(PackageAssetDir + "/app.css"),
  )
  for
    pair in [
      ("index.html", PackageAssetDir + "/index.html"),
      ("frontend.js", PackageAssetDir + "/frontend.js"),
      ("viewer.css", PackageAssetDir + "/viewer.css"),
      ("codicon.ttf", PackageAssetDir + "/codicon.ttf"),
    ] {
    let (source, destination) = pair
    @packaging.copy_file(self.at(source), self.at(destination))
  }
  // The verified terminal emulator assets generated during this packaging run
  // are loaded by index.html before frontend.js.
  @packaging.copy_file(
    terminal_assets.javascript,
    self.at(PackageAssetDir + "/xterm.js"),
  )
  @packaging.copy_file(
    terminal_assets.stylesheet,
    self.at(PackageAssetDir + "/xterm.css"),
  )
  @packaging.copy_tree(
    self.mermaid_assets(),
    self.at(PackageAssetDir + "/mermaid"),
  )
  @packaging.copy_tree(self.at("fonts"), self.at(PackageAssetDir + "/fonts"))
  self.stage_viz_assets(self.at(PackageAssetDir + "/viz"), release~)
  @packaging.copy_file(
    self.engine_binary(release~),
    self.at(PackageBinDir + "/openseek"),
  )
  @packaging.copy_file(ripgrep_assets.binary, self.at(PackageBinDir + "/rg"))
  @packaging.copy_file(
    ripgrep_assets.license_mit,
    self.at(RipgrepLicenseDir + "/LICENSE-MIT"),
  )
  @packaging.copy_file(
    ripgrep_assets.unlicense,
    self.at(RipgrepLicenseDir + "/UNLICENSE"),
  )
  @packaging.run_checked(
    "chmod",
    ["+x", PackageBinDir + "/openseek", PackageBinDir + "/rg"],
    dir=self.dir(),
  )
  // The read-only MoonBit toolchain seed the host copies into its per-user
  // runtime directory on first launch.
  let target = @moonbit.moonbit_linux_x64_toolchain()
  @moonbit.stage_moonbit_toolchain_seed(
    self,
    target,
    PackageInputRoot + "/" + target.seed_relative_dir(),
  )
}

///|
/// Build the exact Proton command arguments. The release flag must reach
/// Proton because Proton 0.2 builds the native host itself and then packages
/// that mode's executable.
fn proton_args(
  workspace : @packaging.Workspace,
  release~ : Bool,
) -> Array[String] {
  let args = [
    "-C",
    workspace.dir(),
    "package",
    "--config",
    "proton.project.json",
    "--format",
    "appimage",
  ]
  if release {
    args.push("--release")
  }
  args
}

///|
/// Hand the prepared resource tree to Proton. From here Proton owns the host
/// build, the AppDir layout with the CEF runtime, the launcher, the desktop
/// entry, and the AppImage itself.
async fn main {
  let matches = @argparse.Command(
    "package/linux",
    about="Prepare OpenSeek inputs and package the Linux AppImage with proton_cli.",
    flags=[
      FlagArg(
        "release",
        about="Build optimized release artifacts instead of debug artifacts.",
      ),
    ],
  ).parse()
  let release = matches.flags.get("release").unwrap_or(false)
  let ws = @packaging.locate_workspace()
  let (terminal_assets, ripgrep_assets) = ws.build_package_inputs(release~)
  println("built openseek engine: \{ws.engine_binary(release~)}")
  ws.stage_package_inputs(terminal_assets, ripgrep_assets, release~)
  @packaging.run_proton_cli(ws, proton_args(ws, release~))
  println("generated the Proton AppImage in \{ws.at("dist")}")
}

///|
async test "linux packaging requests Proton's AppImage format" {
  let workspace = @packaging.locate_workspace()
  let args = proton_args(workspace, release=false)
  assert_eq(args[0], "-C")
  assert_eq(args[1], workspace.dir())
  assert_true(args.contains("package"))
  assert_true(args.contains("appimage"))
  assert_false(args.contains("--release"))
  assert_true(proton_args(workspace, release=true).contains("--release"))
}
