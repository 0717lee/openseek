// Shared helpers for talking to the page's JavaScript through rabbita's
// typed `@js` values. Together with `@dom` they are the frontend's whole
// interop surface: no frontend package embeds raw JavaScript.

///|
/// `value[key]`, with JS `undefined` and `null` both folded to `None`.
pub fn js_prop(value : @js.Value, key : String) -> @js.Value? {
  let prop : @js.Value = value.get_with_string(key)
  if prop.is_undefined() || prop.is_null() {
    None
  } else {
    Some(prop)
  }
}

///|
/// `window.innerWidth` in CSS pixels, `None` where there is no window (a
/// headless test runtime). Read once at startup to seed the narrow-layout
/// flag; later changes arrive through the resize subscription.
pub fn viewport_width() -> Int? {
  js_prop(@js.globalThis, "innerWidth").map(width => {
    let width : Double = width.cast()
    width.to_int()
  })
}

///|
/// `target.addEventListener(event_type, listener, { capture: true })`.
/// A capture-phase listener on the document sees events that do not bubble
/// (like scroll) and keeps working when a render replaces the elements the
/// events originate from.
pub fn add_capture_listener(
  target : @js.Value,
  event_type : String,
  listener : (@dom.Event) -> Unit,
) -> Unit {
  let options = @js.Object::new()
  options["capture"] = true
  let _ : @js.Value = target.apply_with_string("addEventListener", [
    @js.Value::cast_from(event_type),
    @js.Value::cast_from(listener),
    options.to_value(),
  ])
}
