///|
const XtermVersion : String = "5.5.0"

///|
const FitVersion : String = "0.10.0"

///|
const EsbuildVersion : String = "0.28.1"

///|
const VendorDir : String = "target/vendor-xterm"

///|
const XtermSha256 : String = "bd954fa721872170188cc5d7e83e88db3c83c9a18a4e8d24c2783d26491f59d2"

///|
const FitSha256 : String = "917ac44972453d5eed52edc1e50260c76398ce48cf2290c2e60671102bba0b33"

///|
/// The platform-specific npm package containing esbuild's native executable.
/// The type is opaque so packagers can only select a verified target below.
struct EsbuildTarget {
  package_name : String
  binary_path : String
  sha256 : String
}

///|
/// Select the verified macOS arm64 esbuild executable.
pub fn EsbuildTarget::macos_arm64() -> EsbuildTarget {
  {
    package_name: "darwin-arm64",
    binary_path: "bin/esbuild",
    sha256: "5d64cc9bc527d598450b5f8d47ff293eb9f3aea38dd9eff67fd55d228c5ccb43",
  }
}

///|
/// Select the verified Linux x64 esbuild executable.
pub fn EsbuildTarget::linux_x64() -> EsbuildTarget {
  {
    package_name: "linux-x64",
    binary_path: "bin/esbuild",
    sha256: "9ed00ab5330c94386f3273eda99a1fb0e8f37cfd6cb5270e4ad2fe3527da3546",
  }
}

///|
/// Select the verified Windows x64 esbuild executable.
pub fn EsbuildTarget::windows_x64() -> EsbuildTarget {
  {
    package_name: "win32-x64",
    binary_path: "esbuild.exe",
    sha256: "5c5d62da7572b57ddc1fa3caedc36c1218b5d8d02ce9c7ee70e3339fce4453c4",
  }
}

///|
priv struct Archive {
  filename : String
  url : String
  sha256 : String
}

///|
fn Archive::xterm() -> Archive {
  {
    filename: "xterm-\{XtermVersion}.tgz",
    url: "https://registry.npmjs.org/@xterm/xterm/-/xterm-\{XtermVersion}.tgz",
    sha256: XtermSha256,
  }
}

///|
fn Archive::fit() -> Archive {
  {
    filename: "addon-fit-\{FitVersion}.tgz",
    url: "https://registry.npmjs.org/@xterm/addon-fit/-/addon-fit-\{FitVersion}.tgz",
    sha256: FitSha256,
  }
}

///|
fn Archive::esbuild(target : EsbuildTarget) -> Archive {
  {
    filename: "esbuild-\{target.package_name}-\{EsbuildVersion}.tgz",
    url: "https://registry.npmjs.org/@esbuild/\{target.package_name}/-/\{target.package_name}-\{EsbuildVersion}.tgz",
    sha256: target.sha256,
  }
}

///|
priv struct AssetBuilder {
  workspace : @packaging.Workspace
  esbuild_target : EsbuildTarget
}

///|
fn AssetBuilder::at(self : AssetBuilder, relative : String) -> String {
  self.workspace.at("\{VendorDir}/\{relative}")
}

///|
async fn Archive::digest(self : Archive, path : String) -> String {
  guard path.has_suffix(self.filename) else {
    raise @packaging.PackageError(
      "archive path does not match \{self.filename}: \{path}",
    )
  }
  let bytes = @asyncfs.read_file(path).binary()
  @crypto.bytes_to_hex_string(@crypto.sha256(bytes)).to_lower()
}

///|
async fn AssetBuilder::ensure_cached_archive(
  self : AssetBuilder,
  archive : Archive,
) -> String {
  let path = self.at("cache/\{archive.filename}")
  if @asyncfs.exists(path) {
    let actual = archive.digest(path)
    if actual == archive.sha256 {
      return path
    }
    println(
      "cached \{archive.filename} failed SHA-256 verification; downloading it again",
    )
    @packaging.remove_path_if_exists(path)
  }
  println("downloading \{archive.url}")
  let (response, body) = @http.get(archive.url) catch {
    error if @async.is_being_cancelled() => raise error
    error =>
      raise @packaging.PackageError(
        "failed to download \{archive.url}: \{error}",
      )
  }
  if response.code < 200 || response.code >= 300 {
    raise @packaging.PackageError(
      "failed to download \{archive.url}: HTTP \{response.code} \{response.reason}",
    )
  }
  @asyncfs.write_file(path, body, create_mode=CreateOrTruncate)
  let actual = archive.digest(path)
  if actual != archive.sha256 {
    @packaging.remove_path_if_exists(path)
    raise @packaging.PackageError(
      "SHA-256 mismatch for \{archive.filename}: expected \{archive.sha256}, got \{actual}",
    )
  }
  path
}

///|
async fn AssetBuilder::extract_archive(
  self : AssetBuilder,
  archive : String,
  destination : String,
) -> Unit {
  @packaging.remove_path_if_exists(destination)
  @packaging.ensure_dir(destination)
  @packaging.run_checked(
    "tar",
    ["-xzf", archive, "-C", destination, "--strip-components=1"],
    dir=self.workspace.dir(),
  )
}

///|
fn AssetBuilder::esbuild_binary(self : AssetBuilder) -> String {
  self.at("work/esbuild/\{self.esbuild_target.binary_path}")
}

///|
/// Download and verify xterm.js, addon-fit, and the selected native esbuild,
/// then recreate their inspectable work directory for this packaging run.
async fn AssetBuilder::prepare(
  workspace : @packaging.Workspace,
  esbuild_target : EsbuildTarget,
) -> AssetBuilder {
  let builder : AssetBuilder = { workspace, esbuild_target }
  @packaging.ensure_dir(builder.at("cache"))
  let xterm_archive = builder.ensure_cached_archive(Archive::xterm())
  let fit_archive = builder.ensure_cached_archive(Archive::fit())
  let esbuild_archive = builder.ensure_cached_archive(
    Archive::esbuild(esbuild_target),
  )
  @packaging.remove_path_if_exists(builder.at("work"))
  builder.extract_archive(xterm_archive, builder.at("work/xterm"))
  builder.extract_archive(fit_archive, builder.at("work/fit"))
  builder.extract_archive(esbuild_archive, builder.at("work/esbuild"))
  builder
}
