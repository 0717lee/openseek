// The engine-host calling core: one `bridge_request` for every frontend
// package that talks to a host, routed by channel. `Local` is the desktop
// window's injected `__MoonBit__.openseek` op; `Remote(id)` is currently a
// relay device reached over its WebSocket (docs/remote-protocol.md). The method
// names and payloads are identical either way — callers and reply decoders
// cannot tell the transports apart.

///|
priv suberror BridgeError {
  // The call left this client and something went wrong after that: a reply
  // arrived that could not be read.
  BridgeError(String)
  // The call never left: no bridge, no such method, no open socket. Raised
  // strictly before anything is written to the transport, which is what lets
  // callers treat it as "nothing landed" rather than "unknown".
  BridgeUnsent(String)
}

///|
impl Show for BridgeError with fn output(self, logger) {
  match self {
    BridgeError(message) | BridgeUnsent(message) => logger.write_string(message)
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
        raise BridgeUnsent("OpenSeek bridge unavailable")
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
          raise BridgeUnsent("OpenSeek bridge unavailable")
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
    BridgeError(message) | BridgeUnsent(message) => message
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
/// What a failed bridge call says about the command it carried. The question
/// a caller actually has is not "did this error" but "could the host have
/// acted on it", and that has three answers, not two — collapsing `Unsent`
/// into `Unknown` makes callers hedge over an outcome that is not in doubt,
/// and hedging is what leaves an optimistic local state with nothing left to
/// resolve it.
pub(all) enum BridgeFailure {
  // The host answered, and the answer was no. Nothing landed.
  Refused
  // The call never reached a transport: no injected bridge, no such method,
  // no open socket. Nothing landed, and nothing is on its way.
  Unsent
  // It went out and the answer did not come back. The host may have acted;
  // only the durable record can say.
  Unknown
}

///|
/// Classify a failed bridge call. Browser JSON-RPC errors carry a marker set
/// by the response decoder; socket close / down errors do not. In the
/// embedded proton bridge, a present method's rejected promise is the direct
/// host answer.
///
/// The `openseek_api()` test is about *this* page having an embedded host,
/// which on its own says nothing about a request that went out over a socket
/// — a proton page drives remote channels too. It is sound only because
/// `ws_request` names its own failures before they get here, so a bare
/// `@js.Error_` reaching this point came from the local path.
pub fn bridge_failure(error : Error) -> BridgeFailure {
  match error {
    BridgeUnsent(_) => Unsent
    // A reply that arrived and could not be decoded, or a socket that died
    // under a request already sent: it went out, and the answer is what is
    // lost.
    BridgeError(_) => Unknown
    @js.Error_(value) =>
      if openseek_api() is Some(_) || browser_rpc_error_is_definite(value) {
        Refused
      } else {
        Unknown
      }
    _ => Unknown
  }
}

///|
/// Whether a failed bridge call is a definitive host refusal — the two-state
/// view of `bridge_failure`, kept for the start and steer paths, whose
/// unconfirmed handling already does the conservative thing with `Unsent`.
pub fn bridge_error_is_definite(error : Error) -> Bool {
  bridge_failure(error) is Refused
}

///|
fn browser_rpc_error_is_definite(value : @js.Value) -> Bool {
  js_prop(value, "__openseek_rpc_rejection") is Some(marker) &&
  (@js.Cast::into(marker) : Bool?) is Some(true)
}
