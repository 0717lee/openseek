///|
/// Everything needed to derive a development launch belongs to the detected
/// desktop workspace. The command therefore takes no path arguments.
priv struct Development {
  workspace : @packaging.Workspace
}

///|
/// Compile the MoonBit frontend to its normal `_build` artifact and prepare
/// only the raw third-party files a browser cannot obtain from Moon's graph.
/// The checked-in development HTML references every file in place.
async fn Development::prepare_frontend(self : Development) -> Unit {
  @packaging.build_frontend(self.workspace, release=false)
  @packaging.build_viz_frontend(self.workspace, release=false)
  let mermaid_entry = (self.workspace.mermaid_assets() : @path.Path)
    .join("mermaid.esm.min.mjs")
    .to_string()
  if !@asyncfs.exists(mermaid_entry) {
    @packaging.build_mermaid_assets(self.workspace)
  }
  @xterm_assets.stage_development(self.workspace)
}

///|
/// Build the checkout-local engine, then let the pinned Proton CLI resolve its
/// shared runtime/helper and build and launch the host. OpenSeek still owns the
/// product-specific inputs above; duplicating Proton's store layout here made
/// the old launcher depend on the removed `.proton/runtime.json` manifest.
async fn Development::run(self : Development) -> Unit {
  @packaging.build_engine(self.workspace, release=false)
  @packaging.run_proton_cli(self.workspace, [
    "-C",
    self.workspace.dir(),
    "dev",
    "--config",
    self.workspace.at("proton.project.json"),
    "--package",
    ".",
    "--no-frontend",
    "--setup",
  ])
}

///|
/// Build and run the unbundled desktop from paths detected from the current
/// monorepo checkout.
async fn main {
  let development : Development = { workspace: @packaging.locate_workspace() }
  development.prepare_frontend()
  development.run()
}
