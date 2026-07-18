// Deliberate exports with no in-repo production consumer (see
// shrink_package.md): test seams, round-trip/protocol surface, and
// future-proof API kept on purpose. Each entry documents its reason.

///|
/// Whether the client has closed. A closed client never answers again — every
/// later request fails fast with `Closed` — so a pool holding one should discard
/// it and connect afresh.
pub fn Client::is_closed(self : Client) -> Bool {
  self.closed
}

///|
/// Install the handler run for each peer-initiated notification (`method`,
/// `params`). Replaces any previous handler; it runs on the reader task, so it
/// must not block on I/O.
pub fn Client::set_notification_handler(
  self : Client,
  handler : (String, Json) -> Unit,
) -> Unit {
  self.on_notification = handler
}
