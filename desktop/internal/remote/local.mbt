// The local transport: the desktop window's own loopback origin. The host
// serves the packaged frontend bundle over plain `http://127.0.0.1:<port>/`
// and upgrades `/ws` into exactly the JSON-RPC connection a relay browser
// gets (docs/remote-protocol.md), plus the local-only methods — so the
// window and a remote page share one client path end to end. The WebSocket
// is the capability boundary: it requires the launch token minted for the
// window's entry URL, and a present `Origin` header must be our own origin,
// which keeps foreign web pages (whose browsers always send one) out even
// though they can reach loopback.

///|
/// The loopback HTTP+WebSocket server owning the window's origin.
struct LocalServer {
  state : @api.ApiState
  extras : LocalExtras
  asset_dir : String
  token : String
  server : @http.Server
}

///|
/// Bind the loopback listener. The preferred port keeps the origin — and
/// with it the webview's localStorage (UI preferences) — stable across
/// launches; when it is taken, a fresh ephemeral port only costs those
/// preferences.
pub async fn LocalServer::start(
  state : @api.ApiState,
  asset_dir~ : String,
  token~ : String,
  extras~ : LocalExtras,
  preferred_port? : Int,
) -> LocalServer {
  let server = match preferred_port {
    Some(port) =>
      @http.Server(@socket.Addr::parse("127.0.0.1:\{port}")) catch {
        error if @async.is_being_cancelled() => raise error
        _ => Server(@socket.Addr::parse("127.0.0.1:0"))
      }
    None => Server(@socket.Addr::parse("127.0.0.1:0"))
  }
  { state, extras, asset_dir, token, server }
}

///|
pub fn LocalServer::port(self : LocalServer) -> Int {
  self.server.addr.port()
}

///|
/// The URL the window loads. The token rides the entry query string; the
/// page hands it back on its WebSocket dial.
pub fn LocalServer::entry_url(self : LocalServer) -> String {
  "http://127.0.0.1:\{self.port()}/?token=\{self.token}"
}

///|
/// Accept and serve connections for the app's lifetime. Each connection is
/// its own task: a static fetch answers one request and closes, while an
/// upgraded WebSocket lives as one client actor until the page goes away.
pub async fn LocalServer::run(self : LocalServer) -> Unit {
  defer self.server.close()
  @async.with_task_group(group => {
    for ;; {
      let (conn, _) = self.server.accept()
      group.spawn_bg(allow_failure=true, () => self.handle(conn))
    }
  })
}

///|
async fn LocalServer::handle(
  self : LocalServer,
  conn : @http.ServerConnection,
) -> Unit {
  defer conn.close()
  let request = conn.read_request()
  if request.headers.get("upgrade") is Some(upgrade) &&
    ascii_lower(upgrade) == "websocket" {
    self.serve_ws(request, conn)
  } else {
    self.serve_static(request, conn)
  }
}

///|
async fn LocalServer::serve_ws(
  self : LocalServer,
  request : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  guard ws_authorized(
    request.path,
    request.headers.get("origin"),
    token=self.token,
    port=self.port(),
  ) else {
    respond_status(conn, 403, "Forbidden")
    return
  }
  let ws = @websocket.from_http_server(request, conn)
  defer ws.close()
  WsClientActor::new(self.state, local_extras=self.extras).serve(ws) catch {
    error if @async.is_being_cancelled() => raise error
    // The page reloading or the window closing mid-frame is routine.
    _ => ()
  }
}

///|
/// Whether a WebSocket handshake may become a client connection: the `/ws`
/// route presenting the launch token, from our own origin (or none — a
/// non-browser debugging client has no `Origin`; the token remains its
/// capability).
fn ws_authorized(
  path : String,
  origin : String?,
  token~ : String,
  port~ : Int,
) -> Bool {
  let (route, query) = split_path_query(path)
  guard route == "/ws" && query_param(query, "token") == Some(token) else {
    return false
  }
  match origin {
    None => true
    Some(origin) => origin == "http://127.0.0.1:\{port}"
  }
}

///|
async fn LocalServer::serve_static(
  self : LocalServer,
  request : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  guard request.meth is Get else {
    respond_status(conn, 405, "Method Not Allowed")
    return
  }
  let (route, _) = split_path_query(request.path)
  guard static_asset_route(route) is Some(relative) else {
    respond_status(conn, 404, "Not Found")
    return
  }
  let body = @fs.read_file("\{self.asset_dir}/\{relative}").binary() catch {
    error if @async.is_being_cancelled() => raise error
    _ => {
      respond_status(conn, 404, "Not Found")
      return
    }
  }
  conn.send_response(200, "OK", extra_headers={
    "Content-Type": content_type(relative),
    "Content-Length": body.length().to_string(),
    // The bundle changes in place on self-update; make every launch
    // revalidate rather than trust a stale webview cache.
    "Cache-Control": "no-cache",
    "Connection": "close",
  })
  conn.write(body)
  conn.end_response()
}

///|
async fn respond_status(
  conn : @http.ServerConnection,
  code : Int,
  reason : String,
) -> Unit {
  conn.send_response(code, reason, extra_headers={
    "Content-Length": "0",
    "Connection": "close",
  })
  conn.end_response()
}

///|
/// Map a request path onto a bundled file: `/` is the entry document, and
/// only plain visible names (no empty, dotted, or parent segments) resolve —
/// everything else 404s without touching the filesystem.
fn static_asset_route(path : String) -> String? {
  guard path.strip_prefix("/") is Some(rest) else { return None }
  if rest.is_empty() {
    return Some("index.html")
  }
  for segment in rest.split("/") {
    if segment.is_empty() || segment.has_prefix(".") {
      return None
    }
  }
  Some(rest.to_owned())
}

///|
fn content_type(name : String) -> String {
  let extension = match name.rev_find(".") {
    Some(index) => name[index + 1:].to_owned()
    None => ""
  }
  match extension {
    "html" => "text/html; charset=utf-8"
    "js" => "text/javascript; charset=utf-8"
    "css" => "text/css; charset=utf-8"
    "json" => "application/json"
    "svg" => "image/svg+xml"
    "png" => "image/png"
    "ico" => "image/x-icon"
    "ttf" => "font/ttf"
    "woff" => "font/woff"
    "woff2" => "font/woff2"
    "txt" => "text/plain; charset=utf-8"
    _ => "application/octet-stream"
  }
}

///|
fn split_path_query(path : String) -> (String, String) {
  match path.find("?") {
    Some(index) => (path[:index].to_owned(), path[index + 1:].to_owned())
    None => (path, "")
  }
}

///|
/// A raw query parameter. Values are compared byte-for-byte — the launch
/// token is plain hex, so nothing needs percent-decoding.
fn query_param(query : String, name : String) -> String? {
  for pair in query.split("&") {
    if pair.find("=") is Some(index) && pair[:index].to_owned() == name {
      return Some(pair[index + 1:].to_owned())
    }
  }
  None
}

///|
fn ascii_lower(text : String) -> String {
  let out = StringBuilder()
  for ch in text {
    out.write_char(ch.to_ascii_lowercase())
  }
  out.to_string()
}

///|
test "static routes map the entry and reject traversal" {
  assert_eq(static_asset_route("/"), Some("index.html"))
  assert_eq(static_asset_route("/frontend.js"), Some("frontend.js"))
  assert_eq(
    static_asset_route("/fonts/GeistMono-Variable.woff2"),
    Some("fonts/GeistMono-Variable.woff2"),
  )
  assert_true(static_asset_route("/../secret") is None)
  assert_true(static_asset_route("/fonts/../../etc/passwd") is None)
  assert_true(static_asset_route("/.hidden") is None)
  assert_true(static_asset_route("//double") is None)
  assert_true(static_asset_route("no-slash") is None)
}

///|
test "websocket handshakes require the token and our own origin" {
  let token = "sesame"
  assert_true(ws_authorized("/ws?token=sesame", None, token~, port=4100))
  assert_true(
    ws_authorized(
      "/ws?token=sesame",
      Some("http://127.0.0.1:4100"),
      token~,
      port=4100,
    ),
  )
  assert_false(
    ws_authorized(
      "/ws?token=sesame",
      Some("https://evil.example"),
      token~,
      port=4100,
    ),
  )
  assert_false(
    ws_authorized(
      "/ws?token=sesame",
      Some("http://127.0.0.1:4101"),
      token~,
      port=4100,
    ),
  )
  assert_false(ws_authorized("/ws?token=wrong", None, token~, port=4100))
  assert_false(ws_authorized("/ws", None, token~, port=4100))
  assert_false(ws_authorized("/other?token=sesame", None, token~, port=4100))
}

///|
test "content types cover the bundled asset set" {
  assert_eq(content_type("index.html"), "text/html; charset=utf-8")
  assert_eq(content_type("frontend.js"), "text/javascript; charset=utf-8")
  assert_eq(content_type("viewer.css"), "text/css; charset=utf-8")
  assert_eq(content_type("codicon.ttf"), "font/ttf")
  assert_eq(content_type("fonts/GeistMono-Variable.woff2"), "font/woff2")
  assert_eq(content_type("unknown.bin"), "application/octet-stream")
}
