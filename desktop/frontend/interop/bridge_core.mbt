// The engine-host bridge's calling core: locate the API object proton
// injects, call one op, and normalize failures and replies. Shared by every
// frontend package that talks to the host (the main package's engine/session
// commands, the file editor's fs ops), so it lives beside the raw JS helpers
// rather than in any one feature package.

///|
priv suberror BridgeError {
  BridgeError(String)
}

///|
/// `globalThis.__MoonBit__.openseek`, once the proton bridge is injected.
pub fn openseek_api() -> @js.Value? {
  guard moonbit_bridge_root() is Some(root) else { return None }
  js_prop(root, "openseek")
}

///|
/// Call one engine-host op with a typed payload and wait for its raw reply.
/// Raises when encoding fails, the bridge is missing, the call throws, or the
/// op rejects. Reply decoding stays separate so each caller can preserve its
/// feature-specific malformed-reply fallback.
pub async fn[P : ToJson] bridge_request(op : String, payload : P) -> @js.Value {
  guard openseek_api() is Some(api) && js_prop(api, op) is Some(_) else {
    raise BridgeError("OpenSeek bridge unavailable")
  }
  js_method_promise(api, op, @js.Value::from_json(payload.to_json())).wait()
}

///|
/// Decode one successful op reply into its shared response type. Conversion
/// failures are `None`, distinct from a rejected bridge request.
pub fn[R : FromJson] bridge_reply(reply : @js.Value) -> R? {
  let json = reply.to_json() catch { _ => return None }
  let decoded : R = @json.from_json(json) catch { _ => return None }
  Some(decoded)
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
