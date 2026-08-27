// Launch diagnostics for the packaged app: a double-clicked bundle has no
// terminal, so early startup problems would otherwise vanish. OpenSeek starts
// with `openseek-desktop.log` in the per-user runtime dir; Proton 0.2.3 then
// installs its own global xlog handler when the native runtime starts. The
// native shutdown path keeps this fixed OpenSeek path so its CEF state remains
// available even after MoonBit has left the app pump. The bundle directory is
// read-only on end-user installs (App Translocation mounts it so), which is
// exactly when launch diagnostics matter, so both destinations live outside
// the bundle.

///|
async fn launch_logger(executable : String) -> Unit {
  guard @host.prepared_runtime_dir(executable) is Some(dir) else {
    fail("cannot determine the per-user runtime directory")
  }
  let path = dir.join("openseek-desktop.log").to_string()
  // Proton's native shutdown path can run from `atexit`, after MoonBit has
  // already left the app pump. Keep its append-only JSONL sink independent of
  // Proton's later global MoonBit logger configuration.
  @env.set_env_var("OPENSEEK_DESKTOP_LOG", path)
  @xlog.global().set_handler(@xlog.File(path))
  @xlog.global().set_level(Debug)
}
