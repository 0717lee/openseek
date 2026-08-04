// The desktop window's local-only operations. They are registered on the
// loopback WebSocket connection rather than in the shared API dispatcher,
// so a relay client asking for them still gets method-not-found: a remote
// browser must never make this machine launch a URL or post a banner.

///|
/// The local window's host-side powers that need the native UI runtime.
/// Injected by `main` so this package stays free of the CEF dependency:
/// `(title, body, payload)` posts one system notification whose opaque
/// payload later returns through the `notification.click` notification.
pub(all) struct LocalExtras {
  show_notification : async (String, String, String?) -> Unit
}

///|
/// The method names only a loopback connection may call.
pub const OpenExternalMethod = "shell.open_external"

///|
pub const ShowNotificationMethod = "notification.show"

///|
priv struct OpenExternalPayload {
  url : String
} derive(FromJson)

///|
priv struct OpenExternalReply {
  opened : Bool
} derive(ToJson)

///|
priv suberror LocalOpError {
  LocalOpError(String)
}

///|
impl Show for LocalOpError with fn output(self, logger) {
  match self {
    LocalOpError(message) => logger.write_string(message)
  }
}

///|
/// The frontend resolves links through `URL` before sending them, so a strict
/// lowercase allowlist is both sufficient and intentionally rejects every
/// local, app-owned, executable, or otherwise unknown scheme.
fn allowed_external_url(url : String) -> Bool {
  if url.strip_prefix("https://") is Some(rest) {
    !rest.is_empty()
  } else if url.strip_prefix("http://") is Some(rest) {
    !rest.is_empty()
  } else if url.strip_prefix("mailto:") is Some(rest) {
    !rest.is_empty()
  } else {
    false
  }
}

///|
async fn open_external(params : Json) -> Json {
  let payload : OpenExternalPayload = @json.from_json(params) catch {
    _ => raise LocalOpError("Malformed external link request")
  }
  guard allowed_external_url(payload.url) else {
    raise LocalOpError("Blocked unsupported external link")
  }
  let code = @platform.open_url(payload.url) catch {
    error if @async.is_being_cancelled() => raise error
    error => raise LocalOpError("Could not open external link: \{error}")
  }
  guard code == 0 else { raise LocalOpError("Could not open external link") }
  ToJson::to_json(OpenExternalReply::{ opened: true })
}

///|
priv struct ShowNotificationPayload {
  title : String?
  body : String
  payload : String?
} derive(FromJson)

///|
priv struct ShowNotificationReply {
  shown : Bool
} derive(ToJson)

///|
async fn show_notification(extras : LocalExtras, params : Json) -> Json {
  let payload : ShowNotificationPayload = @json.from_json(params) catch {
    _ => raise LocalOpError("Malformed notification request")
  }
  guard !payload.body.is_empty() else {
    raise LocalOpError("Notification body must not be empty")
  }
  (extras.show_notification)(
    payload.title.unwrap_or("OpenSeek"),
    payload.body,
    payload.payload,
  )
  ToJson::to_json(ShowNotificationReply::{ shown: true })
}

///|
/// Run one local-only method; `None` when the method is not local-scoped and
/// belongs to the shared dispatcher.
async fn run_local_op(
  extras : LocalExtras,
  method_ : String,
  params : Json,
) -> Json? {
  match method_ {
    OpenExternalMethod => Some(open_external(params))
    ShowNotificationMethod => Some(show_notification(extras, params))
    _ => None
  }
}

///|
test "external link policy allows browser schemes only" {
  assert_true(allowed_external_url("https://example.com/docs"))
  assert_true(allowed_external_url("http://localhost:8080/"))
  assert_true(allowed_external_url("mailto:hello@example.com"))
  assert_false(allowed_external_url("javascript:alert(1)"))
  assert_false(allowed_external_url("file:///tmp/secret"))
  assert_false(allowed_external_url("proton://app/"))
  assert_false(allowed_external_url("https://"))
}

///|
test "local-only operations are absent from the shared method catalog" {
  assert_false(
    @api.method_names().iter().any(name => name == OpenExternalMethod),
  )
  assert_false(
    @api.method_names().iter().any(name => name == ShowNotificationMethod),
  )
}
