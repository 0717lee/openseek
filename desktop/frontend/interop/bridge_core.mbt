// The engine-host calling core: one `bridge_request` for every frontend
// package that talks to a host, routed by channel. `Local` is the desktop
// window's own loopback host; `Remote(id)` is a relay device. Both are the
// same JSON-RPC WebSocket (docs/remote-protocol.md) — the method names,
// payloads, and transport are identical, so callers and reply decoders
// cannot tell the channels apart.

///|
priv suberror BridgeError {
  BridgeError(String)
}

///|
impl Show for BridgeError with fn output(self, logger) {
  match self {
    BridgeError(message) => logger.write_string(message)
  }
}

///|
/// Call one engine-host method on a channel and wait for its reply. Raises
/// when the connection is down, the call throws, or the host rejects the
/// method.
pub async fn bridge_request(
  channel : ChannelId,
  op : String,
  payload : @js.Value,
) -> @js.Value {
  ws_request(channel, op, payload)
}

///|
/// Call one host method in the page's issue order. The file-panel watcher is
/// the only current user: `watch(A)` followed by `unwatch` is desired state,
/// not two independent queries. The socket preserves issue order on the
/// wire, and the host's reader runs these two methods at the read boundary
/// rather than spawning them, so they enter the connection's actor in order.
pub async fn bridge_request_in_order(
  channel : ChannelId,
  op : String,
  payload : @js.Value,
) -> @js.Value {
  ws_request(channel, op, payload)
}

///|
/// A user-facing message for a failed bridge call, preferring the JS
/// error's `message` over its stringified form.
pub fn bridge_error_text(error : Error) -> String {
  match error {
    BridgeError(message) => message
    @js.Error_(value) =>
      if js_prop(value, "message") is Some(message) &&
        (@js.Cast::into(message) : String?) is Some(text) &&
        !text.is_empty() {
        text
      } else {
        value.to_string()
      }
    _ => "\{error}"
  }
}

///|
/// Whether a failed bridge call is a definitive host refusal. JSON-RPC
/// errors carry a marker set by the response decoder; socket close / down
/// errors do not, and neither does the `BridgeError` a request issued while
/// disconnected fails with.
pub fn bridge_error_is_definite(error : Error) -> Bool {
  match error {
    BridgeError(_) => false
    @js.Error_(value) => browser_rpc_error_is_definite(value)
    _ => false
  }
}

///|
fn browser_rpc_error_is_definite(value : @js.Value) -> Bool {
  js_prop(value, "__openseek_rpc_rejection") is Some(marker) &&
  (@js.Cast::into(marker) : Bool?) is Some(true)
}

///|
/// The op reply as JSON text for the reply decoders. A reply of
/// `undefined`/`null` (an op that returned nothing) reads as the empty
/// object; an unserializable reply reads as malformed input.
pub fn reply_json_text(reply : @js.Value) -> String {
  if reply.is_undefined() || reply.is_null() {
    return "{}"
  }
  reply.to_json_string() catch {
    _ => ""
  }
}

///|
/// Set `payload[key]` to the trimmed `value`, omitting it entirely when
/// blank — the host documents that a present field always carries
/// non-blank text.
pub fn set_trimmed(payload : @js.Object, key : String, value : String) -> Unit {
  let text = value.trim().to_owned()
  if !text.is_empty() {
    payload[key] = text
  }
}

///|
/// Attach the workspace hint to an op payload, when the conversation has one.
pub fn set_workspace(
  payload : @js.Object,
  workspace : @pathx.Absolute?,
) -> Unit {
  if workspace is Some(workspace) {
    set_trimmed(payload, "workspace", workspace.0)
  }
}
