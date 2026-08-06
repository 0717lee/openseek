///|
const WebStagingDir : String = "target/web-assets"

///|
const IndexTemplatePath : String = "index.html"

///|
const ViewerStylesheetPath : String = "viewer.css"

///|
const WebEntrySource : String =
  #|import "./viewer.css";
  #|import "./app.css";
  #|import "./xterm.css";
  #|import "./xterm.js";
  #|import "./application.js";
  #|

///|
const StylesheetToken : String = "__OPENSEEK_STYLESHEET__"

///|
const JavascriptToken : String = "__OPENSEEK_JAVASCRIPT__"

///|
/// One SeekMoon Web build profile. Desktop and Browser compile different
/// MoonBit entry packages, then share the exact same asset graph and title.
struct Profile {
  id : String
  frontend_package : String
  frontend_artifact : String
}

///|
/// Select the embedded Desktop Web personality.
pub fn Profile::desktop() -> Profile {
  {
    id: "desktop",
    frontend_package: "frontend/desktop",
    frontend_artifact: "build/openseek_desktop/frontend/desktop/desktop.js",
  }
}

///|
/// Select the Browser console Web personality served by openseek-api.
pub fn Profile::browser() -> Profile {
  {
    id: "browser",
    frontend_package: "frontend/browser",
    frontend_artifact: "build/openseek_desktop/frontend/browser/browser.js",
  }
}

///|
/// A complete self-contained Web directory: generated index and manifest plus
/// content-hashed JavaScript, CSS, and font assets.
struct Distribution {
  directory : String
}

///|
/// Replace `destination` with this complete Web distribution.
pub async fn Distribution::copy_to(
  self : Distribution,
  destination : String,
) -> Unit {
  @packaging.copy_tree(self.directory, destination)
}

///|
priv struct AssetBase(String)

///|
fn AssetBase::parse(value : String) -> AssetBase raise @packaging.PackageError {
  if value == "" {
    return AssetBase(value)
  }
  guard (value.has_prefix("https://") || value.has_prefix("http://")) &&
    value.has_suffix("/") else {
    raise PackageError(
      "OPENSEEK_ASSET_BASE must be an absolute HTTP(S) directory URL ending in '/': \{value}",
    )
  }
  guard value
    .iter()
    .all(c => {
      c.is_ascii_graphic() &&
      c != '"' &&
      c != '\'' &&
      c != '<' &&
      c != '>' &&
      c != '&' &&
      c != '\\'
    }) else {
    raise PackageError(
      "OPENSEEK_ASSET_BASE contains characters that are unsafe in generated HTML or CSS",
    )
  }
  AssetBase(value)
}

///|
fn AssetBase::url(self : AssetBase, relative : String) -> String {
  if self.0 == "" {
    "./" + relative
  } else {
    self.0 + relative
  }
}

///|
fn AssetBase::esbuild_argument(self : AssetBase) -> String? {
  if self.0 == "" {
    None
  } else {
    Some("--public-path=" + self.0)
  }
}

///|
/// The content-hashed files extracted from one esbuild metafile. This parser
/// is public inside the internal package so black-box tests cover the contract
/// used to generate deployable HTML and the asset manifest.
struct Metadata {
  javascript : String
  stylesheet : String
  files : Array[String]
}

///|
fn Metadata::relative_output_path(
  output_dir : String,
  output_path : String,
) -> String raise @packaging.PackageError {
  let normalized_dir = output_dir.replace_all(old="\\", new="/")
  let normalized_path = output_path.replace_all(old="\\", new="/")
  let prefix = normalized_dir + "/"
  guard normalized_path.strip_prefix(prefix) is Some(relative) else {
    raise PackageError(
      "esbuild output is outside the requested directory: \{output_path}",
    )
  }
  relative.to_owned()
}

///|
/// Parse esbuild's workspace-relative metafile and locate its JavaScript
/// entry, sibling CSS bundle, and all emitted content-addressed files. Relative
/// paths also avoid Windows drive separators in the JSON consumed by MoonBit.
pub fn Metadata::parse(
  text : String,
  output_dir : String,
) -> Metadata raise @packaging.PackageError {
  let root = @json.parse(text) catch {
    error => raise PackageError("invalid esbuild metafile JSON: \{error}")
  }
  guard root is Object(root_fields) &&
    root_fields.get("outputs") is Some(Object(outputs)) else {
    raise PackageError("esbuild metafile does not contain an outputs object")
  }
  let mut javascript : String? = None
  let mut stylesheet : String? = None
  let files : Array[String] = []
  for output_path, output in outputs {
    guard output is Object(fields) else {
      raise PackageError(
        "esbuild output metadata is not an object: \{output_path}",
      )
    }
    let relative = Metadata::relative_output_path(output_dir, output_path)
    files.push(relative)
    if fields.get("entryPoint") is Some(String(_)) {
      guard javascript is None else {
        raise PackageError(
          "esbuild metafile contains more than one JavaScript entry",
        )
      }
      guard relative.has_suffix(".js") else {
        raise PackageError("esbuild entry is not JavaScript: \{output_path}")
      }
      javascript = Some(relative)
      guard fields.get("cssBundle") is Some(String(css_output)) else {
        raise PackageError(
          "esbuild JavaScript entry does not name its CSS bundle",
        )
      }
      stylesheet = Some(Metadata::relative_output_path(output_dir, css_output))
    }
  }
  guard javascript is Some(javascript) else {
    raise PackageError("esbuild metafile contains no JavaScript entry")
  }
  guard stylesheet is Some(stylesheet) else {
    raise PackageError("esbuild metafile contains no CSS bundle")
  }
  { javascript, stylesheet, files }
}

///|
/// Render the shared HTML template with the content-hashed entry files. An
/// empty `asset_base` keeps the distribution self-contained with relative
/// URLs; an absolute base keeps HTML on the app origin while assets use CDN.
pub fn Metadata::render_index(
  self : Metadata,
  template : String,
  asset_base : String,
) -> String raise @packaging.PackageError {
  let base = AssetBase::parse(asset_base)
  guard template.contains(StylesheetToken) && template.contains(JavascriptToken) else {
    raise PackageError("Web index template is missing one or more asset tokens")
  }
  template
  .replace(old=StylesheetToken, new=base.url(self.stylesheet))
  .replace(old=JavascriptToken, new=base.url(self.javascript))
}

///|
/// Serialize the stable deployment manifest. Paths remain relative even for a
/// CDN build so upload tooling can address files under its chosen directory.
pub fn Metadata::manifest(self : Metadata) -> String {
  let manifest : Json = {
    "version": 1,
    "entry": { "javascript": self.javascript, "stylesheet": self.stylesheet },
    "files": self.files,
  }
  manifest.stringify(indent=2) + "\n"
}

///|
/// Build one Web distribution with the locked native esbuild. Debug builds
/// remain readable; release builds add MoonBit optimization and esbuild
/// minification. Desktop and Browser otherwise share the same asset graph.
pub async fn Profile::build(
  self : Profile,
  workspace : @packaging.Workspace,
  esbuild_target : EsbuildTarget,
  release~ : Bool,
  asset_base? : String = "",
) -> Distribution {
  let base = AssetBase::parse(asset_base)
  let release_args = if release { ["--release"] } else { [] }
  let mode = if release { "release" } else { "debug" }
  @packaging.run_checked(
    "moon",
    ["build", self.frontend_package, "--target", "js", ..release_args],
    dir=workspace.dir(),
  )
  @packaging.build_viewer_stylesheet(workspace)
  @packaging.build_mermaid_assets(workspace)
  let builder = AssetBuilder::prepare(workspace, esbuild_target)
  let terminal = builder.build_terminal()
  let relative_root = "\{WebStagingDir}/\{self.id}"
  let root = workspace.at(relative_root)
  let input = root + "/input"
  let output = root + "/dist"
  let metafile = root + "/metafile.json"
  @packaging.remove_path_if_exists(root)
  @packaging.ensure_dir(input)
  @packaging.write_text(input + "/entry.js", WebEntrySource)
  @packaging.copy_file(
    workspace.repo_at("_build/js/\{mode}/\{self.frontend_artifact}"),
    input + "/application.js",
  )
  @packaging.copy_file(workspace.at("app.css"), input + "/app.css")
  @packaging.copy_file(workspace.at("codicon.ttf"), input + "/codicon.ttf")
  @packaging.copy_file(terminal.javascript, input + "/xterm.js")
  @packaging.copy_file(terminal.stylesheet, input + "/xterm.css")
  @packaging.copy_tree(workspace.at("fonts"), input + "/fonts")
  // The editor keeps codicon.ttf relative to its stylesheet, so esbuild can
  // fingerprint both without rewriting the reusable viewer CSS.
  @packaging.copy_file(
    workspace.at(ViewerStylesheetPath),
    input + "/viewer.css",
  )
  let args = [
    input + "/entry.js",
    "--bundle",
    "--format=iife",
    "--platform=browser",
    "--target=es2020",
    "--legal-comments=inline",
    "--entry-names=assets/[name]-[hash]",
    "--asset-names=assets/[name]-[hash]",
    "--loader:.ttf=file",
    "--loader:.woff2=file",
    "--outdir=\{relative_root}/dist",
    "--metafile=\{relative_root}/metafile.json",
  ]
  if release {
    args.push("--minify")
  }
  if base.esbuild_argument() is Some(argument) {
    args.push(argument)
  }
  @packaging.run_checked(builder.esbuild_binary(), args, dir=workspace.dir())
  let metadata = Metadata::parse(
    @asyncfs.read_file(metafile).text(),
    relative_root + "/dist",
  )
  @packaging.ensure_dir(output + "/fonts")
  @packaging.copy_file(
    workspace.at("fonts/LICENSE.txt"),
    output + "/fonts/LICENSE.txt",
  )
  @packaging.copy_tree(workspace.mermaid_assets(), output + "/mermaid")
  metadata.files.push("fonts/LICENSE.txt")
  let template = @asyncfs.read_file(workspace.at(IndexTemplatePath)).text()
  @packaging.write_text(
    output + "/index.html",
    metadata.render_index(template, asset_base),
  )
  @packaging.write_text(output + "/asset-manifest.json", metadata.manifest())
  { directory: output }
}
