// The file-editor subsystem: the editor side-panel's state and messages,
// extracted from the main frontend package so the panel owns its own
// update/view loop. The main package wraps `Msg` in one root variant and
// delegates to `update`/`sync`/`panel_view`, passing the active
// conversation's identity in as `Ctx` — this package never sees the app
// model.

///|
/// One entry of the file panel's tree: a file or directory directly inside
/// some listed directory. `path` is relative to the conversation's workspace
/// ("" being the root), the key the host's `read_directory` / `read_file` ops
/// take.
pub(all) struct FileEntry {
  name : String
  path : @pathx.Relative
  is_dir : Bool
} derive(Eq)

///|
/// A decoded `read_file` reply. Withheld files are their own cases — the
/// wording of their notices is this side's business — and only a real file
/// carries an address for path-routed ops (hover on a notice document has
/// nothing to ask about).
pub(all) enum FileContent {
  Binary
  Oversized
  // `sig` is the file's mtime signature, stat'ed by the host from the same
  // handle it read — the baseline `stat_files` results are compared against.
  Content(content~ : String, absolute~ : @pathx.Absolute, sig~ : String)
}

///|
/// Where one open tab's document stands. Content lives on the tab (not in
/// the viewer) so switching tabs redisplays instantly without a host
/// round-trip; the withheld and deleted cases keep their own notices.
pub(all) enum TabState {
  // A `read_file` is in flight (just opened, restored after a conversation
  // switch, or reloading after a disk change).
  TabLoading
  // `sig` is the loaded content's mtime signature; a differing `stat_files`
  // result means the file changed on disk. Withheld tabs carry no baseline
  // (their replies have none), so they only refresh on an explicit re-open —
  // but deletion still shows, since that compares against `""`, not a
  // baseline.
  TabLoaded(content~ : String, absolute~ : @pathx.Absolute, sig~ : String)
  TabBinary
  TabOversized
  // The file vanished from disk while open. The tab stays — its name is the
  // user's bookmark — showing a notice until the file reappears or the tab
  // is closed.
  TabDeleted
} derive(Eq)

///|
/// One open file's document record, keyed by its workspace-relative path in
/// `State.docs`. Which files are open — and in what order — is the dock
/// strip's business; this table only holds what each open file's document
/// looks like.
pub(all) struct Doc {
  name : String
  state : TabState
  // The file changed on disk while its tab was in the background; reloaded
  // on activation rather than eagerly, so a build storm costs one read.
  stale : Bool
} derive(Eq)

///|
/// One file's decoded `fs.stat_files` result: its current mtime signature,
/// absent when the file is missing.
pub(all) struct FileStat {
  path : @pathx.Relative
  sig : String?
}

///|
/// One concrete filesystem event from the host watcher. Paths are relative
/// to the conversation workspace. A rename keeps both names so the file tree
/// and any open tab at either address can be reconciled.
pub(all) enum FileChange {
  Modified(@pathx.Relative)
  Created(@pathx.Relative)
  Removed(@pathx.Relative)
  Renamed(old~ : @pathx.Relative, new~ : @pathx.Relative)
} derive(Eq)

///|
/// The exact watcher configuration most recently sent to one host connection:
/// every open tab plus the root/expanded directories whose immediate children
/// the file tree needs to keep current.
pub(all) struct WatchedPaths {
  owner : @interop.ConversationKey
  workspace : @pathx.Absolute?
  files : Array[@pathx.Relative]
  directories : Array[@pathx.Relative]
} derive(Eq)

///|
/// The workspace file index behind unified Quick Open: every
/// file under the workspace (the host walks it recursively, pruning churn
/// directories and capping the count). Requested lazily when file Quick Open
/// is first used, refreshed on `FsChanged`, and reset by a conversation switch
/// like the rest of the workspace cache.
pub(all) enum FileIndex {
  // Never requested; opening file Quick Open asks for it.
  IndexEmpty
  // The first request is in flight.
  IndexLoading
  // The first request failed. A later Quick Open retries it.
  IndexFailed
  // `truncated` set means the walk hit the host's cap, so matches may be
  // missing; Quick Open surfaces that limitation.
  IndexReady(files~ : Array[@pathx.Relative], truncated~ : Bool)
} derive(Eq)

///|
/// The file subsystem's state: a lazily-loaded file tree of the active
/// conversation's workspace and the document table behind the dock's open
/// file tabs. Keyed entirely by workspace-relative paths; `owner` records
/// which channel's conversation the cached tree and documents belong to, so
/// switching either channel or session swaps them rather than showing
/// another host's files. Strip membership, order, the active tab, and the
/// parked per-conversation strips all live in the dock package — the open
/// file list arrives through `Ctx`.
pub(all) struct State {
  owner : @interop.ConversationKey?
  // Whether the file-tree pane (the toggleable column right of the viewer)
  // is shown. A panel preference, not per-conversation state, so it
  // survives conversation switches.
  tree_open : Bool
  // The paths the host's watcher currently follows (`None` = parked). Keeping
  // the full configuration makes opening/closing a tab or expanding/collapsing
  // a directory replace the watch even when the conversation did not change.
  watching : WatchedPaths?
  // A watcher can fail after `fs.watch` has already replied. Keep that
  // failure separate from directory/file requests so a later successful
  // directory listing does not hide the loss of live updates.
  watch_error : String?
  // Directory paths the user has expanded, and those with a `read_directory`
  // in flight; plain arrays since a workspace tree is small.
  expanded : Array[@pathx.Relative]
  loading : Array[@pathx.Relative]
  // Listed directories' entries, keyed by the directory's relative path.
  children : Map[@pathx.Relative, Array[FileEntry]]
  // Each open file's document, keyed by workspace-relative path. The key set
  // mirrors the dock strip's file tabs (`Ctx.open_files`): the root update
  // adds an entry when it opens a tab and drops it when the tab closes.
  docs : Map[@pathx.Relative, Doc]
  // The directory a breadcrumb click most recently revealed, flashed in the
  // tree until `HighlightCleared` fires.
  highlighted : @pathx.Relative?
  // The workspace file list consumed by unified Quick Open.
  index : FileIndex
  // The last directory/file failure, surfaced in the panel header;
  // `None` while nothing has failed.
  error : String?
} derive(Eq)

///|
pub fn State::empty() -> State {
  {
    owner: None,
    tree_open: true,
    watching: None,
    watch_error: None,
    expanded: [],
    loading: [],
    children: Map([]),
    docs: Map([]),
    highlighted: None,
    index: IndexEmpty,
    error: None,
  }
}

///|
/// Where the file tree docks inside the editor panel: flat along the bottom
/// (Emacs-window style) or as a column on the viewer's right. A Settings
/// choice owned by the main package and passed in through `Ctx`; the two
/// layouts share one DOM order and differ only in CSS, so switching never
/// re-keys the viewer host.
pub(all) enum TreeLayout {
  BottomPanel
  RightSidebar
} derive(Eq)

///|
/// The stored wire name's inverse; an unknown value falls back to the
/// default right sidebar, so a missing key and a stale value read the same.
pub fn TreeLayout::parse(value : String) -> TreeLayout {
  match value {
    "bottom-panel" => BottomPanel
    _ => RightSidebar
  }
}

///|
pub fn TreeLayout::wire(self : TreeLayout) -> String {
  match self {
    BottomPanel => "bottom-panel"
    RightSidebar => "right-sidebar"
  }
}

///|
/// The active conversation's identity, passed in by the main package on every
/// `update`/`sync`/`panel_view` call: which conversation the panel serves, its
/// attached workspace (the hint fs ops carry), where that conversation is
/// placed, whether the app is in dark mode (drives the
/// embedded viewer's theme attribute), and the Settings choice of where the
/// file tree docks.
pub(all) struct Ctx {
  owner : @interop.ConversationKey
  workspace : @pathx.Absolute?
  // `None` while this connection has not loaded the conversation's placement.
  // Unknown and missing placements both block filesystem requests so neither
  // can be resolved against the registered project's main checkout.
  checkout : @interop.CheckoutPlacement?
  dark_mode : Bool
  tree_layout : TreeLayout
  // The app's phone-narrow layout flag. Narrow, the tree and the viewer
  // share one full-width pane (CSS shows exactly one), so opening a file
  // closes the tree — a drill-down — instead of showing both side by side.
  narrow : Bool
  // The dock's projection, recomputed by the root each dispatch: whether the
  // right panel is expanded, which files the strip holds (in strip order —
  // the stat/watch/reload sweeps run over this list), and which file tab is
  // active (`None` while no file tab is on screen).
  panel_open : Bool
  open_files : Array[@pathx.Relative]
  active_file : @pathx.Relative?
}

///|
pub(all) enum Msg {
  // A breadcrumb segment was clicked: switch back to the (always-rooted)
  // tree and reveal this directory — expanding whatever ancestors are
  // needed to show it, then scrolling to and flashing it. `""` (the leading
  // "Workspace" crumb) just returns to the plain tree with no highlight.
  RevealDirectory(@pathx.Relative)
  // A `RevealDirectory` highlight's flash delay elapsed; clears it unless a
  // newer reveal has since replaced it.
  HighlightCleared(@pathx.Relative)
  // Show or hide the file-tree pane (the column right of the viewer).
  ToggleTree
  // Expand or collapse a directory row in the file tree; the first expansion
  // lazily lists the directory through the host.
  DirToggle(@pathx.Relative)
  // Ensure the workspace-wide file index exists for unified Quick Open.
  // Loading/ready states make this idempotent; Failed retries.
  EnsureFileIndex
  // A `read_directory` reply: `owner`/`path` say which request it answers so a
  // reply that lost a conversation switch can be dropped.
  DirLoaded(
    owner~ : @interop.ConversationKey,
    path~ : @pathx.Relative,
    entries~ : Array[FileEntry]
  )
  DirFailed(
    owner~ : @interop.ConversationKey,
    path~ : @pathx.Relative,
    message~ : String
  )
  // A `list_files` reply: the workspace's files for unified Quick Open.
  // `truncated` means the host's walk stopped at its cap.
  FilesIndexed(
    owner~ : @interop.ConversationKey,
    files~ : Array[@pathx.Relative],
    truncated~ : Bool
  )
  // A `list_files` request failed or returned garbage. An initial failure
  // becomes `IndexFailed`; a failed background refresh retains a ready index.
  FileIndexFailed(owner~ : @interop.ConversationKey)
  // A file row was clicked: read it and show it in the viewer. `name` is the
  // entry's display name, kept for the viewer's title and language guess.
  FileSelected(path~ : @pathx.Relative, name~ : String)
  // A Definition/References result accepted by the Viewer's location opener.
  // Carry the captured owner so a conversation switch that races the async
  // request cannot open the target in the next workspace.
  OpenNavigationLocation(
    owner~ : @interop.ConversationKey,
    path~ : @pathx.Relative,
    range~ : @common.Range
  )
  // `file` is the decoded reply (content + address, or a withheld-file
  // case). `range`, when present, is a jumped-to symbol's one-based range,
  // revealed in the viewer once the file loads and — unless empty —
  // selected so the code it names reads highlighted. `annotation`, when
  // present (an annotation chip's jump), is the user's comment text,
  // re-shown as an editor bubble over `range`. A plain tree click leaves
  // both `None`.
  FileLoaded(
    owner~ : @interop.ConversationKey,
    path~ : @pathx.Relative,
    name~ : String,
    file~ : FileContent,
    range~ : @common.Range?,
    annotation~ : String?
  )
  FileFailed(owner~ : @interop.ConversationKey, message~ : String)
  // An `fs.watch` request rejection or an asynchronous watcher failure. The
  // owner fences both paths against a conversation switch.
  FileWatchFailed(owner~ : @interop.ConversationKey, message~ : String)
  // A new watcher sends `changes=None` once it is attached, requesting a full
  // baseline reconciliation. Later pushes contain the exact debounced events.
  // `session` is absent only for compatibility with an older host.
  FsChanged(session~ : String?, changes~ : Array[FileChange]?)
  // The conversation's agent run finished: the workspace has settled, so
  // re-check the active MoonBit file's module. The pruned watcher cannot see
  // edits outside open files and listed directories, and an agent turn
  // routinely writes files the panel never shows — the finish boundary is
  // the one cheap signal that covers them. `owner` fences a background
  // conversation's finish.
  RunSettled(owner~ : @interop.ConversationKey)
  // A `stat_files` reply: each open tab's current mtime signature (`""` =
  // the file is gone). `owner` says which conversation it answers, like
  // every other reply.
  StatsLoaded(owner~ : @interop.ConversationKey, stats~ : Array[FileStat])
  // The language server's diagnostics returned by `lsp_open`. The full owner
  // fences a reply that lost a device/session switch while the request ran.
  DiagnosticsLoaded(
    owner~ : @interop.ConversationKey,
    absolute~ : @pathx.Absolute,
    diagnostics~ : Array[@protocol.LspDiagnostic]
  )
  // A later diagnostics push from the host. The wire event is channel-scoped
  // but carries no session, so the main package first rejects background
  // channels and this handler then verifies the panel still serves it.
  DiagnosticsPublished(
    channel~ : @interop.ChannelId,
    absolute~ : @pathx.Absolute,
    diagnostics~ : Array[@protocol.LspDiagnostic]
  )
  // The user commented on a selection in the editor viewer (the
  // agent-feedback inline input). NOT handled by this package's `update`:
  // the comment becomes a chip on the main package's composer draft, so the
  // main update intercepts it there and clears the editor's bubble through
  // `remove_editor_feedback`. `resource` is the viewer model URI the comment
  // was filed under — only the key for that removal; `file` is the file as
  // the conversation names it (workspace-relative, recorded when the panel
  // opened the file). `quote` is the selected source; `feedback_id`
  // addresses the bubble to clear.
  EditorCommentAdded(
    resource~ : ModelUri,
    file~ : @pathx.Relative,
    range~ : @common.Range,
    quote~ : String,
    comment~ : String,
    feedback_id~ : String
  )
}
