// The in-app folder picker's own state machine, owned by the shell like
// Quick Open: the root model holds one `State?`, and every picker
// transition (open, navigate, listing replies, confirm, close) happens
// here. The shell decides when the picker may open at all and what a
// confirmed directory does — this package only reports the picked location
// back, the way the palette reports an accepted row.

///|
/// The in-app folder picker's state: the host location currently shown and
/// the rows inside it — a directory's subdirectories, or the Windows drive
/// list's drives. `loading` marks a browse in flight; a failed
/// navigation pops a toast while the previous listing stays usable.
/// `channel` owns every browse and the eventual project mutation;
/// `generation` numbers that picker's latest request. Both ride on replies,
/// so neither a superseded navigation nor a closed picker from another
/// device can replace the current listing.
///
/// Opaque outside this package: the shell holds the value but cannot read
/// into it — every transition goes through `open`, `handle`, `view`, or
/// `subscriptions`.
struct State {
  channel : @interop.ChannelId
  // The last location the host successfully listed. `None` only while the
  // initial home listing is in flight.
  location : Location?
  entries : Array[String]
  loading : Bool
  generation : Int
} derive(Eq)

///|
pub extend State with Eq::{equal, not_equal}

///|
/// Where the picker's current listing was taken: a real host directory —
/// the only thing Confirm can register — or the Windows-only virtual level
/// above the drive roots, whose rows are the drives themselves.
pub(all) enum Location {
  Directory(@common.Uri)
  DriveList
} derive(Eq)

///|
pub extend Location with Eq::{equal, not_equal}

///|
pub(all) enum Msg {
  // Browse into a directory: a subdirectory row, a breadcrumb ancestor, or
  // a path pasted while the picker is open.
  Navigate(String)
  // One location's listing came back from the host — a directory, or the
  // Windows drive list; `generation` names the browse request it answers,
  // so a stale reply is dropped.
  Loaded(
    channel~ : @interop.ChannelId,
    location~ : Location,
    entries~ : Array[String],
    generation~ : Int
  )
  // A navigation failed; the shell pops the message as a toast and the
  // previous listing stays usable.
  Failed(channel~ : @interop.ChannelId, message~ : String, generation~ : Int)
  // Register the picker's current directory and close it.
  Confirm
  Close
} derive(Eq)

///|
pub extend Msg with Eq::{equal, not_equal}

///|
/// What the shell must do about a handled message: register a confirmed
/// directory on its owning device, or surface a navigation failure as a
/// toast. Everything else stays inside the package.
pub(all) enum Outcome {
  Picked(@interop.ChannelId, @common.Uri)
  Failed(String)
} derive(Eq)

///|
pub extend Outcome with Eq::{equal, not_equal}

///|
/// Open a fresh picker against one device's host, browsing from that host's
/// home directory.
pub fn State::open(
  channel : @interop.ChannelId,
  emit : @cmd.Emit[Msg],
) -> (@cmd.Cmd, State) {
  let picker : State = {
    channel,
    location: None,
    entries: [],
    loading: true,
    generation: 1,
  }
  (browse(emit, channel, "", generation=1), picker)
}

///|
/// Fold one picker message into the state. A `Some` outcome is a directory
/// the user registered (the picker has already closed itself) or a
/// navigation failure the shell should surface as a toast.
pub fn State::handle(
  self : State,
  emit : @cmd.Emit[Msg],
  msg : Msg,
) -> (@cmd.Cmd, State?, Outcome?) {
  match msg {
    Navigate(path) => {
      let generation = self.generation + 1
      (
        browse(emit, self.channel, path, generation~),
        Some({ ..self, loading: true, generation }),
        None,
      )
    }
    Loaded(channel~, location~, entries~, generation~) =>
      // A listing for a picker the user already closed — or one answering
      // a navigation that has since been superseded — is dropped.
      if channel == self.channel && generation == self.generation {
        (
          @cmd.none,
          Some({ ..self, location: Some(location), entries, loading: false }),
          None,
        )
      } else {
        (@cmd.none, Some(self), None)
      }
    Failed(channel~, message~, generation~) =>
      // The failure pops as a toast — mainly a pasted path that names no
      // directory — while the previous listing stays usable. One answering
      // a superseded navigation stays silent: its toast would describe a
      // browse the user has already replaced.
      if channel == self.channel && generation == self.generation {
        (@cmd.none, Some({ ..self, loading: false }), Some(Failed(message)))
      } else {
        (@cmd.none, Some(self), None)
      }
    Confirm =>
      // Register the directory the host last listed — always something it
      // confirmed exists — never raw pasted text; a paste navigates (and
      // validates) first. While a navigation is in flight the shown listing
      // is stale, so Enter must wait: confirming then would attach the
      // previous directory, not the destination. The Windows drive list is
      // not a directory and cannot be registered.
      if self.location is Some(Directory(path)) && !self.loading {
        (@cmd.none, None, Some(Picked(self.channel, path)))
      } else {
        (@cmd.none, Some(self), None)
      }
    Close => (@cmd.none, None, None)
  }
}
