///|
const PackageInputRoot : String = "target/proton-package-input"

///|
const PackageAssetDir : String = PackageInputRoot + "/assets"

///|
const PackageBinDir : String = PackageInputRoot + "/bin"

///|
const RipgrepLicenseDir : String = PackageInputRoot + "/licenses/ripgrep"

///|
/// Proton names its Windows outputs after the lowercase product name from
/// `proton.project.json`, below that file's `package.output` directory.
const AppDir : String = "dist/seekmoon"

///|
const ZipPath : String = "dist/seekmoon.zip"

///|
/// Portable NSIS extracted beside the other packaging tools, for hosts
/// without a system-wide NSIS installation.
const LocalMakensisDir : String = "dist/tools/nsis-3.12"

///|
const ProgramFilesX86MakensisDir : String = "C:/Program Files (x86)/NSIS"

///|
const ProgramFilesMakensisDir : String = "C:/Program Files/NSIS"

///|
/// Proton always produces the Windows app directory. Keep only the optional
/// distribution choices here instead of carrying Proton's string-valued CLI
/// arguments into the packaging model.
priv struct ArtifactPlan {
  zip : Bool
  installer : Bool
} derive(Debug, Eq)

///|
fn ArtifactPlan::parse(values : ArrayView[String]) -> ArtifactPlan raise {
  if values.is_empty() {
    return { zip: true, installer: true }
  }
  let mut zip = false
  let mut installer = false
  for value in values {
    match value {
      "app" => ()
      "zip" => zip = true
      "installer" => installer = true
      value =>
        raise @packaging.PackageError(
          "unsupported Windows package target '\{value}'; expected app, zip, or installer",
        )
    }
  }
  { zip, installer }
}

///|
fn package_command() -> @argparse.Command {
  Command(
    "package/windows",
    about="Prepare OpenSeek inputs and package the Windows app, portable zip, and NSIS installer with proton_cli.",
    flags=[
      FlagArg(
        "release",
        about="Build optimized release artifacts instead of debug artifacts.",
      ),
    ],
    options=[
      OptionArg(
        "target",
        action=Append,
        about="Artifact to produce: app, zip, or installer. Repeatable; defaults to zip and installer.",
      ),
    ],
  )
}

///|
fn ArtifactPlan::from_matches(
  matches : @argparse.Matches,
) -> ArtifactPlan raise {
  match matches.values.get("target") {
    Some(values) => ArtifactPlan::parse(values)
    None => ArtifactPlan::parse([])
  }
}

///|
/// Build the exact Proton command arguments for this artifact selection. The
/// release flag must reach Proton because Proton 0.2 builds the native host
/// itself and then packages that mode's executable. `installer` selects
/// Proton's `nsis` format: Proton generates the installer script and compiles
/// it with `makensis`.
fn ArtifactPlan::proton_args(
  self : ArtifactPlan,
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
    "app",
  ]
  if release {
    args.push("--release")
  }
  if self.zip {
    args.append(["--format", "zip"])
  }
  if self.installer {
    args.append(["--format", "nsis"])
  }
  args
}

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
    @xterm_assets.windows_x64_target(),
  )
  let ripgrep_assets = @ripgrep_assets.build(
    self,
    @ripgrep_assets.windows_x64_target(),
  )
  @packaging.build_engine(self, release~)
  (terminal_assets, ripgrep_assets)
}

///|
/// Rebuild the declarative resource tree consumed by `package.resources`.
/// Proton preserves this project-relative tree below the `Resources`
/// directory beside the packaged executable; the host's runtime lookups
/// deliberately know this one stable prefix.
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
  let bundled_engine = self.at(PackageBinDir + "/openseek.exe")
  @packaging.copy_file(self.engine_binary(release~), bundled_engine)
  @pe.set_windows_gui_subsystem(bundled_engine)
  @packaging.copy_file(
    ripgrep_assets.binary,
    self.at(PackageBinDir + "/rg.exe"),
  )
  @packaging.copy_file(
    ripgrep_assets.license_mit,
    self.at(RipgrepLicenseDir + "/LICENSE-MIT"),
  )
  @packaging.copy_file(
    ripgrep_assets.unlicense,
    self.at(RipgrepLicenseDir + "/UNLICENSE"),
  )
  // The read-only MoonBit toolchain seed the host copies into its per-user
  // runtime directory on first launch.
  let target = @moonbit.moonbit_windows_x64_toolchain()
  @moonbit.stage_moonbit_toolchain_seed(
    self,
    target,
    PackageInputRoot + "/" + target.seed_relative_dir(),
  )
}

///|
/// Proton compiles its generated installer with `makensis` from `PATH`. Return
/// the directory to put first on `PATH` when NSIS lives in one of the known
/// locations, or `None` when `makensis` already resolves on `PATH`.
async fn makensis_dir(ws : @packaging.Workspace) -> String? {
  for
    dir in [
      ws.at(LocalMakensisDir),
      ProgramFilesX86MakensisDir,
      ProgramFilesMakensisDir,
    ] {
    if @asyncfs.exists(dir + "/makensis.exe") {
      return Some(dir)
    }
  }
  let code = @process.run("makensis.exe", ["/VERSION"], inherit_env=true) catch {
    error if @async.is_being_cancelled() => raise error
    _ => 1
  }
  if code != 0 {
    raise @packaging.PackageError(
      "makensis.exe not found. Install NSIS on PATH or extract portable NSIS to \{ws.at(LocalMakensisDir)}/makensis.exe.",
    )
  }
  None
}

///|
/// Hand the prepared resource tree to Proton. From here Proton owns the host
/// build, the app directory with the CEF runtime beside the executable, the
/// package manifest, the portable ZIP, and the NSIS installer.
async fn @packaging.Workspace::package_with_proton(
  self : @packaging.Workspace,
  artifacts : ArtifactPlan,
  release~ : Bool,
  makensis_dir~ : String?,
) -> Unit {
  let package_env = @sys.get_env_vars()
  if makensis_dir is Some(dir) {
    @envx.prepend_path_entry(package_env, dir) |> ignore
  }
  @packaging.run_proton_cli(
    self,
    artifacts.proton_args(self, release~),
    extra_env=package_env,
  )
}

///|
async fn main {
  // Parse first: a mistyped target must fail before the build, not after it.
  let matches = package_command().parse()
  let artifacts = ArtifactPlan::from_matches(matches)
  let release = matches.flags.get("release").unwrap_or(false)
  let ws = @packaging.locate_workspace()
  // A missing installer tool must also fail before the build.
  let makensis_dir = if artifacts.installer { makensis_dir(ws) } else { None }
  let (terminal_assets, ripgrep_assets) = ws.build_package_inputs(release~)
  println("built openseek engine: \{ws.engine_binary(release~)}")
  ws.stage_package_inputs(terminal_assets, ripgrep_assets, release~)
  ws.package_with_proton(artifacts, release~, makensis_dir~)
  println("generated \{ws.at(AppDir)}")
  if artifacts.zip {
    println("generated \{ws.at(ZipPath)}")
  }
  if artifacts.installer {
    println("generated the NSIS installer in \{ws.at("dist")}")
  }
}

///|
test "windows package args default to zip and installer" {
  let matches = package_command().parse(argv=[])
  let artifacts = ArtifactPlan::from_matches(matches)
  assert_eq(artifacts, { zip: true, installer: true })
  assert_false(matches.flags.get("release").unwrap_or(false))
}

///|
test "windows package args accept release" {
  let matches = package_command().parse(argv=["--release", "--target", "app"])
  let artifacts = ArtifactPlan::from_matches(matches)
  assert_eq(artifacts, { zip: false, installer: false })
  assert_true(matches.flags.get("release").unwrap_or(false))
}

///|
test "windows package target app skips distribution archives" {
  let matches = package_command().parse(argv=["--target", "app"])
  assert_eq(ArtifactPlan::from_matches(matches), {
    zip: false,
    installer: false,
  })
}

///|
test "windows package target zip skips installer" {
  let matches = package_command().parse(argv=["--target", "zip"])
  assert_eq(ArtifactPlan::from_matches(matches), {
    zip: true,
    installer: false,
  })
}

///|
test "windows package target installer skips zip" {
  let matches = package_command().parse(argv=["--target", "installer"])
  assert_eq(ArtifactPlan::from_matches(matches), {
    zip: false,
    installer: true,
  })
}

///|
test "windows package targets can be repeated" {
  let matches = package_command().parse(argv=[
    "--target", "app", "--target", "zip", "--target", "installer",
  ])
  assert_eq(ArtifactPlan::from_matches(matches), { zip: true, installer: true })
}

///|
test "windows package rejects an unsupported target" {
  let matches = package_command().parse(argv=["--target", "msi"])
  try ArtifactPlan::from_matches(matches) catch {
    err =>
      assert_true(
        err
        .to_string()
        .contains(
          "unsupported Windows package target 'msi'; expected app, zip, or installer",
        ),
      )
  } noraise {
    _ => fail("expected unsupported Windows package target to fail")
  }
}

///|
test "windows package args reject removed zip-only flag" {
  try package_command().parse(argv=["--zip-only"]) catch {
    err =>
      assert_true(
        err.to_string().contains("unexpected argument '--zip-only' found"),
      )
  } noraise {
    _ => fail("expected removed --zip-only flag to fail")
  }
}

///|
/// Proton's formats mirror the artifact selection one to one: the app
/// directory is always requested, and each distribution choice adds its own
/// `--format`. The old `--no-build` and `--target` spellings are gone because
/// Proton 0.2 builds the host and names the formats itself.
async test "windows packaging maps artifacts to Proton formats" {
  let workspace = @packaging.locate_workspace()
  let everything : ArtifactPlan = { zip: true, installer: true }
  let args = everything.proton_args(workspace, release=false)
  assert_eq(args[0], "-C")
  assert_eq(args[1], workspace.dir())
  assert_true(args.contains("package"))
  assert_true(args.contains("app"))
  assert_true(args.contains("zip"))
  assert_true(args.contains("nsis"))
  assert_false(args.contains("--release"))
  assert_false(args.contains("--target"))
  assert_false(args.contains("--no-build"))
  let app_only : ArtifactPlan = { zip: false, installer: false }
  let release_args = app_only.proton_args(workspace, release=true)
  assert_true(release_args.contains("--release"))
  assert_false(release_args.contains("zip"))
  assert_false(release_args.contains("nsis"))
}
