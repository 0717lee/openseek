// The terminal panel's public state machine: a set of terminal tabs, each
// backed by one PTY session on the host and one emulator instance in the
// DOM (see host.mbt). Tabs are grouped by workspace — the panel shows only
// the active conversation's workspace group, and every group's shells stay
// alive while the user looks elsewhere.

///|
/// Which workspace a tab belongs to. Conversations in the same registered
/// project directory share one group; a scratch conversation's workspace
/// directory is its own, so its group is keyed by the conversation.
pub(all) enum WorkspaceKey {
  Project(String)
  Scratch(String)
} derive(Eq)

///|
pub(all) enum TabStatus {
  /// `terminal_open` is in flight.
  TabOpening
  TabRunning
  /// The child exited; the tab offers a restart.
  TabExited(code~ : Int)
  /// Opening or driving the session failed.
  TabFailed(message~ : String)
} derive(Eq)

///|
/// One terminal tab. `key` is the panel's own stable handle (the emulator
/// instance is keyed by it, and it exists before the host names the
/// session); `id` is the host's session id once `terminal_open` replies.
/// `session`/`workspace_path` are the binding the tab was opened with —
/// restarts reuse them, so a tab never migrates between workspaces.
pub(all) struct Tab {
  key : Int
  id : Int?
  workspace : WorkspaceKey
  workspace_label : String
  session : String
  workspace_path : @pathx.Absolute?
  status : TabStatus
} derive(Eq)

///|
pub(all) struct State {
  open : Bool
  next_key : Int
  tabs : Array[Tab]
  /// The remembered active tab per workspace group, as an association list
  /// (small; a workspace rarely has more than a handful of tabs).
  active : Array[(WorkspaceKey, Int)]
  /// The tab whose emulator element is currently displayed (`None` while
  /// the panel is closed). Mirrors imperative DOM state so `sync` can tell
  /// when a conversation switch must re-aim the display — the switch itself
  /// produces no terminal message.
  shown : Int?
} derive(Eq)

///|
pub fn State::empty() -> State {
  { open: false, next_key: 1, tabs: [], active: [], shown: None }
}

///|
/// The terminal package's view of the active conversation, recomputed per
/// dispatch by the main package (mirrors `@fileeditor.Ctx`).
pub(all) struct Ctx {
  session : String
  workspace : @pathx.Absolute?
  dark_mode : Bool
}

///|
/// The workspace group the active conversation belongs to.
fn workspace_key(ctx : Ctx) -> WorkspaceKey {
  match ctx.workspace {
    Some(workspace) => Project(workspace.0)
    None => Scratch(ctx.session)
  }
}

///|
/// The tabs of the active conversation's workspace group, in creation order.
fn State::visible_tabs(self : State, ctx : Ctx) -> Array[Tab] {
  let key = workspace_key(ctx)
  self.tabs.filter(tab => tab.workspace == key)
}

///|
/// The tab the panel should show for the active conversation's workspace:
/// the remembered choice while it still exists, else the group's newest tab.
fn State::active_tab(self : State, ctx : Ctx) -> Tab? {
  let visible = self.visible_tabs(ctx)
  guard !visible.is_empty() else { return None }
  let group = workspace_key(ctx)
  for entry in self.active {
    if entry.0 == group {
      for tab in visible {
        if tab.key == entry.1 {
          return Some(tab)
        }
      }
    }
  }
  visible.get(visible.length() - 1)
}

///|
fn State::tab_by_key(self : State, key : Int) -> Tab? {
  for tab in self.tabs {
    if tab.key == key {
      return Some(tab)
    }
  }
  None
}

///|
fn State::tab_by_id(self : State, id : Int) -> Tab? {
  for tab in self.tabs {
    if tab.id is Some(tab_id) && tab_id == id {
      return Some(tab)
    }
  }
  None
}

///|
/// Replace one tab (matched by key) with an updated copy.
fn State::replace_tab(self : State, updated : Tab) -> State {
  {
    ..self,
    tabs: self.tabs.map(tab => {
      if tab.key == updated.key {
        updated
      } else {
        tab
      }
    }),
  }
}

///|
/// Remember `key` as the workspace group's active tab.
fn State::remember_active(
  self : State,
  group : WorkspaceKey,
  key : Int,
) -> State {
  let active = self.active.filter(entry => entry.0 != group)
  active.push((group, key))
  { ..self, active, }
}

///|
pub(all) enum Msg {
  /// Show/hide the panel (every shell keeps running while hidden).
  ToggleTerminal
  /// Open one more terminal in the active conversation's workspace.
  NewTerminal
  TabSelected(key~ : Int)
  /// Close a tab: its shell is torn down, its emulator disposed.
  TabClosed(key~ : Int)
  /// The tab's emulator is mounted, fitted, and reports its grid size.
  EmulatorReady(key~ : Int, cols~ : Int, rows~ : Int)
  /// `terminal_open` replied for the tab.
  Opened(key~ : Int, id~ : Int)
  OpenFailed(key~ : Int, message~ : String)
  /// Keystrokes from one tab's emulator.
  UserInput(key~ : Int, data~ : String)
  /// One tab's emulator re-fit to a new grid size.
  ViewportResized(key~ : Int, cols~ : Int, rows~ : Int)
  /// `terminal_output` event: base64 of raw PTY bytes, plus their decoded
  /// length so a chunk nobody renders can still be acknowledged.
  Output(id~ : Int, data~ : String, bytes~ : Int)
  /// An emulator finished rendering a chunk; flow-control ack.
  OutputRendered(id~ : Int, bytes~ : Int)
  /// `terminal_exit` event.
  SessionExited(id~ : Int, code~ : Int)
  /// Spawn a fresh shell in an exited/failed tab (same workspace binding).
  RestartTab(key~ : Int)
}
