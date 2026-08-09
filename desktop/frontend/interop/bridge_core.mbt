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
/// requests in separate native tasks. The per-channel lane below already
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
/// what makes the contract hold for remote hosts: the wire protocol states
/// that "responses may arrive out of order relative to other requests — the
/// `id` is the correlation", and the server runs each request in its own task
/// accordingly, so ordering can only be established on the issuing side.
let ordered_request_lanes : Map[ChannelId, Lane] = Map([])

///|
fn ordered_request_lane(channel : ChannelId) -> Lane {
  match ordered_request_lanes.get(channel) {
    Some(lane) => lane
    None => {
      let lane = Lane::Lane()
      ordered_request_lanes[channel] = lane
      lane
    }
  }
}

///|
/// Call one host method in the page's issue order, for callers whose requests
/// are desired state or ordered observations rather than independent queries:
/// the file-panel watcher (`watch(A)` then `unwatch`), file-stat snapshots,
/// and browser view ops (create-then-place, bounds-before-visibility).
/// Deliberately do not put a caller-side timeout around this lane: neither the
/// Proton promise nor an older remote RPC is cancelable, so releasing the lane
/// early would allow its successor to overtake an operation still applying.
pub async fn[Payload : ToJson, Reply : @json.FromJson] bridge_request_in_order(
  channel : ChannelId,
  command : @commands.Command[Payload, Reply],
  payload : Payload,
) -> Reply {
  ordered_request_lane(channel).run(() => {
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
  })
}

///|
test "an ordered request failure releases its channel lane" {
  // No bridge is injected under test, so both calls fail at the same point.
  // The second one only reaches it if the first released the lane on its way
  // out; before, a lane still held would have parked it forever.
  let failures = []
  for _ in 0..<2 {
    @js.async_run(() => {
      ignore(
        bridge_request_in_order(
          ChannelId::Local,
          @commands.fs_unwatch,
          @protocol.EmptyPayload::NoPayload,
        ),
      ) catch {
        _ => {
          failures.push(true)
          return
        }
      }
      failures.push(false)
    })
  }
  assert_eq(failures, [true, true])
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
