// Decoding of the host's `list_apps` reply: the launcher apps detected as
// installed, with their display names and (optionally) an embedded icon.

///|
/// One launcher app the host reports as installed. `icon` is a
/// `data:image/png` URL, or empty when the host could not extract one.
pub(all) struct LauncherAppItem {
  id : String
  name : String
  icon : String
}

///|
/// Map a decoded `list_apps` reply into display rows. Wire validation and
/// tolerant row decoding belong to the shared protocol package; this layer
/// only applies the launcher's display-name fallback.
pub fn apps_from_reply(
  reply : @protocol.ListAppsReply,
) -> Array[LauncherAppItem] {
  let items : Array[LauncherAppItem] = []
  for app in reply.apps {
    items.push({
      id: app.id,
      name: if app.name.trim().is_empty() {
        app.id
      } else {
        app.name
      },
      icon: app.icon,
    })
  }
  items
}
