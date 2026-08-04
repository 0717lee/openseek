// The persisted loopback port. The desktop window's origin is
// `http://127.0.0.1:<port>`, and the webview keys localStorage (UI
// preferences) by origin — so the port is remembered across launches.
// Losing it is harmless: a changed port only resets those preferences.

///|
const LocalPortFileName = "local_http.json"

///|
fn local_port_file(runtime_dir : @path.Path) -> String {
  runtime_dir.join(LocalPortFileName).to_string()
}

///|
/// The port a previous launch served on; `None` when never saved or
/// unreadable (both mean "pick a fresh ephemeral port").
pub async fn load_local_http_port(runtime_dir : @path.Path) -> Int? {
  let text = @fs.read_file(local_port_file(runtime_dir)).text() catch {
    error if @async.is_being_cancelled() => raise error
    _ => return None
  }
  let parsed = @json.parse(text) catch { _ => return None }
  guard parsed is { "port": Number(port, ..), .. } else { return None }
  let port = port.to_int()
  if port > 0 && port <= 65_535 {
    Some(port)
  } else {
    None
  }
}

///|
/// Remember the served port for the next launch, best effort — a failed
/// write only costs the webview's saved preferences.
pub async fn save_local_http_port(runtime_dir : @path.Path, port : Int) -> Unit {
  let body : Json = { "port": Json::number(port.to_double()) }
  @fs.write_file(local_port_file(runtime_dir), body.stringify()) catch {
    error if @async.is_being_cancelled() => raise error
    _ => ()
  }
}
