///|
/// The complete Browser application directory consumed by openseek-api.
const BrowserDistDir : String = "dist/browser"

///|
const AssetBaseEnv : String = "OPENSEEK_ASSET_BASE"

///|
/// Build the Browser personality through the same locked esbuild asset graph
/// as native Desktop packages. An optional absolute asset base keeps this
/// generated HTML on the application origin while JS, CSS, and fonts use CDN.
async fn main {
  let matches = @argparse.Command(
    "package/browser",
    about="Build and stage the browser frontend assets.",
    flags=[
      FlagArg(
        "release",
        about="Build optimized release artifacts instead of debug artifacts.",
      ),
    ],
  ).parse()
  let release = matches.flags.get("release").unwrap_or(false)
  let ws = @packaging.locate_workspace()
  let esbuild_target = if @platform.linux {
    @web_assets.EsbuildTarget::linux_x64()
  } else if @platform.apple_os_mac {
    @web_assets.EsbuildTarget::macos_arm64()
  } else if @platform.win64 {
    @web_assets.EsbuildTarget::windows_x64()
  } else {
    raise @packaging.PackageError(
      "browser packaging supports Linux x64, macOS arm64, and Windows x64 hosts",
    )
  }
  let asset_base = @env.get(AssetBaseEnv).unwrap_or("")
  let distribution = @web_assets.Profile::browser().build(
    ws,
    esbuild_target,
    release~,
    asset_base~,
  )
  distribution.copy_to(ws.at(BrowserDistDir))
  println("generated \{ws.at(BrowserDistDir)}")
}
