// The engine-host calling core: one `bridge_request` for every frontend
// package that talks to a host, routed by channel. `Local` is the desktop
// window's injected `__MoonBit__.openseek` op; `Remote(id)` is currently a
// relay device reached over its WebSocket (docs/remote-protocol.md). The method
// names and payloads are identical either way — callers and reply decoders
// cannot tell the transports apart.

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
/// `globalThis.__MoonBit__.openseek`, once the proton bridge is injected.
pub fn openseek_api() -> @js.Value? {
  guard moonbit_bridge_root() is Some(root) else { return None }
  js_prop(root, "openseek")
}

///|
/// Call one typed Desktop command on a channel and wait for its concrete
/// reply. The command value fixes both generic types, so a caller cannot send
/// one command's payload under another command name or decode the wrong reply.
pub async fn[Payload : ToJson, Reply : @json.FromJson] bridge_request(
  channel : ChannelId,
  command : @commands.Command[Payload, Reply],
  payload : Payload,
) -> Reply {
  let op = command.name()
  let payload = @js.Value::from_json(payload.to_json())
  let reply = match channel {
    Local => {
      guard openseek_api() is Some(api) && js_prop(api, op) is Some(_) else {
        raise BridgeError("OpenSeek bridge unavailable")
      }
      js_method_promise(api, op, payload).wait()
    }
    Remote(_) => ws_request(channel, op, payload)
  }
  let json = if reply.is_undefined() || reply.is_null() {
    Json::empty_object()
  } else {
    reply.to_json() catch {
      _ => raise BridgeError("Malformed reply from {op}")
    }
  }
  @json.from_json(json) catch {
    _ => raise BridgeError("Malformed reply from {op}")
  }
}

///|
/// Keep local Proton method entry ordered even though its bridge dispatches
/// requests in separate native tasks. The per-channel lock below already
/// serializes callers; this promise tail also keeps ordering at the JS/native
/// handoff if that implementation detail changes.
extern "js" fn js_ordered_method_promise(
  target : @js.Value,
  name : String,
  payload : @js.Value,
) -> @js.Promise =
  #| (() => {
  #|   let tail = Promise.resolve();
  #|   return (target, name, payload) => {
  #|     const request = tail
  #|       .catch(() => undefined)
  #|       .then(() => target[name](payload));
  #|     tail = request.catch(() => undefined);
  #|     return request;
  #|   };
  #| })()

///|
/// One ordered-request lane per host. This transport-independent boundary is
/// what makes the contract hold for remote hosts, including older servers
/// that execute ordinary JSON-RPC requests concurrently.
let ordered_request_locks : Map[ChannelId, @async.Mutex] = Map([])

///|
fn ordered_request_lock(channel : ChannelId) -> @async.Mutex {
  match ordered_request_locks.get(channel) {
    Some(lock) => lock
    None => {
      let lock : @async.Mutex = Mutex()
      ordered_request_locks[channel] = lock
      lock
    }
  }
}

///|
/// Call one host method in the page's issue order, for callers whose requests
/// are desired state or ordered observations rather than independent queries:
/// the file-panel watcher (`watch(A)` then `unwatch`), file-stat snapshots,
/// and browser view ops (create-then-place, bounds-before-visibility).
pub async fn[Payload : ToJson, Reply : @json.FromJson] bridge_request_in_order(
  channel : ChannelId,
  command : @commands.Command[Payload, Reply],
  payload : Payload,
) -> Reply {
  let lock = ordered_request_lock(channel)
  lock.acquire()
  defer lock.release()
  let op = command.name()
  let payload = @js.Value::from_json(payload.to_json())
  let reply = match channel {
    Local => {
      guard openseek_api() is Some(api) && js_prop(api, op) is Some(_) else {
        raise BridgeError("OpenSeek bridge unavailable")
      }
      js_ordered_method_promise(api, op, payload).wait()
    }
    Remote(_) => ws_request(channel, op, payload)
  }
  let json = if reply.is_undefined() || reply.is_null() {
    Json::empty_object()
  } else {
    reply.to_json() catch {
      _ => raise BridgeError("Malformed reply from {op}")
    }
  }
  @json.from_json(json) catch {
    _ => raise BridgeError("Malformed reply from {op}")
  }
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
/// Whether a failed bridge call is a definitive host refusal. Browser
/// JSON-RPC errors carry a marker set by the response decoder; socket close /
/// down errors do not. In the embedded proton bridge, a present method's
/// rejected promise is the direct host answer, while a missing bridge is the
/// separate ambiguous `BridgeError` case.
pub fn bridge_error_is_definite(error : Error) -> Bool {
  match error {
    BridgeError(_) => false
    @js.Error_(value) =>
      openseek_api() is Some(_) || browser_rpc_error_is_definite(value)
    _ => false
  }
}

///|
fn browser_rpc_error_is_definite(value : @js.Value) -> Bool {
  js_prop(value, "__openseek_rpc_rejection") is Some(marker) &&
  (@js.Cast::into(marker) : Bool?) is Some(true)
}
