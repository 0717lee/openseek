// The panel's message handlers and post-dispatch reconciliation, extracted
// from the main package's update loop. `update` is pure: effects go out as
// commands, and every host reply carries the conversation owner it answers so
// a reply that lost a device/session switch is dropped against `ctx`/`state`.

///|
/// Attach the viewer the first time the panel has real width, install the
/// resize-drag handle, and re-measure on every width change. Idempotent, so
/// every panel-opening path batches it in front of its own work.
pub fn mount_cmds(dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.batch([
    request_viewer_mount(dispatch),
    request_resize_handle_mount(),
    request_tree_resize_mount(),
    request_viewer_remeasure(),
  ])
}

///|
/// The baseline the Viewer quick-diff service consumes. `ReviewMissing` is an
/// intentional empty original so every working-tree line renders as added;
/// unavailable/error cases clear the gutter rather than drawing a false diff.
fn ReviewBaseline::quick_diff_original(self : ReviewBaseline) -> String? {
  match self {
    ReviewContent(content) => Some(content)
    ReviewMissing => Some("")
    ReviewLoading | ReviewBinary | ReviewOversized | ReviewFailed(_) => None
  }
}

///|
fn Doc::quick_diff_original(self : Doc) -> String? {
  match self.review {
    Some(review) => review.baseline.quick_diff_original()
    None => None
  }
}

///|
/// The review request that owns any auxiliary working-tree reload. Ordinary
/// documents carry no token; review reloads must keep the token so a later
/// changed-row click can fence their replies too.
fn Doc::review_generation(self : Doc) -> Int? {
  match self.review {
    Some(review) => Some(review.generation)
    None => None
  }
}

///|
/// The command that puts `path`'s document on screen: its content (scroll
/// restored to where the tab was left), a withheld/deleted notice, or — for
/// a document whose content is not loaded yet — a fresh read, whose
/// `FileLoaded` does the showing. A MoonBit file also re-syncs diagnostics,
/// matching what its first load did.
fn show_tab_impl(
  dispatch : @cmd.Emit[Msg],
  ctx : Ctx,
  path : @pathx.Relative,
  doc : Doc,
  reload_stale : Bool,
) -> @cmd.Cmd {
  let show = match doc.state {
    // A review-loading document always has the paired read started by
    // `open_changed_document`; activation must not create an untagged
    // duplicate that could outlive a later review generation.
    TabLoading if doc.review is Some(_) => @cmd.none
    TabLoading =>
      // Covers both "a read is already in flight" (a duplicate reply is
      // folded idempotently) and "parked since a conversation restore, never
      // read" — the read is the only way to tell the viewer has something to
      // show.
      read_file(
        dispatch,
        ctx.owner,
        path,
        doc.name,
        range=None,
        workspace=ctx.workspace,
      )
    TabLoaded(content~, absolute~, ..) => {
      let show = show_file_in_viewer(
        ctx.owner,
        ctx.workspace,
        doc.name,
        content,
        absolute~,
        relative=path,
        restore_scroll=true,
        review_original?=doc.quick_diff_original(),
      )
      if language_id(doc.name) == "moonbit" {
        @cmd.batch([show, request_diagnostics(dispatch, ctx.owner, absolute)])
      } else {
        show
      }
    }
    // A deleted change, or a transiently unreadable working file, can still
    // have a useful textual HEAD side. Show that baseline under explicit
    // review chrome; other unavailable cases use the panel notice overlay.
    TabDeleted | TabReadFailed(_) =>
      match doc.review {
        Some({ baseline: ReviewContent(content), .. }) =>
          show_file_in_viewer(
            ctx.owner,
            ctx.workspace,
            doc.name,
            content,
            relative=path,
            restore_scroll=true,
          )
        _ => clear_document()
      }
    TabBinary | TabOversized => clear_document()
  }
  // A document that went stale in the background (or was deleted and
  // reappeared) shows what it has and reloads in the same breath; the reply
  // lands with the scroll kept in place.
  if reload_stale && doc.stale && !(doc.state is TabLoading) {
    @cmd.batch([
      show,
      read_file(
        dispatch,
        ctx.owner,
        path,
        doc.name,
        review_generation?=doc.review_generation(),
        range=None,
        workspace=ctx.workspace,
      ),
    ])
  } else {
    show
  }
}

///|
fn show_tab(
  dispatch : @cmd.Emit[Msg],
  ctx : Ctx,
  path : @pathx.Relative,
  doc : Doc,
) -> @cmd.Cmd {
  show_tab_impl(dispatch, ctx, path, doc, true)
}

///|
/// Open `path`'s document — the file half of a tree click, a chip jump, or
/// a dock activation of a not-yet-open file. The dock half (which tab is in
/// the strip and active) has already happened in the root update, so
/// `ctx.active_file` names this path; `had_active` says whether a file tab
/// was on screen before the transition (gaining the first one reveals the
/// breadcrumb row, which needs a viewer remeasure). A plain re-open of an
/// already-loaded document shows what the table has, exactly like a
/// tab-strip click; everything else reads the file — so a jump's
/// `range`/`annotation` ride the reply to be revealed on arrival.
pub fn open_document(
  dispatch : @cmd.Emit[Msg],
  state : State,
  ctx : Ctx,
  path : @pathx.Relative,
  name~ : String,
  range~ : @common.Range?,
  annotation? : String,
  had_active~ : Bool,
) -> (@cmd.Cmd, State) {
  // Opening the path from Files, Quick Open, navigation, or a mention leaves
  // review mode. If the same Viewer model stays attached, the show below
  // clears its resource-keyed quick-diff baseline without replacing content.
  let state = match state.docs.get(path) {
    Some({ review: Some(_), .. }) => {
      let docs = state.docs.copy()
      let doc = docs[path]
      docs[path] = { ..doc, review: None }
      { ..state, docs, }
    }
    _ => state
  }
  // The plain-activation case must not rely on the read's reply to switch
  // the document: `FileLoaded`'s identical-content dedup assumes the reply's
  // document is the one on screen, so a re-read of an unchanged file would
  // skip the redraw and leave the previous tab's document showing. Withheld
  // and deleted documents still fall through to the read — a tree click is
  // the explicit re-open that refreshes them (see `TabState`).
  if range is None &&
    annotation is None &&
    state.docs.get(path) is Some(doc) &&
    !(doc.state is (TabBinary | TabOversized | TabReadFailed(_) | TabDeleted)) {
    let show = show_tab(dispatch, ctx, path, doc)
    // Gaining the first active tab reveals the breadcrumb row, and the
    // narrow drill-down closing the tree reveals a viewer that was last
    // measured while hidden — both need a remeasure alongside the show.
    let cmd = if !had_active || (state.tree_open && ctx.narrow) {
      @cmd.batch([show, request_viewer_remeasure()])
    } else {
      show
    }
    return (
      cmd,
      { ..state, error: None, tree_open: state.tree_open && !ctx.narrow },
    )
  }
  let docs = state.docs.copy()
  if !docs.contains(path) {
    docs[path] = { name, state: TabLoading, review: None, stale: false }
  }
  let read = read_file(
    dispatch,
    ctx.owner,
    path,
    name,
    range~,
    annotation?,
    workspace=ctx.workspace,
  )
  // Gaining the first active tab reveals the breadcrumb row, and the narrow
  // drill-down closing the tree reveals a hidden-measured viewer — either
  // way the viewer must remeasure before the reply's document lands.
  let cmd = if !had_active || (state.tree_open && ctx.narrow) {
    @cmd.batch([read, request_viewer_remeasure()])
  } else {
    read
  }
  (
    cmd,
    { ..state, docs, error: None, tree_open: state.tree_open && !ctx.narrow },
  )
}

///|
/// Open one row from Changes as a review. Existing working-tree files load
/// through the ordinary reader while HEAD loads independently; whichever
/// reply wins is parked on the same document and the late side completes the
/// Viewer in place. Deleted paths skip the guaranteed-failing filesystem read
/// and show their textual HEAD blob when it arrives.
pub fn open_changed_document(
  dispatch : @cmd.Emit[Msg],
  state : State,
  ctx : Ctx,
  change : ChangedFile,
  had_active~ : Bool,
) -> (@cmd.Cmd, State) {
  guard change.selectable() else { return (@cmd.none, state) }
  let path = change.path
  let name = basename(path)
  let generation = state.review_generation + 1
  let docs = state.docs.copy()
  let doc_state = if change.has_working_tree_file() {
    // Keep a real document on screen while both refreshes run. Besides
    // avoiding a blank/loading flash, `FileLoaded` then recognizes a reload
    // and restores the tab's scroll position. Other states need the fresh
    // read before they can become a working document.
    match docs.get(path) {
      Some({ state: TabLoaded(content~, absolute~, sig~), .. }) =>
        TabLoaded(content~, absolute~, sig~)
      _ => TabLoading
    }
  } else {
    TabDeleted
  }
  let missing_rename_source = change.kind is (ChangeRenamed | ChangeCopied) &&
    change.original_path is None
  let baseline = if missing_rename_source {
    ReviewFailed("the original path is outside this workspace")
  } else {
    ReviewLoading
  }
  let review_doc = {
    name,
    state: doc_state,
    review: Some({ generation, baseline, selected: change }),
    // A cached document can already be behind the filesystem when the row is
    // selected. Keep that fact until the tagged working-tree read settles: if
    // an ordinary open cancels this review first, `show_tab` must still issue
    // its own untagged refresh instead of blessing the cached text as current.
    stale: if change.has_working_tree_file() {
      docs.get(path).map(doc => doc.stale).unwrap_or(false)
    } else {
      false
    },
  }
  docs[path] = review_doc
  let cmds = []
  if !missing_rename_source {
    let source = change.original_path.unwrap_or(path)
    cmds.push(
      read_git_original(
        dispatch,
        ctx.owner,
        path,
        source,
        generation,
        revision=state.changes_head,
        workspace=ctx.workspace,
      ),
    )
  }
  if change.has_working_tree_file() {
    if doc_state is TabLoaded(..) {
      // Clear a previous review baseline immediately while keeping the cached
      // working document and view state; the new HEAD side fills in later.
      // The tagged read below is the sole refresh owner, so this command only
      // displays the cached document instead of scheduling a duplicate reload.
      cmds.push(show_tab_impl(dispatch, ctx, path, review_doc, false))
    }
    cmds.push(
      read_file(
        dispatch,
        ctx.owner,
        path,
        name,
        review_generation=generation,
        range=None,
        workspace=ctx.workspace,
      ),
    )
  } else {
    // Remove an earlier working document immediately; the notice covers the
    // Viewer until the HEAD side settles.
    cmds.push(clear_document())
  }
  if !had_active || (state.tree_open && ctx.narrow) {
    cmds.push(request_viewer_remeasure())
  }
  (
    @cmd.batch(cmds),
    {
      ..state,
      docs,
      review_generation: generation,
      error: None,
      tree_open: state.tree_open && !ctx.narrow,
    },
  )
}

///|
/// Find the refreshed form of the exact Changes row that opened a review.
/// Git may emit multiple rows with the same destination path, so prefer the
/// original porcelain identity, then progressively weaker *unique* matches.
/// An ambiguous result exits review mode instead of silently switching sides.
fn selected_review_change(
  files : Array[ChangedFile],
  selected : ChangedFile,
) -> ChangedFile? {
  let candidates = files.filter(change => change.path == selected.path)
  for change in candidates {
    if change == selected {
      return Some(change)
    }
  }
  let mut status_match : ChangedFile? = None
  let mut status_matches = 0
  for change in candidates {
    if change.original_path == selected.original_path &&
      change.index_status == selected.index_status &&
      change.worktree_status == selected.worktree_status {
      status_match = Some(change)
      status_matches += 1
    }
  }
  if status_matches == 1 {
    return status_match
  }
  let selected_source = if selected.kind is (ChangeRenamed | ChangeCopied) {
    selected.original_path
  } else {
    Some(selected.path)
  }
  let mut input_match : ChangedFile? = None
  let mut input_matches = 0
  for change in candidates {
    let source = if change.kind is (ChangeRenamed | ChangeCopied) {
      change.original_path
    } else {
      Some(change.path)
    }
    if source == selected_source &&
      change.has_working_tree_file() == selected.has_working_tree_file() {
      input_match = Some(change)
      input_matches += 1
    }
  }
  if input_matches == 1 {
    return input_match
  }
  let mut availability_match : ChangedFile? = None
  let mut availability_matches = 0
  for change in candidates {
    if change.has_working_tree_file() == selected.has_working_tree_file() {
      availability_match = Some(change)
      availability_matches += 1
    }
  }
  if availability_matches == 1 {
    return availability_match
  }
  if candidates.length() == 1 {
    Some(candidates[0])
  } else {
    None
  }
}

///|
/// Reconcile parked reviews only against a final changed-file snapshot. Rows
/// that disappeared (or became non-textual) leave review mode. When HEAD, the
/// rename source, or working-file availability changed, surviving rows receive
/// a new generation and fresh HEAD read. The first authoritative snapshot
/// after a missing-checkout recovery also restarts an incomplete side once so
/// a reply discarded at that boundary cannot strand the document in loading.
fn reconcile_reviews_after_changes(
  dispatch : @cmd.Emit[Msg],
  state : State,
  ctx : Ctx,
  files : Array[ChangedFile],
  head~ : String?,
  head_changed~ : Bool,
  restart_incomplete~ : Bool,
) -> (Array[@cmd.Cmd], Map[@pathx.Relative, Doc], Int) {
  let docs = state.docs.copy()
  let cmds : Array[@cmd.Cmd] = []
  let mut review_generation = state.review_generation
  for path, doc in state.docs {
    guard doc.review is Some(review) else { continue }
    let current_change = selected_review_change(files, review.selected)
    match current_change {
      None => {
        let ordinary = { ..doc, review: None }
        docs[path] = ordinary
        if ctx.active_file == Some(path) {
          cmds.push(show_tab(dispatch, ctx, path, ordinary))
        }
      }
      Some(change) if !change.selectable() => {
        let ordinary = { ..doc, review: None }
        docs[path] = ordinary
        if ctx.active_file == Some(path) {
          cmds.push(show_tab(dispatch, ctx, path, ordinary))
        }
      }
      Some(change) => {
        // Only an explicit missing-checkout recovery may invalidate a healthy
        // in-flight read without changing HEAD or row metadata. Ordinary
        // three-second polls leave slow requests alone instead of repeatedly
        // superseding their generation.
        let review_incomplete = restart_incomplete &&
          (
            doc.state is TabLoading ||
            doc.review is Some({ baseline: ReviewLoading, .. })
          )
        let review_inputs_changed = review_incomplete ||
          head_changed ||
          ({
            let previous_source = if review.selected.kind
              is (ChangeRenamed | ChangeCopied) {
              review.selected.original_path
            } else {
              Some(review.selected.path)
            }
            let source = if change.kind is (ChangeRenamed | ChangeCopied) {
              change.original_path
            } else {
              Some(change.path)
            }
            previous_source != source ||
            review.selected.has_working_tree_file() !=
            change.has_working_tree_file()
          })
        if !review_inputs_changed {
          if review.selected != change {
            docs[path] = { ..doc, review: Some({ ..review, selected: change }) }
          }
          continue
        }
        review_generation = review_generation + 1
        let generation = review_generation
        let has_working_file = change.has_working_tree_file()
        let missing_rename_source = change.kind
          is (ChangeRenamed | ChangeCopied) &&
          change.original_path is None
        let baseline = if missing_rename_source {
          ReviewFailed("the original path is outside this workspace")
        } else {
          ReviewLoading
        }
        // The same path can cross the working-file boundary when HEAD moves:
        // a partial commit can turn a modified row into a deletion, while a
        // checkout can make a formerly deleted path readable again. Keep the
        // tab state aligned with the final Git snapshot before either paired
        // reply lands.
        let refreshed_state = if !has_working_file {
          TabDeleted
        } else {
          match doc.state {
            TabDeleted => TabLoading
            state => state
          }
        }
        let refreshed = {
          ..doc,
          state: refreshed_state,
          review: Some({ generation, baseline, selected: change }),
          stale: if has_working_file {
            doc.stale
          } else {
            false
          },
        }
        docs[path] = refreshed
        if !missing_rename_source {
          let source = change.original_path.unwrap_or(path)
          cmds.push(
            read_git_original(
              dispatch,
              ctx.owner,
              path,
              source,
              generation,
              revision=head,
              workspace=ctx.workspace,
            ),
          )
        }
        if has_working_file && refreshed_state is TabLoading {
          cmds.push(
            read_file(
              dispatch,
              ctx.owner,
              path,
              doc.name,
              review_generation=generation,
              range=None,
              workspace=ctx.workspace,
            ),
          )
        } else if ctx.active_file == Some(path) {
          // Clear the old gutter immediately while the new HEAD side loads;
          // deleted previews switch back to their precise loading notice.
          cmds.push(show_tab(dispatch, ctx, path, refreshed))
        }
      }
    }
  }
  (cmds, docs, review_generation)
}

///|
/// Open (or refocus) `path`'s document for a composer chip's or transcript
/// chip's jump, after the main package has relativized the raw path and
/// opened the dock tab. Ensures the viewer is mounted, since the jump may be
/// what opens the panel.
pub fn open_file(
  dispatch : @cmd.Emit[Msg],
  state : State,
  ctx : Ctx,
  path : @pathx.Relative,
  range~ : @common.Range?,
  annotation? : String,
  had_active~ : Bool,
) -> (@cmd.Cmd, State) {
  let (cmd, state) = open_document(
    dispatch,
    state,
    ctx,
    path,
    name=basename(path),
    range~,
    annotation?,
    had_active~,
  )
  (@cmd.batch([mount_cmds(dispatch), cmd]), state)
}

///|
/// Show `path`'s document after the dock switched its active tab to it — a
/// tab-strip click. The document is expected in the table; a missing entry
/// (a stale click racing a close) is a no-op.
pub fn activate(
  dispatch : @cmd.Emit[Msg],
  state : State,
  ctx : Ctx,
  path : @pathx.Relative,
) -> (@cmd.Cmd, State) {
  guard state.docs.get(path) is Some(doc) else { return (@cmd.none, state) }
  let show = show_tab(dispatch, ctx, path, doc)
  // The narrow drill-down closing the tree reveals a viewer that was last
  // measured while hidden; it must remeasure with the show.
  let cmd = if state.tree_open && ctx.narrow {
    @cmd.batch([show, request_viewer_remeasure()])
  } else {
    show
  }
  (cmd, { ..state, error: None, tree_open: state.tree_open && !ctx.narrow })
}

///|
/// Drop `path`'s document after its dock tab closed. `next`, when the closed
/// tab owned the screen, is the file the dock promoted (`None` when the
/// strip emptied — the viewer falls back to the placeholder, and the tree is
/// forced open so the panel is never a dead pane). The closed document's
/// parked scroll is forgotten after the neighbor's show re-parks the
/// outgoing document.
pub fn close_document(
  dispatch : @cmd.Emit[Msg],
  state : State,
  ctx : Ctx,
  path : @pathx.Relative,
  next~ : @pathx.Relative?,
  was_active~ : Bool,
) -> (@cmd.Cmd, State) {
  let docs = state.docs.copy()
  docs.remove(path)
  guard was_active else { return (forget_view_state(path), { ..state, docs, }) }
  match next {
    Some(next_path) =>
      if docs.get(next_path) is Some(doc) {
        (
          @cmd.batch([
            show_tab(dispatch, ctx, next_path, doc),
            forget_view_state(path),
          ]),
          { ..state, docs, },
        )
      } else {
        (forget_view_state(path), { ..state, docs, })
      }
    // The last tab: fall back to the placeholder and force the tree open so
    // the panel is never a dead pane. Losing the active tab also hides the
    // breadcrumb row, so the viewer must remeasure.
    None =>
      (
        @cmd.batch([
          clear_document(),
          forget_view_state(path),
          request_viewer_remeasure(),
        ]),
        { ..state, docs, tree_open: true },
      )
  }
}

///|
/// The commands a panel-visibility toggle needs: the mount set always, plus
/// — when opening — a read for an active document that was restored while
/// the panel was closed and never read (it sits at `TabLoading`; opening is
/// what makes it worth showing, and a duplicate of an in-flight read folds
/// idempotently).
pub fn panel_toggle_cmds(
  dispatch : @cmd.Emit[Msg],
  state : State,
  ctx : Ctx,
  opening~ : Bool,
) -> @cmd.Cmd {
  let cmds = [mount_cmds(dispatch)]
  if opening &&
    ctx.active_file is Some(path) &&
    state.docs.get(path) is Some(doc) &&
    doc.state is TabLoading {
    cmds.push(show_tab(dispatch, ctx, path, doc))
  }
  @cmd.batch(cmds)
}

///|
/// Whether this event can change the file currently addressed by `path`.
/// Structural directory events cover every descendant; a content modification
/// applies only to the exact file returned by the watcher.
fn FileChange::touches(self : FileChange, path : @pathx.Relative) -> Bool {
  match self {
    Modified(changed) => changed == path
    Created(changed) | Removed(changed) => changed.contains(path)
    Renamed(old~, new~) => old.contains(path) || new.contains(path)
  }
}

///|
/// The directory containing `path`; a root-level entry belongs to `""`.
fn FileChange::parent(path : @pathx.Relative) -> @pathx.Relative {
  let segments = [..path.0.split("/")]
  ignore(segments.pop())
  Relative(segments.join("/"))
}

///|
/// Listed directories whose immediate rows may have changed. A created or
/// renamed destination is included too so a directory that disappeared and
/// later returned does not reuse stale cached children.
fn FileChange::relist_candidates(self : FileChange) -> Array[@pathx.Relative] {
  match self {
    Modified(_) => []
    Created(path) => [FileChange::parent(path), path]
    Removed(path) => [FileChange::parent(path)]
    Renamed(old~, new~) =>
      [FileChange::parent(old), FileChange::parent(new), new]
  }
}

///|
fn FileChange::changes_file_list(self : FileChange) -> Bool {
  !(self is Modified(_))
}

///|
/// Whether the change involves a path that feeds `moon check` — a source or
/// interface file, or a module/package manifest. Only these can move the
/// module's diagnostics.
fn FileChange::moonbit_relevant(self : FileChange) -> Bool {
  match self {
    Modified(path) | Created(path) | Removed(path) => moonbit_check_input(path)
    Renamed(old~, new~) => moonbit_check_input(old) || moonbit_check_input(new)
  }
}

///|
/// The diagnostics request for the active file when it is a loaded MoonBit
/// document, or `None` when it is anything else — the shared trigger behind
/// the stats, watcher, and run-finish re-check paths.
fn active_moonbit_diagnostics(
  dispatch : @cmd.Emit[Msg],
  owner : @interop.ConversationKey,
  docs : Map[@pathx.Relative, Doc],
  active : @pathx.Relative?,
) -> @cmd.Cmd? {
  guard active is Some(active) &&
    docs.get(active) is Some({ name, state: TabLoaded(absolute~, ..), .. }) &&
    language_id(name) == "moonbit" else {
    return None
  }
  Some(request_diagnostics(dispatch, owner, absolute))
}

///|
fn moonbit_check_input(path : @pathx.Relative) -> Bool {
  let text = path.0
  if text.has_suffix(".mbt") ||
    text.has_suffix(".mbti") ||
    text.has_suffix(".mbt.md") {
    return true
  }
  for
    name in [
      "moon.pkg", "moon.mod", "moon.work", "moon.pkg.json", "moon.mod.json",
    ] {
    if text == name || text.has_suffix("/" + name) {
      return true
    }
  }
  false
}

///|
/// Reconcile the host's workspace watcher with what the panel and Quick Open
/// need: follow the active session while the file body is visible, tabs remain
/// open, or a workspace file index is live. Wraps every `sync` exit so the
/// bookkeeping cannot be missed.
fn State::watched_paths(self : State, ctx : Ctx) -> WatchedPaths? {
  let index_live = self.index is IndexLoading || self.index is IndexReady(..)
  if ctx.checkout is None ||
    ctx.checkout is Some(@interop.MissingWorktree(_)) ||
    (!ctx.panel_open && ctx.open_files.is_empty() && !index_live) ||
    ctx.owner.session.is_empty() {
    return None
  }
  let files = ctx.open_files.copy()
  files.sort_by((left, right) => left.0.lexical_compare(right.0))
  let directories : Array[@pathx.Relative] = []
  if ctx.panel_open || index_live {
    directories.push(@pathx.Relative::root())
    for directory in self.expanded {
      if !directories.contains(directory) {
        directories.push(directory)
      }
    }
    directories.sort_by((left, right) => left.0.lexical_compare(right.0))
  }
  Some({ owner: ctx.owner, workspace: ctx.workspace, files, directories })
}

///|
fn with_watch(
  dispatch : @cmd.Emit[Msg],
  state : State,
  ctx : Ctx,
  cmd : @cmd.Cmd,
) -> (State, @cmd.Cmd) {
  let want = state.watched_paths(ctx)
  if state.watching == want {
    (state, cmd)
  } else {
    let commands = [cmd]
    // A watcher is host-local. Moving across channels must explicitly retire
    // the old host; placing a new watch on another socket cannot replace it.
    if state.watching is Some(current) &&
      (
        want is None ||
        (want is Some(next) && current.owner.channel != next.owner.channel)
      ) {
      commands.push(
        watch_workspace(dispatch, channel=current.owner.channel, None),
      )
    }
    if want is Some(next) {
      commands.push(
        watch_workspace(dispatch, channel=next.owner.channel, Some(next)),
      )
    }
    ({ ..state, watching: want, watch_error: None }, @cmd.batch(commands))
  }
}

///|
const ChangesPollDelayMilliseconds = 3000

///|
fn explorer_visible(state : State, ctx : Ctx) -> Bool {
  ctx.panel_open && (state.tree_open || ctx.active_file is None)
}

///|
fn changes_visible(state : State, ctx : Ctx) -> Bool {
  explorer_visible(state, ctx) && state.explorer_mode is ExplorerChanges
}

///|
/// A hidden explorer normally parks its Git inventory, but an open review is
/// still rendering against that inventory's HEAD identity. Keep the low-rate
/// refresh alive until every reviewed document is closed or ordinarily
/// reopened.
fn changes_live(state : State, ctx : Ctx) -> Bool {
  if changes_visible(state, ctx) {
    return true
  }
  for _, doc in state.docs {
    if doc.review is Some(_) {
      return true
    }
  }
  false
}

///|
fn changes_poll_after_settle(
  dispatch : @cmd.Emit[Msg],
  owner : @interop.ConversationKey,
  generation : Int,
) -> @cmd.Cmd {
  @cmd.delay(
    dispatch(ChangesPollDue(owner~, generation~)),
    ChangesPollDelayMilliseconds,
  )
}

///|
/// Start the first changed-file request or refresh an existing snapshot.
/// `refresh_again` latches a watcher/run signal that arrives while a request
/// is in flight. Its reply starts one follow-up request, so bursts coalesce
/// without losing the final workspace state.
fn refresh_changes(
  dispatch : @cmd.Emit[Msg],
  state : State,
  ctx : Ctx,
) -> (@cmd.Cmd, State) {
  guard state.owner == Some(ctx.owner) && !ctx.owner.session.is_empty() else {
    return (@cmd.none, state)
  }
  match state.changes {
    ChangeListLoading(refresh_again~) =>
      if refresh_again {
        (@cmd.none, state)
      } else {
        (@cmd.none, { ..state, changes: ChangeListLoading(refresh_again=true) })
      }
    ChangeListReady(repository~, files~, refreshing~, refresh_again~) =>
      if refreshing {
        if refresh_again {
          (@cmd.none, state)
        } else {
          (
            @cmd.none,
            {
              ..state,
              changes: ChangeListReady(
                repository~,
                files~,
                refreshing~,
                refresh_again=true,
              ),
            },
          )
        }
      } else {
        let generation = state.changes_generation + 1
        (
          list_changes(dispatch, ctx.owner, generation, workspace=ctx.workspace),
          {
            ..state,
            changes_generation: generation,
            changes: ChangeListReady(
              repository~,
              files~,
              refreshing=true,
              refresh_again=false,
            ),
          },
        )
      }
    ChangeListIdle | ChangeListFailed(_) => {
      let generation = state.changes_generation + 1
      (
        list_changes(dispatch, ctx.owner, generation, workspace=ctx.workspace),
        {
          ..state,
          changes: ChangeListLoading(refresh_again=false),
          changes_generation: generation,
        },
      )
    }
  }
}

///|
/// Reconcile the file subsystem with the active conversation after every
/// message: rebuild the document table and drop the tree cache when the
/// conversation changed (the dock parks/restores strip identities; this side
/// re-seeds documents from the fresh `Ctx` projection), list the workspace
/// root once its path is known, and keep the host's file watcher pointed at
/// the right workspace. The main update runs this post-dispatch — after the
/// dock's own sync, so the projection is already the new conversation's.
/// The re-root happens whether the panel is open or closed — hidden
/// documents and the watcher must always agree on the session — while
/// listing the tree waits for an open panel. A no-op unless something is
/// actually due, so it never re-fires while a request is in flight or the
/// tree is already current.
pub fn sync(
  dispatch : @cmd.Emit[Msg],
  state : State,
  ctx : Ctx,
) -> (State, @cmd.Cmd) {
  // When the active conversation changes, drop the cached tree *and* the
  // viewer's open document — the viewer is imperative state outside the
  // model, so it would otherwise keep showing the previous conversation's
  // file. The dock has already parked the outgoing strip and restored this
  // conversation's; the document table is rebuilt from the projection —
  // identities only, every entry `TabLoading` until a read lands. This runs
  // even while the panel is closed: `with_watch` follows `ctx.owner`
  // whenever open files remain, so leaving the documents rooted in the
  // previous conversation would have the next fs_changed stat their paths
  // against the new conversation's workspace — marking hidden documents
  // deleted/stale for files that never moved.
  let (state, reroot_cmd) = if state.owner == Some(ctx.owner) {
    (state, @cmd.none)
  } else {
    let docs : Map[@pathx.Relative, Doc] = Map([])
    for path in ctx.open_files {
      docs[path] = {
        name: basename(path),
        state: TabState::TabLoading,
        review: None,
        stale: false,
      }
    }
    let cmds = [clear_viewer()]
    // A hidden panel's restored active document is not worth a read yet; it
    // stays TabLoading and the panel-open toggle reads it on reopen.
    if ctx.panel_open && ctx.active_file is Some(path) && docs.contains(path) {
      cmds.push(
        read_file(
          dispatch,
          ctx.owner,
          path,
          basename(path),
          range=None,
          workspace=ctx.workspace,
        ),
      )
    }
    (
      {
        ..State::empty(),
        owner: Some(ctx.owner),
        tree_open: state.tree_open,
        explorer_mode: state.explorer_mode,
        // Request tokens must outlive the per-conversation cache. Resetting
        // here would let a late A reply collide after switching A→B→A.
        changes_generation: state.changes_generation,
        review_generation: state.review_generation,
        review_recovery_pending: false,
        // Preserve the last host configuration long enough for `with_watch`
        // to retire or replace it on the way out.
        watching: state.watching,
        docs,
      },
      @cmd.batch(cmds),
    )
  }
  let checkout_ready = !(ctx.checkout is None ||
    ctx.checkout is Some(@interop.MissingWorktree(_)))
  // A checkout can disappear while a Git request is in flight. The parked
  // update path correctly refuses its late host reply; clear the in-flight
  // bit here as well so restoring the same owner starts a fresh generation
  // instead of leaving Changes wedged in Loading/refreshing forever.
  let state = if checkout_ready {
    state
  } else {
    let state = { ..state, review_recovery_pending: true }
    match state.changes {
      ChangeListLoading(_) => { ..state, changes: ChangeListIdle }
      ChangeListReady(repository~, files~, refreshing=true, ..) =>
        {
          ..state,
          changes: ChangeListReady(
            repository~,
            files~,
            refreshing=false,
            refresh_again=false,
          ),
        }
      _ => state
    }
  }
  // A hidden explorer can miss nested edits even when Quick Open keeps its
  // shallow root-directory watch alive. The actual hide/show transition
  // therefore invalidates a ready Changes snapshot; watcher ownership and
  // workspace gaps cover the remaining reroot cases.
  let explorer_is_visible = explorer_visible(state, ctx)
  let explorer_reopened = explorer_is_visible && !state.explorer_was_visible
  let changes_are_live = changes_live(state, ctx)
  let changes_may_be_stale = (explorer_is_visible || changes_are_live) &&
    (match state.watching {
      Some(watching) =>
        explorer_reopened ||
        watching.owner != ctx.owner ||
        watching.workspace != ctx.workspace ||
        !watching.directories.contains(@pathx.Relative::root())
      None => true
    })
  let state = { ..state, explorer_was_visible: explorer_is_visible }
  // The mode selection survives re-rooting, but its inventory does not. Load
  // it when Changes is visible, and refresh a ready snapshot when reopening
  // after its root watch was parked. Failed requests only retry on an explicit
  // selection or a settled run, not on every unrelated sync pass.
  let (changes_cmd, state) = if checkout_ready &&
    changes_are_live &&
    (
      state.changes is ChangeListIdle ||
      (
        changes_may_be_stale &&
        (
          state.changes is ChangeListLoading(_) ||
          state.changes is ChangeListReady(..)
        )
      )
    ) {
    refresh_changes(dispatch, state, ctx)
  } else {
    (@cmd.none, state)
  }
  let pending_cmd = @cmd.batch([reroot_cmd, changes_cmd])
  // A closed panel re-roots (above) and keeps the watcher placed, but the
  // tree itself can wait for the reopen.
  guard ctx.panel_open else {
    return with_watch(dispatch, state, ctx, pending_cmd)
  }
  // Load as soon as there is a conversation: the workspace directory is a pure
  // function of the session id, so the host can list it without waiting for a
  // run to report `cwd` (it reports an empty workspace until the first turn
  // creates the directory).
  if ctx.owner.session.is_empty() ||
    state.children.contains("") ||
    state.loading.contains("") {
    return with_watch(dispatch, state, ctx, pending_cmd)
  }
  let loading = state.loading.copy()
  loading.push("")
  with_watch(
    dispatch,
    { ..state, loading, },
    ctx,
    @cmd.batch([
      pending_cmd,
      read_directory(
        dispatch,
        ctx.owner,
        @pathx.Relative::root(),
        workspace=ctx.workspace,
      ),
    ]),
  )
}

///|
pub fn update(
  dispatch : @cmd.Emit[Msg],
  msg : Msg,
  state : State,
  ctx : Ctx,
) -> (@cmd.Cmd, State) {
  // `sync` parks the old owner while placement is unresolved or its checkout
  // is missing. Refuse every file-editor action in the meantime: even stale
  // controls must not send an empty session through the host, where it could
  // otherwise mean the registered project's main checkout.
  if ctx.checkout is None || ctx.checkout is Some(@interop.MissingWorktree(_)) {
    // The explorer selection is a local panel preference and remains useful
    // while placement is broken; only the host-backed refresh must wait.
    return match msg {
      ExplorerModeSelected(mode) =>
        (@cmd.none, { ..state, explorer_mode: mode })
      _ => (@cmd.none, state)
    }
  }
  match msg {
    ToggleTree => {
      // The docked panel takes its height from the viewer, and the viewer
      // cannot see a CSS change on its own.
      let opening = !state.tree_open
      (request_viewer_remeasure(), { ..state, tree_open: opening })
    }
    ExplorerModeSelected(mode) => {
      let already_selected = state.explorer_mode == mode
      let selected = { ..state, explorer_mode: mode }
      match mode {
        ExplorerFiles => (@cmd.none, selected)
        ExplorerChanges =>
          if already_selected ||
            selected.changes is ChangeListIdle ||
            selected.changes is ChangeListFailed(_) {
            // Clicking the already-selected Changes tab is a manual refresh.
            // The first visit also has to obtain an inventory. Moving focus
            // back to a ready Changes tab keeps its watcher-fed snapshot and
            // lets the normal fallback poll catch index-only changes.
            refresh_changes(dispatch, selected, ctx)
          } else {
            match selected.changes {
              ChangeListReady(repository=true, refreshing=false, ..) =>
                (
                  changes_poll_after_settle(
                    dispatch,
                    ctx.owner,
                    selected.changes_generation,
                  ),
                  selected,
                )
              _ => (@cmd.none, selected)
            }
          }
      }
    }
    RevealDirectory(path) =>
      if path.is_root() {
        (
          @cmd.none,
          {
            ..state,
            tree_open: true,
            explorer_mode: ExplorerFiles,
            highlighted: None,
          },
        )
      } else {
        let expanded = state.expanded.copy()
        let loading = state.loading.copy()
        let cmds = []
        for ancestor in ancestor_paths(path) {
          if !expanded.contains(ancestor) {
            expanded.push(ancestor)
          }
          if !state.children.contains(ancestor) && !loading.contains(ancestor) {
            loading.push(ancestor)
            cmds.push(
              read_directory(
                dispatch,
                ctx.owner,
                ancestor,
                workspace=ctx.workspace,
              ),
            )
          }
        }
        cmds.push(reveal_row_after_render(path))
        cmds.push(@cmd.delay(dispatch(HighlightCleared(path)), 1500))
        (
          @cmd.batch(cmds),
          {
            ..state,
            tree_open: true,
            explorer_mode: ExplorerFiles,
            expanded,
            loading,
            highlighted: Some(path),
          },
        )
      }
    HighlightCleared(path) =>
      if state.highlighted == Some(path) {
        (@cmd.none, { ..state, highlighted: None })
      } else {
        (@cmd.none, state)
      }
    DirToggle(path) =>
      if state.expanded.contains(path) {
        (
          @cmd.none,
          { ..state, expanded: state.expanded.filter(entry => entry != path) },
        )
      } else {
        let expanded = state.expanded.copy()
        expanded.push(path)
        // A directory listed once stays cached, so re-expanding is instant.
        if state.children.contains(path) || state.loading.contains(path) {
          (@cmd.none, { ..state, expanded, })
        } else {
          let loading = state.loading.copy()
          loading.push(path)
          (
            read_directory(dispatch, ctx.owner, path, workspace=ctx.workspace),
            { ..state, expanded, loading },
          )
        }
      }
    EnsureFileIndex =>
      if state.owner != Some(ctx.owner) {
        (@cmd.none, state)
      } else if state.index is IndexEmpty || state.index is IndexFailed {
        (
          list_files(dispatch, ctx.owner, workspace=ctx.workspace),
          { ..state, index: IndexLoading },
        )
      } else {
        (@cmd.none, state)
      }
    DirLoaded(owner~, path~, entries~) =>
      // Drop a reply whose conversation is no longer the panel's.
      if state.owner != Some(owner) {
        (@cmd.none, state)
      } else {
        let children = state.children.copy()
        children[path] = entries
        // A pending highlight's target row may only now exist in the DOM —
        // this directory could be one of the ancestors `RevealDirectory` had
        // to list first (e.g. reached via a mention jump, which never
        // touched `expanded`/`children` itself).
        let reveal_cmd = match state.highlighted {
          Some(target) if ancestor_paths(target).contains(path) =>
            reveal_row_after_render(target)
          _ => @cmd.none
        }
        (
          reveal_cmd,
          {
            ..state,
            children,
            loading: state.loading.filter(entry => entry != path),
            error: None,
          },
        )
      }
    DirFailed(owner~, path~, message~) =>
      if state.owner != Some(owner) {
        (@cmd.none, state)
      } else {
        (
          @cmd.none,
          {
            ..state,
            loading: state.loading.filter(entry => entry != path),
            error: Some(message),
          },
        )
      }
    FilesIndexed(owner~, files~, truncated~) =>
      if state.owner != Some(owner) {
        (@cmd.none, state)
      } else {
        (@cmd.none, { ..state, index: IndexReady(files~, truncated~) })
      }
    FileIndexFailed(owner~) =>
      // Only a failed first fetch records a retryable failure; a failed refresh
      // keeps serving the index it already has.
      if state.owner != Some(owner) || !(state.index is IndexLoading) {
        (@cmd.none, state)
      } else {
        (@cmd.none, { ..state, index: IndexFailed })
      }
    ChangesPollDue(owner~, generation~) =>
      if state.owner == Some(owner) &&
        state.changes_generation == generation &&
        changes_live(state, ctx) &&
        state.changes is ChangeListReady(repository=true, refreshing=false, ..) {
        refresh_changes(dispatch, state, ctx)
      } else {
        (@cmd.none, state)
      }
    ChangesLoaded(owner~, generation~, repository~, head~, files~) =>
      if state.owner != Some(owner) || state.changes_generation != generation {
        (@cmd.none, state)
      } else {
        let refresh_again = match state.changes {
          ChangeListLoading(refresh_again~) => refresh_again
          ChangeListReady(refreshing=true, refresh_again~, ..) => refresh_again
          // The matching generation has already settled. Ignore a duplicate
          // callback instead of replacing the current inventory.
          _ => return (@cmd.none, state)
        }
        let previous_files = match state.changes {
          ChangeListReady(files~, ..) => files
          _ => []
        }
        // A watcher/run signal may have latched while this request was in
        // flight, then the user hid the explorer before its reply. Reopening
        // performs a fresh full refresh, so do not spend the latch off-screen.
        let follow_up = refresh_again &&
          (explorer_visible(state, ctx) || changes_live(state, ctx))
        let next_generation = if follow_up {
          generation + 1
        } else {
          generation
        }
        // An intermediate coalesced snapshot is not authoritative: a path can
        // disappear briefly and return in the already-scheduled follow-up. On
        // the final reply, clear vanished reviews and refresh every surviving
        // baseline when the host reports a different HEAD identity.
        let head_changed = state.changes_head_known &&
          state.changes_head != head
        let (review_cmds, docs, review_generation) = if follow_up {
          ([], state.docs, state.review_generation)
        } else {
          reconcile_reviews_after_changes(
            dispatch,
            state,
            ctx,
            files,
            head~,
            head_changed~,
            restart_incomplete=state.review_recovery_pending,
          )
        }
        let settle = if follow_up {
          list_changes(
            dispatch,
            owner,
            next_generation,
            workspace=ctx.workspace,
          )
        } else if repository && changes_live(state, ctx) {
          changes_poll_after_settle(dispatch, owner, generation)
        } else {
          @cmd.none
        }
        review_cmds.push(settle)
        (
          @cmd.batch(review_cmds),
          {
            ..state,
            docs,
            changes_head: if follow_up {
              state.changes_head
            } else {
              head
            },
            changes_head_known: if follow_up {
              state.changes_head_known
            } else {
              true
            },
            changes_generation: next_generation,
            review_generation,
            review_recovery_pending: if follow_up {
              state.review_recovery_pending
            } else {
              false
            },
            changes: ChangeListReady(
              repository~,
              files=if follow_up { previous_files } else { files },
              refreshing=follow_up,
              refresh_again=false,
            ),
          },
        )
      }
    ChangesFailed(owner~, generation~, message~) =>
      if state.owner != Some(owner) || state.changes_generation != generation {
        (@cmd.none, state)
      } else {
        match state.changes {
          // An event arrived while the initial request was in flight. Give it
          // one final attempt before surfacing the failure, unless every
          // consumer hid meanwhile (reopening starts a fresh request).
          ChangeListLoading(refresh_again=true) =>
            if explorer_visible(state, ctx) || changes_live(state, ctx) {
              let next_generation = generation + 1
              (
                list_changes(
                  dispatch,
                  owner,
                  next_generation,
                  workspace=ctx.workspace,
                ),
                {
                  ..state,
                  changes: ChangeListLoading(refresh_again=false),
                  changes_generation: next_generation,
                },
              )
            } else {
              (@cmd.none, { ..state, changes: ChangeListIdle })
            }
          // A background refresh failure leaves the last usable inventory on
          // screen. If an event arrived meanwhile, spend its one coalesced
          // retry before clearing the in-flight bit.
          ChangeListReady(repository~, files~, refreshing=true, refresh_again~) =>
            if refresh_again &&
              (explorer_visible(state, ctx) || changes_live(state, ctx)) {
              let next_generation = generation + 1
              (
                list_changes(
                  dispatch,
                  owner,
                  next_generation,
                  workspace=ctx.workspace,
                ),
                {
                  ..state,
                  changes_generation: next_generation,
                  changes: ChangeListReady(
                    repository~,
                    files~,
                    refreshing=true,
                    refresh_again=false,
                  ),
                },
              )
            } else {
              (
                if repository && changes_live(state, ctx) {
                  // The failed request consumed the previous timer. Keep the
                  // low-frequency fallback alive after a transient bridge/Git
                  // error while retaining the last usable snapshot.
                  changes_poll_after_settle(dispatch, owner, generation)
                } else {
                  @cmd.none
                },
                {
                  ..state,
                  changes: ChangeListReady(
                    repository~,
                    files~,
                    refreshing=false,
                    refresh_again=false,
                  ),
                },
              )
            }
          // A failure from an already superseded request cannot invalidate a
          // usable snapshot.
          ChangeListReady(..) => (@cmd.none, state)
          ChangeListLoading(refresh_again=false) =>
            if explorer_visible(state, ctx) {
              (@cmd.none, { ..state, changes: ChangeListFailed(message) })
            } else {
              // The error is off-screen and reopening has a stronger fresh
              // signal than this failed snapshot; return to Idle so sync
              // starts that request instead of surfacing a stale failure.
              (@cmd.none, { ..state, changes: ChangeListIdle })
            }
          // An Idle/Failed state has no active request. This can be a late
          // same-owner reply after an A→B→A re-root whose generation has not
          // yet advanced because Changes is hidden; ignore it.
          _ => (@cmd.none, state)
        }
      }
    // Owned by the main package's update: which dock tab a tree click opens
    // is the strip's business, so the root intercepts this (the
    // `EditorCommentAdded` pattern), opens/activates the dock tab, and calls
    // `open_document`. Reaching this arm means the root didn't intercept it;
    // changing nothing is the safe answer.
    FileSelected(..) => (@cmd.none, state)
    // Intercepted by the root so the dock can open/activate the file tab
    // before this package starts the paired working-tree + HEAD reads.
    ChangedFileSelected(_) => (@cmd.none, state)
    // Intercepted by the root for the same reason: a navigation jump opens
    // a dock tab before the document loads.
    OpenNavigationLocation(..) => (@cmd.none, state)
    GitOriginalLoaded(owner~, path~, generation~, original~) => {
      guard state.owner == Some(owner) &&
        state.docs.get(path) is Some(doc) &&
        doc.review is Some(current_review) &&
        current_review.generation == generation &&
        current_review.baseline is ReviewLoading else {
        return (@cmd.none, state)
      }
      let review = match original {
        @protocol.OriginalContent(content) => ReviewContent(content)
        @protocol.Missing => ReviewMissing
        @protocol.BinaryOriginal => ReviewBinary
        @protocol.OversizedOriginal => ReviewOversized
      }
      let docs = state.docs.copy()
      let next_doc = {
        ..doc,
        review: Some({ ..current_review, baseline: review }),
      }
      docs[path] = next_doc
      // A working-tree read may still be in flight. It will consume the
      // parked baseline when `FileLoaded` arrives; every settled document can
      // update immediately (including a deleted-file HEAD preview).
      let cmd = if ctx.active_file == Some(path) &&
        !(next_doc.state is TabLoading) {
        show_tab(dispatch, ctx, path, next_doc)
      } else {
        @cmd.none
      }
      (cmd, { ..state, docs, })
    }
    GitOriginalFailed(owner~, path~, generation~, message~) => {
      guard state.owner == Some(owner) &&
        state.docs.get(path) is Some(doc) &&
        doc.review is Some(current_review) &&
        current_review.generation == generation &&
        current_review.baseline is ReviewLoading else {
        return (@cmd.none, state)
      }
      let docs = state.docs.copy()
      let next_doc = {
        ..doc,
        review: Some({ ..current_review, baseline: ReviewFailed(message) }),
      }
      docs[path] = next_doc
      let cmd = if ctx.active_file == Some(path) &&
        !(next_doc.state is TabLoading) {
        show_tab(dispatch, ctx, path, next_doc)
      } else {
        @cmd.none
      }
      (cmd, { ..state, docs, })
    }
    FileLoaded(
      owner~,
      path~,
      name~,
      file~,
      review_generation~,
      range~,
      annotation~
    ) =>
      // A stale read — the conversation switched, or the tab was closed
      // while the read was in flight — must not resurrect state.
      if state.owner != Some(owner) {
        (@cmd.none, state)
      } else if state.docs.get(path) is Some(doc) {
        // A repeated changed-row click starts a new working-tree read as well
        // as a new HEAD read. Fence the older working reply against the
        // generation still parked on this document. An untagged ordinary read
        // is accepted only when no review has since claimed the document.
        if review_generation is Some(generation) &&
          !(doc.review is Some({ generation: current, .. }) &&
          current == generation) {
          return (@cmd.none, state)
        }
        // An ordinary read may already have been in flight when the user
        // clicked Changes. It has no review token and must not overwrite the
        // paired working snapshot or inherit the newly-fetched HEAD baseline.
        if review_generation is None && doc.review is Some(_) {
          return (@cmd.none, state)
        }
        let previous = doc.state
        let doc_state = match file {
          Content(content~, absolute~, sig~) =>
            TabState::TabLoaded(content~, absolute~, sig~)
          Binary => TabBinary
          Oversized => TabOversized
        }
        let docs = state.docs.copy()
        docs[path] = {
          name,
          state: doc_state,
          review: doc.review,
          stale: false,
        }
        // Only the tab on screen touches the viewer; a background load just
        // settles into its tab for the next activation. No content
        // comparison happens here: whether anything actually needs redrawing
        // is the show command's call, made against what the viewer really
        // displays (see `show_file_in_viewer`) — this side would only be
        // guessing from the tab cache.
        let cmd = if ctx.active_file == Some(path) {
          match file {
            // A real MoonBit file also gets a diagnostics request: the host
            // runs `moon check` over the file's module and returns its
            // current diagnostics, and future re-analysis arrives as
            // `diagnostics` events. Other files have nothing behind
            // `lsp_open` — moon has no diagnostics for a README or JSON file
            // — so only the viewer shows.
            Content(content~, absolute~, ..) => {
              let show = show_file_in_viewer(
                ctx.owner,
                ctx.workspace,
                name,
                content,
                absolute~,
                relative=path,
                range~,
                annotation?,
                // A reload of a document already on screen keeps the reading
                // position; only a genuinely fresh document opens at the top.
                restore_scroll=previous is TabLoaded(..),
                review_original?=doc.quick_diff_original(),
              )
              if language_id(name) == "moonbit" {
                @cmd.batch([
                  show,
                  request_diagnostics(dispatch, ctx.owner, absolute),
                ])
              } else {
                show
              }
            }
            // The notice overlay (rendered from the tab's new state) covers
            // the viewer; drop whatever document it was showing.
            Binary | Oversized => clear_document()
          }
        } else {
          @cmd.none
        }
        (cmd, { ..state, docs, })
      } else {
        (@cmd.none, state)
      }
    RunSettled(owner~) =>
      if state.owner == Some(owner) {
        let diagnostics = match
          active_moonbit_diagnostics(
            dispatch,
            owner,
            state.docs,
            ctx.active_file,
          ) {
          Some(recheck) => recheck
          None => @cmd.none
        }
        // While the explorer is on-screen—or a review still consumes its HEAD
        // baseline—keep the inventory current even when the user is looking
        // at Files, including retrying a previous failure. An idle Changes
        // tab also loads at this workspace-settled boundary.
        let (changes_cmd, next) = if (
            explorer_visible(state, ctx) || changes_live(state, ctx)
          ) &&
          (
            !(state.changes is ChangeListIdle) ||
            state.explorer_mode is ExplorerChanges
          ) {
          refresh_changes(dispatch, state, ctx)
        } else {
          (@cmd.none, state)
        }
        (@cmd.batch([diagnostics, changes_cmd]), next)
      } else {
        (@cmd.none, state)
      }
    FsChanged(session~, changes~) =>
      if state.owner is Some(owner) &&
        (session is None || session == Some(owner.session)) {
        // A baseline checks the whole selection after watcher replacement.
        // Concrete batches stat only affected open files (the dock strip's
        // projection) and re-list only directories whose immediate children
        // changed.
        let cmds = []
        let stat_paths : Array[@pathx.Relative] = []
        let relist : Array[@pathx.Relative] = []
        let mut refresh_index = false
        let mut moonbit_changed = false
        if changes is Some(changes) {
          for change in changes {
            if change.moonbit_relevant() {
              moonbit_changed = true
            }
            for path in ctx.open_files {
              if change.touches(path) && !stat_paths.contains(path) {
                stat_paths.push(path)
              }
            }
            for directory in change.relist_candidates() {
              if !relist.contains(directory) &&
                state.children.contains(directory) &&
                (directory.is_root() || state.expanded.contains(directory)) &&
                !state.loading.contains(directory) {
                relist.push(directory)
              }
            }
            if change.changes_file_list() {
              refresh_index = true
            }
          }
        } else {
          for path in ctx.open_files {
            stat_paths.push(path)
          }
          if state.children.contains("") && !state.loading.contains("") {
            relist.push(@pathx.Relative::root())
          }
          for directory in state.expanded {
            if state.children.contains(directory) &&
              !state.loading.contains(directory) {
              relist.push(directory)
            }
          }
          refresh_index = true
        }
        if !stat_paths.is_empty() {
          cmds.push(
            stat_files(dispatch, owner, stat_paths, workspace=ctx.workspace),
          )
        } else if moonbit_changed &&
          active_moonbit_diagnostics(
            dispatch,
            owner,
            state.docs,
            ctx.active_file,
          )
          is Some(recheck) {
          // A MoonBit change that touched no open tab still moves the
          // module's diagnostics (a sibling file's edit can break or fix the
          // active file), and without a stat round there is no `StatsLoaded`
          // to carry the usual re-check — ask directly. The check's pushes
          // refresh the other open tabs too.
          cmds.push(recheck)
        }
        let loading = state.loading.copy()
        for directory in relist {
          loading.push(directory)
          cmds.push(
            read_directory(dispatch, owner, directory, workspace=ctx.workspace),
          )
        }
        // Only structural events can change Quick Open's file index.
        // Do not duplicate the initial request when attaching its watcher emits
        // a baseline; only an already-usable snapshot refreshes in background.
        if refresh_index && state.index is IndexReady(..) {
          cmds.push(list_files(dispatch, owner, workspace=ctx.workspace))
        }
        let next = { ..state, loading, }
        // Any content event can change Git status, not just a structural one.
        // Refresh only after Changes has been requested and while its explorer
        // or a review is live; reopening performs its own full refresh. The
        // in-flight flag inside `refresh_changes` coalesces watcher bursts.
        let (changes_cmd, next) = if (
            explorer_visible(state, ctx) || changes_live(state, ctx)
          ) &&
          (
            state.changes is ChangeListLoading(_) ||
            state.changes is ChangeListReady(..)
          ) {
          refresh_changes(dispatch, next, ctx)
        } else {
          (@cmd.none, next)
        }
        cmds.push(changes_cmd)
        (@cmd.batch(cmds), next)
      } else {
        (@cmd.none, state)
      }
    StatsLoaded(owner~, stats~) =>
      if state.owner != Some(owner) {
        (@cmd.none, state)
      } else {
        let docs = state.docs.copy()
        let cmds = []
        // Whether the loop below already reloads the active tab — that path
        // re-requests diagnostics on its own.
        let mut active_reloading = false
        for stat in stats {
          guard docs.get(stat.path) is Some(doc) else { continue }
          guard stat.sig is Some(current_sig) else {
            // The file is gone. The tab stays as the user's bookmark; the
            // notice replaces the document if it is the one on screen. A tab
            // already reviewing a textual HEAD side instead switches to that
            // deleted-file preview.
            if !(doc.state is TabDeleted) {
              let deleted = { ..doc, state: TabDeleted, stale: false }
              docs[stat.path] = deleted
              if ctx.active_file == Some(stat.path) {
                cmds.push(show_tab(dispatch, ctx, stat.path, deleted))
              }
            }
            continue
          }
          let changed = match doc.state {
            // The loaded baseline says whether the disk moved on.
            TabLoaded(sig~, ..) => sig != current_sig
            // A deleted file whose signature came back: it reappeared.
            TabDeleted => true
            // A read is already in flight; its reply carries a fresh
            // signature anyway.
            TabLoading => false
            // Withheld documents carry no baseline to compare against (see
            // `TabState`); they refresh on explicit re-open instead. A
            // previous read failure does retry once the watcher proves the
            // path exists.
            TabBinary | TabOversized => false
            TabReadFailed(_) => true
          }
          if changed {
            if ctx.active_file == Some(stat.path) {
              // The document on screen reloads eagerly (scroll kept —
              // `FileLoaded` sees the previous content). The document keeps
              // its loaded state so that restore has its baseline.
              active_reloading = true
              cmds.push(
                read_file(
                  dispatch,
                  owner,
                  stat.path,
                  doc.name,
                  review_generation?=doc.review_generation(),
                  range=None,
                  workspace=ctx.workspace,
                ),
              )
            } else {
              // Background documents just remember they are behind;
              // activation reloads them. A build storm therefore costs one
              // read, not one per open tab.
              docs[stat.path] = { ..doc, stale: true }
            }
          }
        }
        // A change elsewhere in the module can add or remove the active
        // file's diagnostics without touching its own mtime — the one-shot
        // `moon check` behind `lsp_open` only runs when asked, unlike the
        // resident server it replaced. One re-check per (debounced) change
        // burst covers that: the reload above brings its own request, so
        // only an active file the stats left untouched needs the explicit
        // refresh. Its check's pushes update the other open tabs too.
        if !active_reloading &&
          active_moonbit_diagnostics(dispatch, owner, docs, ctx.active_file)
          is Some(recheck) {
          cmds.push(recheck)
        }
        (@cmd.batch(cmds), { ..state, docs, })
      }
    DiagnosticsLoaded(owner~, absolute~, diagnostics~) =>
      if state.owner == Some(owner) {
        (apply_diagnostics(owner.channel, absolute, diagnostics), state)
      } else {
        (@cmd.none, state)
      }
    DiagnosticsPublished(channel~, absolute~, diagnostics~) =>
      if state.owner is Some(owner) && owner.channel == channel {
        (apply_diagnostics(channel, absolute, diagnostics), state)
      } else {
        (@cmd.none, state)
      }
    FileFailed(owner~, path~, review_generation~, message~) =>
      if state.owner != Some(owner) {
        (@cmd.none, state)
      } else if review_generation is Some(generation) {
        // Review reads are generation-fenced just like successful replies.
        // Preserve a current working-side failure without guessing that every
        // host error means deletion; a superseded read remains invisible.
        guard state.docs.get(path) is Some(doc) &&
          doc.review is Some({ generation: current, .. }) &&
          current == generation else {
          return (@cmd.none, state)
        }
        let docs = state.docs.copy()
        let failed = { ..doc, state: TabReadFailed(message), stale: false }
        docs[path] = failed
        let cmd = if ctx.active_file == Some(path) {
          show_tab(dispatch, ctx, path, failed)
        } else {
          @cmd.none
        }
        (cmd, { ..state, docs, error: None })
      } else if state.docs.get(path) is Some({ review: Some(_), .. }) {
        // Like an untagged success, this failure belongs to an ordinary read
        // that predates the review click and is no longer user-visible.
        (@cmd.none, state)
      } else {
        (@cmd.none, { ..state, error: Some(message) })
      }
    FileWatchFailed(owner~, message~) =>
      if state.owner != Some(owner) {
        (@cmd.none, state)
      } else {
        (@cmd.none, { ..state, watch_error: Some(message) })
      }
    // Owned by the main package's update: the comment becomes a composer
    // chip there, which then clears the editor bubble through
    // `remove_editor_feedback`. Reaching this arm means the main update
    // didn't intercept it; changing nothing is the safe answer.
    EditorCommentAdded(..) => (@cmd.none, state)
  }
}

// State-transition tests for the document table: opening documents, how
// replies settle into the table, disk-change sweeps, and how a conversation
// switch re-roots the table from the dock's projection. Commands are opaque,
// so the tests assert on the returned state only.

///|
fn test_emit() -> @cmd.Emit[Msg] {
  Emit(_ => @cmd.none)
}

///|
fn test_ctx() -> Ctx {
  {
    owner: { channel: @interop.ChannelId::Local, session: "desktop-test" },
    workspace: None,
    checkout: Some(@interop.WorkspaceRoot),
    dark_mode: false,
    tree_layout: BottomPanel,
    narrow: false,
    panel_open: true,
    open_files: [],
    active_file: None,
  }
}

///|
fn owned_state() -> State {
  {
    ..State::empty(),
    owner: Some(test_ctx().owner),
    explorer_was_visible: true,
  }
}

///|
fn loaded_doc(path : String) -> Doc raise {
  guard @resource.of_path(@interop.ChannelId::Local, "/work/" + path)
    is Some(absolute) else {
    fail("test document resource was not absolute")
  }
  {
    name: basename(Relative(path)),
    state: TabLoaded(content="", absolute~, sig="1:0"),
    review: None,
    stale: false,
  }
}

///|
fn test_modified_change(path : @pathx.Relative) -> ChangedFile {
  {
    path,
    original_path: None,
    index_status: " ",
    worktree_status: "M",
    kind: ChangeModified,
  }
}

///|
test "open_document seeds a loading entry and re-open keeps cached content" {
  let emit = test_emit()
  let (_, one) = open_document(
    emit,
    owned_state(),
    {
      ..test_ctx(),
      open_files: [Relative("a.mbt")],
      active_file: Some(Relative("a.mbt")),
    },
    Relative("a.mbt"),
    name="a.mbt",
    range=None,
    had_active=false,
  )
  assert_true(
    one.docs.get(Relative("a.mbt")) is Some({ state: TabLoading, .. }),
  )
  // A plain re-open of a loaded document keeps the cached state — the show
  // command redraws from the table, never waiting on a re-read's reply.
  let docs = one.docs.copy()
  docs[Relative("a.mbt")] = loaded_doc("a.mbt")
  let (_, again) = open_document(
    emit,
    { ..one, docs, },
    {
      ..test_ctx(),
      open_files: [Relative("a.mbt")],
      active_file: Some(Relative("a.mbt")),
    },
    Relative("a.mbt"),
    name="a.mbt",
    range=None,
    had_active=true,
  )
  assert_true(
    again.docs.get(Relative("a.mbt")) is Some({ state: TabLoaded(..), .. }),
  )
}

///|
test "changed-file review fences paired replies and ordinary opens leave review" {
  let emit = test_emit()
  let path = @pathx.Relative("a.mbt")
  let ctx = { ..test_ctx(), open_files: [path], active_file: Some(path) }
  let change : ChangedFile = {
    path,
    original_path: None,
    index_status: " ",
    worktree_status: "M",
    kind: ChangeModified,
  }
  let (_, first) = open_changed_document(
    emit,
    owned_state(),
    ctx,
    change,
    had_active=false,
  )
  assert_eq(first.review_generation, 1)
  assert_true(
    first.docs.get(path)
    is Some(
      {
        state: TabLoading,
        review: Some({ generation: 1, baseline: ReviewLoading, .. }),
        ..,
      }
    ),
  )
  // A repeated row click owns a newer generation; its predecessor cannot
  // replace the baseline even though owner and path still match.
  let (_, second) = open_changed_document(
    emit,
    first,
    ctx,
    change,
    had_active=true,
  )
  guard @resource.of_path(@interop.ChannelId::Local, "/work/a.mbt")
    is Some(absolute) else {
    fail("test file resource was not absolute")
  }
  // An ordinary read that began before the first review click carries no
  // token. It must not inherit the newer baseline if it settles afterward.
  let (_, pre_review_working) = update(
    emit,
    FileLoaded(
      owner=ctx.owner,
      path~,
      name="a.mbt",
      file=Content(content="pre-review working", absolute~, sig="0:18"),
      review_generation=None,
      range=None,
      annotation=None,
    ),
    second,
    ctx,
  )
  assert_true(
    pre_review_working.docs.get(path)
    is Some(
      {
        state: TabLoading,
        review: Some({ generation: 2, baseline: ReviewLoading, .. }),
        ..,
      }
    ),
  )
  let (_, old_working) = update(
    emit,
    FileLoaded(
      owner=ctx.owner,
      path~,
      name="a.mbt",
      file=Content(content="stale working", absolute~, sig="1:13"),
      review_generation=Some(1),
      range=None,
      annotation=None,
    ),
    pre_review_working,
    ctx,
  )
  assert_true(
    old_working.docs.get(path)
    is Some(
      {
        state: TabLoading,
        review: Some({ generation: 2, baseline: ReviewLoading, .. }),
        ..,
      }
    ),
  )
  let (_, ignored) = update(
    emit,
    GitOriginalLoaded(
      owner=ctx.owner,
      path~,
      generation=1,
      original=@protocol.OriginalContent("old one"),
    ),
    old_working,
    ctx,
  )
  assert_true(
    ignored.docs.get(path)
    is Some(
      { review: Some({ generation: 2, baseline: ReviewLoading, .. }), .. }
    ),
  )
  let (_, reviewed) = update(
    emit,
    GitOriginalLoaded(
      owner=ctx.owner,
      path~,
      generation=2,
      original=@protocol.OriginalContent("old two"),
    ),
    ignored,
    ctx,
  )
  assert_true(
    reviewed.docs.get(path)
    is Some(
      {
        review: Some({ generation: 2, baseline: ReviewContent("old two"), .. }),
        ..,
      }
    ),
  )
  let docs = reviewed.docs.copy()
  docs[path] = {
    ..loaded_doc("a.mbt"),
    review: Some({
      generation: 2,
      baseline: ReviewContent("old two"),
      selected: change,
    }),
  }
  let (_, ordinary) = open_document(
    emit,
    { ..reviewed, docs, },
    ctx,
    path,
    name="a.mbt",
    range=None,
    had_active=true,
  )
  assert_true(ordinary.docs.get(path) is Some({ review: None, .. }))
  let (_, review_after_ordinary) = update(
    emit,
    FileLoaded(
      owner=ctx.owner,
      path~,
      name="a.mbt",
      file=Content(content="late review", absolute~, sig="3:11"),
      review_generation=Some(2),
      range=None,
      annotation=None,
    ),
    ordinary,
    ctx,
  )
  assert_true(review_after_ordinary == ordinary)
}

///|
test "changed-file review preserves a stale cached working document until reload" {
  let emit = test_emit()
  let path = @pathx.Relative("stale.mbt")
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[path] = { ..loaded_doc("stale.mbt"), stale: true }
  let ctx = { ..test_ctx(), open_files: [path], active_file: Some(path) }
  let change : ChangedFile = {
    path,
    original_path: None,
    index_status: " ",
    worktree_status: "M",
    kind: ChangeModified,
  }
  let (_, reviewing) = open_changed_document(
    emit,
    { ..owned_state(), docs, },
    ctx,
    change,
    had_active=true,
  )
  assert_true(
    reviewing.docs.get(path)
    is Some({ state: TabLoaded(..), review: Some(_), stale: true, .. }),
  )
  // Canceling the tagged review read through an ordinary open retains the
  // staleness marker, so `show_tab` schedules its own untagged refresh.
  let (_, ordinary) = open_document(
    emit,
    reviewing,
    ctx,
    path,
    name="stale.mbt",
    range=None,
    had_active=true,
  )
  assert_true(
    ordinary.docs.get(path)
    is Some({ state: TabLoaded(..), review: None, stale: true, .. }),
  )
}

///|
test "review failures settle precisely and missing rename sources stay unavailable" {
  let emit = test_emit()
  let path = @pathx.Relative("new.mbt")
  let ctx = { ..test_ctx(), open_files: [path], active_file: Some(path) }
  let rename : ChangedFile = {
    path,
    original_path: None,
    index_status: "R",
    worktree_status: " ",
    kind: ChangeRenamed,
  }
  let (_, unavailable) = open_changed_document(
    emit,
    owned_state(),
    ctx,
    rename,
    had_active=false,
  )
  assert_true(
    unavailable.docs.get(path)
    is Some(
      {
        review: Some(
          {
            generation: 1,
            baseline: ReviewFailed(
              "the original path is outside this workspace"
            ),
            ..,
          }
        ),
        ..,
      }
    ),
  )

  let modified = {
    ..rename,
    index_status: " ",
    worktree_status: "M",
    kind: ChangeModified,
  }
  let (_, loading) = open_changed_document(
    emit,
    owned_state(),
    ctx,
    modified,
    had_active=false,
  )
  let (_, failed) = update(
    emit,
    GitOriginalFailed(
      owner=ctx.owner,
      path~,
      generation=1,
      message="Git baseline failed",
    ),
    loading,
    ctx,
  )
  assert_true(
    failed.docs.get(path)
    is Some(
      {
        review: Some(
          { generation: 1, baseline: ReviewFailed("Git baseline failed"), .. }
        ),
        ..,
      }
    ),
  )
  let (_, read_failed) = update(
    emit,
    FileFailed(
      owner=ctx.owner,
      path~,
      review_generation=Some(1),
      message="file disappeared",
    ),
    failed,
    ctx,
  )
  assert_true(
    read_failed.docs.get(path)
    is Some({ state: TabReadFailed("file disappeared"), .. }),
  )
  assert_true(read_failed.error is None)
}

///|
test "deleted changes preview HEAD and working-file loads retain early baselines" {
  let emit = test_emit()
  let deleted_path = @pathx.Relative("gone.mbt")
  let ctx = {
    ..test_ctx(),
    open_files: [deleted_path],
    active_file: Some(deleted_path),
  }
  let deleted : ChangedFile = {
    path: deleted_path,
    original_path: None,
    index_status: " ",
    worktree_status: "D",
    kind: ChangeDeleted,
  }
  let (_, loading) = open_changed_document(
    emit,
    owned_state(),
    ctx,
    deleted,
    had_active=false,
  )
  assert_true(
    loading.docs.get(deleted_path)
    is Some(
      {
        state: TabDeleted,
        review: Some({ generation: 1, baseline: ReviewLoading, .. }),
        ..,
      }
    ),
  )
  let (_, preview) = update(
    emit,
    GitOriginalLoaded(
      owner=ctx.owner,
      path=deleted_path,
      generation=1,
      original=@protocol.OriginalContent("removed source"),
    ),
    loading,
    ctx,
  )
  assert_true(
    preview.docs.get(deleted_path)
    is Some(
      {
        state: TabDeleted,
        review: Some(
          { generation: 1, baseline: ReviewContent("removed source"), .. }
        ),
        ..,
      }
    ),
  )

  // The HEAD request may beat the ordinary filesystem read. Its result stays
  // on the loading document and is preserved when `FileLoaded` settles it.
  let live_path = @pathx.Relative("live.mbt")
  let live_ctx = {
    ..ctx,
    open_files: [live_path],
    active_file: Some(live_path),
  }
  let live = {
    ..deleted,
    path: live_path,
    worktree_status: "M",
    kind: ChangeModified,
  }
  let (_, live_loading) = open_changed_document(
    emit,
    owned_state(),
    live_ctx,
    live,
    had_active=false,
  )
  let (_, baseline_first) = update(
    emit,
    GitOriginalLoaded(
      owner=live_ctx.owner,
      path=live_path,
      generation=1,
      original=@protocol.Missing,
    ),
    live_loading,
    live_ctx,
  )
  guard @resource.of_path(@interop.ChannelId::Local, "/work/live.mbt")
    is Some(absolute) else {
    fail("test file resource was not absolute")
  }
  let (_, loaded) = update(
    emit,
    FileLoaded(
      owner=live_ctx.owner,
      path=live_path,
      name="live.mbt",
      file=Content(content="new", absolute~, sig="2:3"),
      review_generation=Some(1),
      range=None,
      annotation=None,
    ),
    baseline_first,
    live_ctx,
  )
  assert_true(
    loaded.docs.get(live_path)
    is Some(
      {
        state: TabLoaded(content="new", ..),
        review: Some({ generation: 1, baseline: ReviewMissing, .. }),
        ..,
      }
    ),
  )
}

///|
test "narrow ctx: opening or activating a document closes the tree pane" {
  let emit = test_emit()
  let narrow : Ctx = {
    ..test_ctx(),
    narrow: true,
    open_files: [Relative("a.mbt")],
    active_file: Some(Relative("a.mbt")),
  }
  let start = { ..owned_state(), tree_open: true }
  // A fresh open drills down into the viewer.
  let (_, opened) = open_document(
    emit,
    start,
    narrow,
    Relative("a.mbt"),
    name="a.mbt",
    range=None,
    had_active=false,
  )
  assert_false(opened.tree_open)
  // Back to the tree, then activating an open document drills down again.
  let (_, tree) = update(emit, ToggleTree, opened, narrow)
  assert_true(tree.tree_open)
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[Relative("a.mbt")] = loaded_doc("a.mbt")
  let (_, activated) = activate(
    emit,
    { ..tree, docs, },
    narrow,
    Relative("a.mbt"),
  )
  assert_false(activated.tree_open)
  // The wide layout keeps the pane open alongside the viewer.
  let (_, wide) = open_document(
    emit,
    start,
    {
      ..test_ctx(),
      open_files: [Relative("b.mbt")],
      active_file: Some(Relative("b.mbt")),
    },
    Relative("b.mbt"),
    name="b.mbt",
    range=None,
    had_active=false,
  )
  assert_true(wide.tree_open)
}

///|
test "activate without a document entry is a no-op" {
  let emit = test_emit()
  let (_, same) = activate(
    emit,
    owned_state(),
    test_ctx(),
    Relative("gone.mbt"),
  )
  assert_true(same == owned_state())
}

///|
test "close_document drops the entry and forces the tree open on the last one" {
  let emit = test_emit()
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[Relative("a.mbt")] = loaded_doc("a.mbt")
  docs[Relative("b.mbt")] = loaded_doc("b.mbt")
  let state = { ..owned_state(), docs, tree_open: false }
  // Closing the active document with a neighbor left: the entry goes, the
  // tree stays as it was.
  let (_, one) = close_document(
    emit,
    state,
    test_ctx(),
    Relative("a.mbt"),
    next=Some(Relative("b.mbt")),
    was_active=true,
  )
  assert_false(one.docs.contains(Relative("a.mbt")))
  assert_true(one.docs.contains(Relative("b.mbt")))
  assert_false(one.tree_open)
  // Closing the last document: the viewer falls back to the placeholder and
  // the tree is forced open so the panel is never a dead pane.
  let (_, last) = close_document(
    emit,
    one,
    test_ctx(),
    Relative("b.mbt"),
    next=None,
    was_active=true,
  )
  assert_true(last.docs.is_empty())
  assert_true(last.tree_open)
}

///|
test "FileLoaded settles content into its document, active or not" {
  let emit = test_emit()
  guard @resource.of_path(@interop.ChannelId::Local, "/work/a.mbt")
    is Some(absolute) else {
    fail("test file resource was not absolute")
  }
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[Relative("a.mbt")] = {
    name: "a.mbt",
    state: TabLoading,
    review: None,
    stale: false,
  }
  docs[Relative("b.mbt")] = loaded_doc("b.mbt")
  let state = { ..owned_state(), docs, }
  let ctx = {
    ..test_ctx(),
    open_files: [Relative("a.mbt"), Relative("b.mbt")],
    active_file: Some(Relative("b.mbt")),
  }
  let (_, next) = update(
    emit,
    FileLoaded(
      owner=test_ctx().owner,
      path=Relative("a.mbt"),
      name="a.mbt",
      file=Content(content="fn main {}", absolute~, sig="2:0"),
      review_generation=None,
      range=None,
      annotation=None,
    ),
    state,
    ctx,
  )
  assert_true(
    next.docs.get(Relative("a.mbt"))
    is Some({ state: TabLoaded(content="fn main {}", ..), .. }),
  )
  // A reply for a closed document (or another conversation) is dropped.
  guard @resource.of_path(@interop.ChannelId::Local, "/work/gone.mbt")
    is Some(gone_absolute) else {
    fail("test closed file resource was not absolute")
  }
  let (_, stray) = update(
    emit,
    FileLoaded(
      owner=test_ctx().owner,
      path=Relative("gone.mbt"),
      name="gone.mbt",
      file=Content(content="", absolute=gone_absolute, sig="2:0"),
      review_generation=None,
      range=None,
      annotation=None,
    ),
    next,
    ctx,
  )
  assert_true(stray.docs.length() == 2)
  let (_, other) = update(
    emit,
    FileLoaded(
      owner={
        channel: @interop.ChannelId::Remote("other"),
        session: "desktop-test",
      },
      path=Relative("a.mbt"),
      name="a.mbt",
      file=Binary,
      review_generation=None,
      range=None,
      annotation=None,
    ),
    stray,
    ctx,
  )
  assert_true(
    other.docs.get(Relative("a.mbt")) is Some({ state: TabLoaded(..), .. }),
  )
}

///|
test "sync re-roots the document table from the dock's projection" {
  let emit = test_emit()
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[Relative("old.mbt")] = loaded_doc("old.mbt")
  let state = { ..owned_state(), docs, tree_open: false }
  // Switch conversations: the dock restored a two-file strip for the new
  // one; the table re-seeds from it, identities only.
  let other : Ctx = {
    ..test_ctx(),
    owner: {
      channel: @interop.ChannelId::Remote("other"),
      session: "desktop-test",
    },
    open_files: [Relative("a.mbt"), Relative("b.mbt")],
    active_file: Some(Relative("a.mbt")),
  }
  let (rerooted, _) = sync(emit, state, other)
  assert_true(rerooted.owner is Some({ channel: Remote("other"), .. }))
  assert_false(rerooted.docs.contains(Relative("old.mbt")))
  assert_true(
    rerooted.docs.get(Relative("a.mbt")) is Some({ state: TabLoading, .. }),
  )
  assert_true(
    rerooted.docs.get(Relative("b.mbt")) is Some({ state: TabLoading, .. }),
  )
  // The pane-visibility preference follows the panel, not the conversation.
  assert_false(rerooted.tree_open)
}

///|
/// The bug this guards against: with the panel closed but files remaining
/// open, switching conversations used to skip the re-root while the watcher
/// followed the new session — the next fs_changed then stat'ed the old
/// conversation's paths against the new workspace, marking hidden documents
/// deleted or stale for files that never moved.
test "a closed panel still re-roots when the conversation switches" {
  let emit = test_emit()
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[Relative("a.mbt")] = loaded_doc("a.mbt")
  let state = {
    ..owned_state(),
    docs,
    watching: Some({
      owner: test_ctx().owner,
      workspace: None,
      files: [Relative("a.mbt")],
      directories: [],
    }),
  }
  // The new conversation has nothing open and the panel is closed.
  let other : Ctx = {
    ..test_ctx(),
    owner: {
      channel: @interop.ChannelId::Remote("other"),
      session: "desktop-test",
    },
    panel_open: false,
  }
  let (parked, _) = sync(emit, state, other)
  assert_true(parked.owner is Some({ channel: Remote("other"), .. }))
  assert_true(parked.docs.is_empty())
  // Nothing left to track in the new conversation, so the watcher parks.
  assert_true(parked.watching is None)
  // Switching back (still closed) re-seeds the table and the watcher
  // follows the open files again.
  let back : Ctx = {
    ..test_ctx(),
    panel_open: false,
    open_files: [Relative("a.mbt")],
    active_file: Some(Relative("a.mbt")),
  }
  let (restored, _) = sync(emit, parked, back)
  assert_true(
    restored.docs.get(Relative("a.mbt")) is Some({ state: TabLoading, .. }),
  )
  assert_true(
    restored.watching
    is Some(
      {
        owner: { channel: Local, session: "desktop-test" },
        workspace: None,
        files: [Relative("a.mbt")],
        directories: [],
      }
    ),
  )
}

///|
test "a missing checkout parks files and refuses editor actions until repair" {
  let emit = test_emit()
  let present = test_ctx()
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[Relative("a.mbt")] = loaded_doc("a.mbt")
  let state = {
    ..owned_state(),
    docs,
    watching: Some({
      owner: present.owner,
      workspace: None,
      files: [Relative("a.mbt")],
      directories: [@pathx.Relative::root()],
    }),
  }
  let missing : Ctx = {
    ..present,
    owner: { ..present.owner, session: "" },
    checkout: Some(@interop.MissingWorktree(name="wt")),
    open_files: [],
    active_file: None,
  }
  let (parked, _) = sync(emit, state, missing)
  assert_true(parked.owner is Some({ session: "", .. }))
  assert_true(parked.docs.is_empty())
  assert_true(parked.watching is None)
  // A stale control event cannot start a file index request while missing.
  let (_, refused) = update(emit, EnsureFileIndex, parked, missing)
  assert_true(refused == parked)
  let (_, selected) = update(
    emit,
    ExplorerModeSelected(ExplorerChanges),
    parked,
    missing,
  )
  assert_true(selected.explorer_mode is ExplorerChanges)
  // Repeated reconciliation is pure. The dock owns the remembered tab
  // identity; after Repair its projection re-seeds that document here.
  let (still_parked, _) = sync(emit, parked, missing)
  assert_true(still_parked == parked)
  let restored_ctx = {
    ..present,
    open_files: [Relative("a.mbt")],
    active_file: Some(Relative("a.mbt")),
  }
  let (restored, _) = sync(emit, parked, restored_ctx)
  assert_true(
    restored.docs.get(Relative("a.mbt")) is Some({ state: TabLoading, .. }),
  )
}

///|
test "a missing checkout settles an in-flight Changes request for retry" {
  let emit = test_emit()
  let present = test_ctx()
  let state = {
    ..owned_state(),
    explorer_mode: ExplorerChanges,
    changes: ChangeListLoading(refresh_again=true),
    changes_generation: 1,
    watching: Some({
      owner: present.owner,
      workspace: None,
      files: [],
      directories: [@pathx.Relative::root()],
    }),
  }
  let missing : Ctx = {
    ..present,
    checkout: Some(@interop.MissingWorktree(name="wt")),
  }
  let (parked, _) = sync(emit, state, missing)
  assert_true(parked.changes is ChangeListIdle)
  assert_true(parked.changes_generation == 1)
  assert_true(parked.watching is None)
  // The host reply is local state only, but the parked update boundary drops
  // it. The sync above has already removed the liveness hazard.
  let (_, after_reply) = update(
    emit,
    ChangesLoaded(
      owner=present.owner,
      generation=1,
      repository=true,
      head=None,
      files=[],
    ),
    parked,
    missing,
  )
  assert_true(after_reply == parked)
  let (restored, _) = sync(emit, after_reply, present)
  assert_true(restored.changes is ChangeListLoading(refresh_again=false))
  assert_true(restored.changes_generation == 2)
}

///|
test "checkout recovery restarts a review whose paired replies were parked" {
  let emit = test_emit()
  let present = test_ctx()
  let path = @pathx.Relative("reviewed.mbt")
  let change : ChangedFile = {
    path,
    original_path: None,
    index_status: " ",
    worktree_status: "M",
    kind: ChangeModified,
  }
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[path] = {
    name: "reviewed.mbt",
    state: TabLoading,
    review: Some({ generation: 3, baseline: ReviewLoading, selected: change }),
    stale: false,
  }
  let state = {
    ..owned_state(),
    changes: ChangeListReady(
      repository=true,
      files=[change],
      refreshing=true,
      refresh_again=false,
    ),
    changes_generation: 1,
    changes_head: Some("same-head"),
    changes_head_known: true,
    review_generation: 3,
    docs,
    watching: Some({
      owner: present.owner,
      workspace: None,
      files: [path],
      directories: [@pathx.Relative::root()],
    }),
  }
  let missing : Ctx = {
    ..present,
    checkout: Some(@interop.MissingWorktree(name="wt")),
    open_files: [path],
    active_file: Some(path),
  }
  let (parked, _) = sync(emit, state, missing)
  assert_true(
    parked.changes is ChangeListReady(refreshing=false, refresh_again=false, ..),
  )
  assert_true(parked.review_recovery_pending)
  let (restored, _) = sync(emit, parked, {
    ..present,
    open_files: [path],
    active_file: Some(path),
  })
  assert_true(
    restored.changes
    is ChangeListReady(refreshing=true, refresh_again=false, ..),
  )
  assert_true(restored.changes_generation == 2)
  assert_true(restored.review_recovery_pending)
  let (_, restarted) = update(
    emit,
    ChangesLoaded(
      owner=present.owner,
      generation=2,
      repository=true,
      head=Some("same-head"),
      files=[change],
    ),
    restored,
    { ..present, open_files: [path], active_file: Some(path) },
  )
  assert_true(restarted.review_generation == 4)
  assert_false(restarted.review_recovery_pending)
  assert_true(
    restarted.docs.get(path)
    is Some(
      {
        state: TabLoading,
        review: Some({ generation: 4, baseline: ReviewLoading, .. }),
        ..,
      }
    ),
  )
}

///|
test "ordinary Changes polls do not supersede healthy in-flight reviews" {
  let emit = test_emit()
  let present = test_ctx()
  let path = @pathx.Relative("slow.mbt")
  let change : ChangedFile = {
    path,
    original_path: None,
    index_status: " ",
    worktree_status: "M",
    kind: ChangeModified,
  }
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[path] = {
    name: "slow.mbt",
    state: TabLoading,
    review: Some({ generation: 3, baseline: ReviewLoading, selected: change }),
    stale: false,
  }
  let state = {
    ..owned_state(),
    changes: ChangeListReady(
      repository=true,
      files=[change],
      refreshing=true,
      refresh_again=false,
    ),
    changes_generation: 1,
    changes_head: Some("same-head"),
    changes_head_known: true,
    review_generation: 3,
    docs,
  }
  let (_, polled) = update(
    emit,
    ChangesLoaded(
      owner=present.owner,
      generation=1,
      repository=true,
      head=Some("same-head"),
      files=[change],
    ),
    state,
    { ..present, open_files: [path], active_file: Some(path) },
  )
  assert_true(polled.review_generation == 3)
  assert_true(
    polled.docs.get(path)
    is Some(
      {
        state: TabLoading,
        review: Some({ generation: 3, baseline: ReviewLoading, .. }),
        ..,
      }
    ),
  )
}

///|
test "an unresolved placement parks files and refuses editor actions" {
  let emit = test_emit()
  let present = test_ctx()
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[Relative("a.mbt")] = loaded_doc("a.mbt")
  let state = {
    ..owned_state(),
    docs,
    watching: Some({
      owner: present.owner,
      workspace: None,
      files: [Relative("a.mbt")],
      directories: [@pathx.Relative::root()],
    }),
  }
  let unresolved : Ctx = {
    ..present,
    owner: { ..present.owner, session: "" },
    checkout: None,
    open_files: [],
    active_file: None,
  }
  let (parked, _) = sync(emit, state, unresolved)
  assert_true(parked.owner is Some({ session: "", .. }))
  assert_true(parked.docs.is_empty())
  assert_true(parked.watching is None)
  let (_, refused) = update(emit, EnsureFileIndex, parked, unresolved)
  assert_true(refused == parked)
  let (_, selected) = update(
    emit,
    ExplorerModeSelected(ExplorerChanges),
    parked,
    unresolved,
  )
  assert_true(selected.explorer_mode is ExplorerChanges)
}

///|
test "ToggleTree flips the pane and RevealDirectory forces it open" {
  let emit = test_emit()
  let (_, closed) = update(
    emit,
    ToggleTree,
    { ..owned_state(), explorer_mode: ExplorerChanges },
    test_ctx(),
  )
  assert_false(closed.tree_open)
  let (_, revealed) = update(
    emit,
    RevealDirectory(Relative("src")),
    closed,
    test_ctx(),
  )
  assert_true(revealed.tree_open)
  assert_true(revealed.explorer_mode is ExplorerFiles)
  assert_true(revealed.highlighted is Some(Relative("src")))
}

///|
test "reopening Changes refreshes despite a Quick Open root watch" {
  let state = {
    ..owned_state(),
    explorer_mode: ExplorerChanges,
    changes: ChangeListReady(
      repository=true,
      files=[],
      refreshing=false,
      refresh_again=false,
    ),
    index: IndexReady(files=[Relative("nested/file.mbt")], truncated=false),
    watching: Some({
      owner: test_ctx().owner,
      workspace: None,
      files: [],
      directories: [@pathx.Relative::root()],
    }),
  }
  let closed_ctx = { ..test_ctx(), panel_open: false }
  let (closed, _) = sync(test_emit(), state, closed_ctx)
  assert_false(closed.explorer_was_visible)
  assert_true(closed.watching is Some({ directories: [Relative("")], .. }))
  let (refreshed, _) = sync(test_emit(), closed, test_ctx())
  assert_true(refreshed.explorer_was_visible)
  assert_true(
    refreshed.changes
    is ChangeListReady(refreshing=true, refresh_again=false, ..),
  )
}

///|
test "showing a hidden explorer refreshes Changes before polling resumes" {
  let hidden_ctx = { ..test_ctx(), active_file: Some(Relative("src/main.mbt")) }
  let state = {
    ..owned_state(),
    tree_open: false,
    explorer_mode: ExplorerChanges,
    explorer_was_visible: false,
    changes: ChangeListReady(
      repository=true,
      files=[],
      refreshing=false,
      refresh_again=false,
    ),
    watching: Some({
      owner: test_ctx().owner,
      workspace: None,
      files: [],
      directories: [@pathx.Relative::root()],
    }),
  }
  let (hidden, _) = sync(test_emit(), state, hidden_ctx)
  assert_false(hidden.explorer_was_visible)
  assert_true(hidden.changes is ChangeListReady(refreshing=false, ..))
  let (refreshed, _) = sync(
    test_emit(),
    { ..hidden, tree_open: true },
    hidden_ctx,
  )
  assert_true(refreshed.explorer_was_visible)
  assert_true(refreshed.changes is ChangeListReady(refreshing=true, ..))
}

///|
test "reopening Changes latches a follow-up for an in-flight refresh" {
  let state = {
    ..owned_state(),
    explorer_mode: ExplorerChanges,
    changes: ChangeListReady(
      repository=true,
      files=[],
      refreshing=true,
      refresh_again=false,
    ),
    changes_generation: 1,
    explorer_was_visible: false,
    watching: Some({
      owner: test_ctx().owner,
      workspace: None,
      files: [],
      directories: [@pathx.Relative::root()],
    }),
  }
  let (refreshed, _) = sync(test_emit(), state, test_ctx())
  assert_true(
    refreshed.changes
    is ChangeListReady(refreshing=true, refresh_again=true, ..),
  )
  assert_true(refreshed.changes_generation == 1)
}

///|
test "reopening Changes latches a follow-up for the initial load" {
  let state = {
    ..owned_state(),
    explorer_mode: ExplorerChanges,
    changes: ChangeListLoading(refresh_again=false),
    changes_generation: 1,
    explorer_was_visible: false,
    watching: Some({
      owner: test_ctx().owner,
      workspace: None,
      files: [],
      directories: [@pathx.Relative::root()],
    }),
  }
  let (refreshed, _) = sync(test_emit(), state, test_ctx())
  assert_true(refreshed.changes is ChangeListLoading(refresh_again=true))
  assert_true(refreshed.changes_generation == 1)
}

///|
test "selecting Changes loads once and coalesces an in-flight refresh" {
  let emit = test_emit()
  let (_, loading) = update(
    emit,
    ExplorerModeSelected(ExplorerChanges),
    owned_state(),
    test_ctx(),
  )
  assert_true(loading.explorer_mode is ExplorerChanges)
  assert_true(loading.changes is ChangeListLoading(refresh_again=false))
  assert_true(loading.changes_generation == 1)
  // Re-selecting while the first request is in flight latches one follow-up,
  // without starting another request before this reply lands.
  let (_, latched) = update(
    emit,
    ExplorerModeSelected(ExplorerChanges),
    loading,
    test_ctx(),
  )
  assert_true(latched.changes is ChangeListLoading(refresh_again=true))
  let (_, following_up) = update(
    emit,
    ChangesLoaded(
      owner=test_ctx().owner,
      generation=1,
      repository=true,
      head=None,
      files=[],
    ),
    latched,
    test_ctx(),
  )
  assert_true(
    following_up.changes
    is ChangeListReady(refreshing=true, refresh_again=false, ..),
  )
  assert_true(following_up.changes_generation == 2)
}

///|
test "moving focus to a ready Changes snapshot defers its fallback refresh" {
  let emit = test_emit()
  let state = {
    ..owned_state(),
    explorer_mode: ExplorerFiles,
    changes: ChangeListReady(
      repository=true,
      files=[],
      refreshing=false,
      refresh_again=false,
    ),
    changes_generation: 4,
  }
  let (_, selected) = update(
    emit,
    ExplorerModeSelected(ExplorerChanges),
    state,
    test_ctx(),
  )
  assert_true(selected.explorer_mode is ExplorerChanges)
  assert_true(selected.changes_generation == 4)
  assert_true(selected.changes is ChangeListReady(refreshing=false, ..))
  // Re-selecting the active tab remains the explicit, immediate refresh.
  let (_, refreshing) = update(
    emit,
    ExplorerModeSelected(ExplorerChanges),
    selected,
    test_ctx(),
  )
  assert_true(refreshing.changes_generation == 5)
  assert_true(refreshing.changes is ChangeListReady(refreshing=true, ..))
}

///|
test "watcher events latch a follow-up during the initial change load" {
  let emit = test_emit()
  let state = {
    ..owned_state(),
    explorer_mode: ExplorerChanges,
    changes: ChangeListLoading(refresh_again=false),
    changes_generation: 1,
  }
  let (_, latched) = update(
    emit,
    FsChanged(
      session=Some("desktop-test"),
      changes=Some([Modified(Relative("src/main.mbt"))]),
    ),
    state,
    test_ctx(),
  )
  assert_true(latched.changes is ChangeListLoading(refresh_again=true))
}

///|
test "changed-file replies are owner-and-generation-fenced" {
  let emit = test_emit()
  let state = {
    ..owned_state(),
    explorer_mode: ExplorerChanges,
    changes: ChangeListLoading(refresh_again=false),
    changes_generation: 1,
  }
  let files = [
    {
      path: Relative("src/main.mbt"),
      original_path: None,
      index_status: " ",
      worktree_status: "M",
      kind: ChangeModified,
    },
  ]
  let (_, ready) = update(
    emit,
    ChangesLoaded(
      owner=test_ctx().owner,
      generation=1,
      repository=true,
      head=None,
      files~,
    ),
    state,
    test_ctx(),
  )
  assert_true(
    ready.changes
    is ChangeListReady(
      repository=true,
      files=[{ path: Relative("src/main.mbt"), .. }],
      refreshing=false,
      refresh_again=false
    ),
  )
  let (_, stale) = update(
    emit,
    ChangesLoaded(
      owner={
        channel: @interop.ChannelId::Remote("other"),
        session: "desktop-test",
      },
      generation=1,
      repository=true,
      head=None,
      files=[],
    ),
    ready,
    test_ctx(),
  )
  assert_true(stale == ready)
  let (_, stale_failure) = update(
    emit,
    ChangesFailed(
      owner={
        channel: @interop.ChannelId::Remote("other"),
        session: "desktop-test",
      },
      generation=1,
      message="stale git failure",
    ),
    ready,
    test_ctx(),
  )
  assert_true(stale_failure == ready)
  let (_, stale_generation) = update(
    emit,
    ChangesLoaded(
      owner=test_ctx().owner,
      generation=0,
      repository=true,
      head=None,
      files=[],
    ),
    ready,
    test_ctx(),
  )
  assert_true(stale_generation == ready)
  let idle = { ..owned_state(), changes_generation: 1 }
  let (_, stale_idle_failure) = update(
    emit,
    ChangesFailed(
      owner=test_ctx().owner,
      generation=1,
      message="stale git failure",
    ),
    idle,
    test_ctx(),
  )
  assert_true(stale_idle_failure == idle)
}

///|
test "a settled Changes snapshot clears reviews whose rows disappeared" {
  let path = @pathx.Relative("src/committed.mbt")
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[path] = {
    ..loaded_doc(path.0),
    review: Some({
      generation: 3,
      baseline: ReviewContent("old HEAD"),
      selected: test_modified_change(path),
    }),
  }
  let state = {
    ..owned_state(),
    explorer_mode: ExplorerChanges,
    changes: ChangeListLoading(refresh_again=false),
    changes_generation: 1,
    review_generation: 3,
    docs,
  }
  let (_, settled) = update(
    test_emit(),
    ChangesLoaded(
      owner=test_ctx().owner,
      generation=1,
      repository=true,
      head=None,
      files=[],
    ),
    state,
    { ..test_ctx(), open_files: [path], active_file: Some(path) },
  )
  assert_true(settled.docs.get(path) is Some({ review: None, .. }))
}

///|
test "only a final Changes snapshot reconciles reviews and moved HEAD refreshes survivors" {
  let path = @pathx.Relative("src/partial.mbt")
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[path] = {
    ..loaded_doc(path.0),
    review: Some({
      generation: 3,
      baseline: ReviewContent("old HEAD"),
      selected: test_modified_change(path),
    }),
  }
  let state = {
    ..owned_state(),
    explorer_mode: ExplorerChanges,
    changes: ChangeListLoading(refresh_again=true),
    changes_generation: 1,
    changes_head: Some("old-head"),
    changes_head_known: true,
    review_generation: 3,
    docs,
  }
  let ctx = { ..test_ctx(), open_files: [path], active_file: Some(path) }
  // The coalesced first reply is intermediate. Its temporary absence must not
  // clear the review or consume the new HEAD identity before the follow-up.
  let (_, following_up) = update(
    test_emit(),
    ChangesLoaded(
      owner=test_ctx().owner,
      generation=1,
      repository=true,
      head=Some("new-head"),
      files=[],
    ),
    state,
    ctx,
  )
  assert_true(
    following_up.docs.get(path)
    is Some(
      {
        review: Some({ generation: 3, baseline: ReviewContent("old HEAD"), .. }),
        ..,
      }
    ),
  )
  assert_true(following_up.changes_head == Some("old-head"))
  assert_true(following_up.changes_generation == 2)
  let files = [
    {
      path,
      original_path: None,
      index_status: " ",
      worktree_status: "M",
      kind: ChangeModified,
    },
  ]
  let (_, settled) = update(
    test_emit(),
    ChangesLoaded(
      owner=test_ctx().owner,
      generation=2,
      repository=true,
      head=Some("new-head"),
      files~,
    ),
    following_up,
    ctx,
  )
  assert_true(settled.changes_head == Some("new-head"))
  assert_true(settled.changes_head_known)
  assert_true(settled.review_generation == 4)
  assert_true(
    settled.docs.get(path)
    is Some(
      { review: Some({ generation: 4, baseline: ReviewLoading, .. }), .. }
    ),
  )
}

///|
test "Changes reconciliation preserves the selected duplicate-path row" {
  let path = @pathx.Relative("recreated.mbt")
  let deleted : ChangedFile = {
    path,
    original_path: None,
    index_status: "D",
    worktree_status: " ",
    kind: ChangeDeleted,
  }
  let untracked : ChangedFile = {
    path,
    original_path: None,
    index_status: "?",
    worktree_status: "?",
    kind: ChangeUntracked,
  }
  let ctx = { ..test_ctx(), open_files: [path], active_file: Some(path) }
  let (_, reviewing) = open_changed_document(
    test_emit(),
    owned_state(),
    ctx,
    untracked,
    had_active=false,
  )
  let refreshing = {
    ..reviewing,
    changes: ChangeListLoading(refresh_again=false),
    changes_generation: 1,
    changes_head: Some("old-head"),
    changes_head_known: true,
  }
  // Porcelain sorts both rows by the same path, with the staged deletion
  // first. A moved HEAD must refresh the selected untracked working side,
  // never silently turn the document into a deleted-file preview.
  let (_, settled) = update(
    test_emit(),
    ChangesLoaded(
      owner=ctx.owner,
      generation=1,
      repository=true,
      head=Some("new-head"),
      files=[deleted, untracked],
    ),
    refreshing,
    ctx,
  )
  assert_true(
    settled.docs.get(path)
    is Some(
      {
        state: TabLoading,
        review: Some({ generation: 2, baseline: ReviewLoading, selected }),
        ..,
      }
    ) &&
    selected == untracked,
  )
}

///|
test "moved HEAD normalizes reviewed tabs across the working-file boundary" {
  let path = @pathx.Relative("src/crossing.mbt")
  let ctx = { ..test_ctx(), open_files: [path], active_file: Some(path) }
  let deleted : ChangedFile = {
    path,
    original_path: None,
    index_status: " ",
    worktree_status: "D",
    kind: ChangeDeleted,
  }
  let loading_docs : Map[@pathx.Relative, Doc] = Map([])
  loading_docs[path] = {
    name: "crossing.mbt",
    state: TabLoading,
    review: Some({
      generation: 3,
      baseline: ReviewContent("old HEAD"),
      selected: test_modified_change(path),
    }),
    stale: true,
  }
  let loading = {
    ..owned_state(),
    explorer_mode: ExplorerChanges,
    changes: ChangeListLoading(refresh_again=false),
    changes_generation: 1,
    changes_head: Some("old-head"),
    changes_head_known: true,
    review_generation: 3,
    docs: loading_docs,
  }
  let (_, became_deleted) = update(
    test_emit(),
    ChangesLoaded(
      owner=ctx.owner,
      generation=1,
      repository=true,
      head=Some("new-head"),
      files=[deleted],
    ),
    loading,
    ctx,
  )
  assert_true(
    became_deleted.docs.get(path)
    is Some(
      {
        state: TabDeleted,
        review: Some({ generation: 4, baseline: ReviewLoading, .. }),
        stale: false,
        ..,
      }
    ),
  )

  let deleted_docs : Map[@pathx.Relative, Doc] = Map([])
  deleted_docs[path] = {
    name: "crossing.mbt",
    state: TabDeleted,
    review: Some({
      generation: 3,
      baseline: ReviewContent("old HEAD"),
      selected: deleted,
    }),
    stale: false,
  }
  let deleted_state = { ..loading, docs: deleted_docs }
  let restored = { ..deleted, worktree_status: "M", kind: ChangeModified }
  let (_, became_loading) = update(
    test_emit(),
    ChangesLoaded(
      owner=ctx.owner,
      generation=1,
      repository=true,
      head=Some("new-head"),
      files=[restored],
    ),
    deleted_state,
    ctx,
  )
  assert_true(
    became_loading.docs.get(path)
    is Some(
      {
        state: TabLoading,
        review: Some({ generation: 4, baseline: ReviewLoading, .. }),
        ..,
      }
    ),
  )
}

///|
test "a changed rename source refreshes its review without moving HEAD" {
  let path = @pathx.Relative("src/new.mbt")
  let previous : ChangedFile = {
    path,
    original_path: Some(@pathx.Relative("src/old.mbt")),
    index_status: "R",
    worktree_status: " ",
    kind: ChangeRenamed,
  }
  let current = {
    ..previous,
    original_path: None,
    index_status: "?",
    worktree_status: "?",
    kind: ChangeUntracked,
  }
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[path] = {
    ..loaded_doc(path.0),
    review: Some({
      generation: 3,
      baseline: ReviewContent("old source"),
      selected: previous,
    }),
  }
  let state = {
    ..owned_state(),
    changes: ChangeListReady(
      repository=true,
      files=[previous],
      refreshing=true,
      refresh_again=false,
    ),
    changes_generation: 1,
    changes_head: Some("same-head"),
    changes_head_known: true,
    review_generation: 3,
    docs,
  }
  let (_, settled) = update(
    test_emit(),
    ChangesLoaded(
      owner=test_ctx().owner,
      generation=1,
      repository=true,
      head=Some("same-head"),
      files=[current],
    ),
    state,
    { ..test_ctx(), open_files: [path], active_file: Some(path) },
  )
  assert_true(settled.review_generation == 4)
  assert_true(
    settled.docs.get(path)
    is Some(
      { review: Some({ generation: 4, baseline: ReviewLoading, .. }), .. }
    ),
  )
}

///|
test "only a visible settled Changes snapshot accepts its polling fallback" {
  let emit = test_emit()
  let state = {
    ..owned_state(),
    explorer_mode: ExplorerChanges,
    changes: ChangeListReady(
      repository=true,
      files=[],
      refreshing=false,
      refresh_again=false,
    ),
    changes_generation: 4,
  }
  let (_, refreshing) = update(
    emit,
    ChangesPollDue(owner=test_ctx().owner, generation=4),
    state,
    test_ctx(),
  )
  assert_true(refreshing.changes_generation == 5)
  assert_true(refreshing.changes is ChangeListReady(refreshing=true, ..))
  let (_, stale) = update(
    emit,
    ChangesPollDue(owner=test_ctx().owner, generation=4),
    refreshing,
    test_ctx(),
  )
  assert_true(stale == refreshing)
  let (_, hidden) = update(
    emit,
    ChangesPollDue(owner=test_ctx().owner, generation=4),
    state,
    { ..test_ctx(), panel_open: false },
  )
  assert_true(hidden == state)
  let (_, hidden_tree) = update(
    emit,
    ChangesPollDue(owner=test_ctx().owner, generation=4),
    { ..state, tree_open: false },
    { ..test_ctx(), active_file: Some(Relative("open.mbt")) },
  )
  assert_true(hidden_tree == { ..state, tree_open: false })
  let (_, files_mode) = update(
    emit,
    ChangesPollDue(owner=test_ctx().owner, generation=4),
    { ..state, explorer_mode: ExplorerFiles },
    test_ctx(),
  )
  assert_true(files_mode.explorer_mode is ExplorerFiles)
  assert_true(files_mode.changes_generation == 4)
}

///|
test "hidden explorer drops coalesced follow-ups when requests settle" {
  let emit = test_emit()
  let hidden = { ..test_ctx(), panel_open: false }
  let refreshing = {
    ..owned_state(),
    changes: ChangeListReady(
      repository=true,
      files=[],
      refreshing=true,
      refresh_again=true,
    ),
    changes_generation: 4,
  }
  let (_, loaded) = update(
    emit,
    ChangesLoaded(
      owner=test_ctx().owner,
      generation=4,
      repository=true,
      head=None,
      files=[],
    ),
    refreshing,
    hidden,
  )
  assert_true(loaded.changes_generation == 4)
  assert_true(
    loaded.changes is ChangeListReady(refreshing=false, refresh_again=false, ..),
  )
  let (_, failed_refresh) = update(
    emit,
    ChangesFailed(owner=test_ctx().owner, generation=4, message="git failed"),
    refreshing,
    hidden,
  )
  assert_true(failed_refresh.changes_generation == 4)
  assert_true(
    failed_refresh.changes
    is ChangeListReady(refreshing=false, refresh_again=false, ..),
  )
  let loading = {
    ..owned_state(),
    changes: ChangeListLoading(refresh_again=true),
    changes_generation: 4,
  }
  let (_, failed_load) = update(
    emit,
    ChangesFailed(owner=test_ctx().owner, generation=4, message="git failed"),
    loading,
    hidden,
  )
  assert_true(failed_load.changes_generation == 4)
  assert_true(failed_load.changes is ChangeListIdle)
  let (_, failed_unlatched_load) = update(
    emit,
    ChangesFailed(owner=test_ctx().owner, generation=4, message="git failed"),
    { ..loading, changes: ChangeListLoading(refresh_again=false) },
    hidden,
  )
  assert_true(failed_unlatched_load.changes_generation == 4)
  assert_true(failed_unlatched_load.changes is ChangeListIdle)
}

///|
test "conversation re-roots retain the change request generation" {
  let state = {
    ..owned_state(),
    owner: Some({
      channel: @interop.ChannelId::Remote("previous"),
      session: "previous-session",
    }),
    explorer_mode: ExplorerChanges,
    changes_generation: 7,
  }
  let (rerooted, _) = sync(test_emit(), state, test_ctx())
  assert_true(rerooted.owner == Some(test_ctx().owner))
  assert_true(rerooted.changes is ChangeListLoading(refresh_again=false))
  assert_true(rerooted.changes_generation == 8)
}

///|
test "watcher refresh keeps the ready change snapshot visible" {
  let emit = test_emit()
  let state = {
    ..owned_state(),
    changes: ChangeListReady(
      repository=true,
      files=[],
      refreshing=false,
      refresh_again=false,
    ),
  }
  let (_, refreshing) = update(
    emit,
    FsChanged(
      session=Some("desktop-test"),
      changes=Some([Modified(Relative("src/main.mbt"))]),
    ),
    state,
    test_ctx(),
  )
  assert_true(refreshing.changes_generation == 1)
  assert_true(
    refreshing.changes
    is ChangeListReady(
      repository=true,
      files=[],
      refreshing=true,
      refresh_again=false
    ),
  )
  let (_, latched) = update(
    emit,
    FsChanged(
      session=Some("desktop-test"),
      changes=Some([Modified(Relative("src/other.mbt"))]),
    ),
    refreshing,
    test_ctx(),
  )
  assert_true(
    latched.changes
    is ChangeListReady(
      repository=true,
      files=[],
      refreshing=true,
      refresh_again=true
    ),
  )
  // The first reply consumes the latch by starting one follow-up request; the
  // second reply settles the snapshot.
  let (_, following_up) = update(
    emit,
    ChangesLoaded(
      owner=test_ctx().owner,
      generation=1,
      repository=true,
      head=None,
      files=[],
    ),
    latched,
    test_ctx(),
  )
  assert_true(following_up.changes_generation == 2)
  assert_true(
    following_up.changes
    is ChangeListReady(
      repository=true,
      files=[],
      refreshing=true,
      refresh_again=false
    ),
  )
  let (_, settled) = update(
    emit,
    ChangesLoaded(
      owner=test_ctx().owner,
      generation=2,
      repository=true,
      head=None,
      files=[],
    ),
    following_up,
    test_ctx(),
  )
  assert_true(
    settled.changes
    is ChangeListReady(
      repository=true,
      files=[],
      refreshing=false,
      refresh_again=false
    ),
  )
}

///|
test "hidden explorer parks event-driven change refreshes until reopen" {
  let emit = test_emit()
  let state = {
    ..owned_state(),
    changes: ChangeListReady(
      repository=true,
      files=[],
      refreshing=false,
      refresh_again=false,
    ),
    changes_generation: 4,
  }
  let hidden = { ..test_ctx(), panel_open: false }
  let (_, after_watch) = update(
    emit,
    FsChanged(session=Some("desktop-test"), changes=Some([])),
    state,
    hidden,
  )
  assert_true(after_watch.changes_generation == 4)
  assert_true(after_watch.changes is ChangeListReady(refreshing=false, ..))
  let (_, after_run) = update(
    emit,
    RunSettled(owner=test_ctx().owner),
    after_watch,
    hidden,
  )
  assert_true(after_run.changes_generation == 4)
  assert_true(after_run.changes is ChangeListReady(refreshing=false, ..))
}

///|
test "hidden explorer keeps Git refresh live for an open review" {
  let path = @pathx.Relative("src/reviewed.mbt")
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[path] = {
    ..loaded_doc(path.0),
    review: Some({
      generation: 2,
      baseline: ReviewContent("old HEAD"),
      selected: test_modified_change(path),
    }),
  }
  let state = {
    ..owned_state(),
    changes: ChangeListReady(
      repository=true,
      files=[],
      refreshing=false,
      refresh_again=false,
    ),
    changes_generation: 4,
    docs,
  }
  let hidden = {
    ..test_ctx(),
    panel_open: false,
    open_files: [path],
    active_file: Some(path),
  }
  let (_, after_run) = update(
    test_emit(),
    RunSettled(owner=test_ctx().owner),
    state,
    hidden,
  )
  assert_true(after_run.changes_generation == 5)
  assert_true(after_run.changes is ChangeListReady(refreshing=true, ..))
  let (_, after_poll) = update(
    test_emit(),
    ChangesPollDue(owner=test_ctx().owner, generation=4),
    state,
    hidden,
  )
  assert_true(after_poll.changes_generation == 5)
  assert_true(after_poll.changes is ChangeListReady(refreshing=true, ..))
}

///|
test "sync refreshes a hidden review after its workspace watch was parked" {
  let path = @pathx.Relative("src/reviewed.mbt")
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[path] = {
    ..loaded_doc(path.0),
    review: Some({
      generation: 2,
      baseline: ReviewContent("old HEAD"),
      selected: test_modified_change(path),
    }),
  }
  let state = {
    ..owned_state(),
    explorer_was_visible: false,
    watching: None,
    changes: ChangeListReady(
      repository=true,
      files=[],
      refreshing=false,
      refresh_again=false,
    ),
    changes_generation: 4,
    docs,
  }
  let hidden = {
    ..test_ctx(),
    panel_open: false,
    open_files: [path],
    active_file: Some(path),
  }
  let (refreshed, _) = sync(test_emit(), state, hidden)
  assert_true(refreshed.changes_generation == 5)
  assert_true(refreshed.changes is ChangeListReady(refreshing=true, ..))
}

///|
test "change-list failures stay isolated from file errors and watcher retries" {
  let emit = test_emit()
  let state = {
    ..owned_state(),
    changes: ChangeListLoading(refresh_again=false),
    changes_generation: 1,
    error: Some("file read failed"),
  }
  let (_, failed) = update(
    emit,
    ChangesFailed(owner=test_ctx().owner, generation=1, message="git failed"),
    state,
    test_ctx(),
  )
  assert_true(failed.changes is ChangeListFailed("git failed"))
  assert_true(failed.error == Some("file read failed"))
  // A watcher event does not hammer an already-failed request. A settled run
  // or an explicit Changes click remains the retry boundary.
  let (_, still_failed) = update(
    emit,
    FsChanged(
      session=Some("desktop-test"),
      changes=Some([Modified(Relative("src/main.mbt"))]),
    ),
    failed,
    test_ctx(),
  )
  assert_true(still_failed.changes is ChangeListFailed("git failed"))
  let (_, retrying) = update(
    emit,
    RunSettled(owner=test_ctx().owner),
    still_failed,
    test_ctx(),
  )
  assert_true(retrying.changes is ChangeListLoading(refresh_again=false))
  assert_true(retrying.changes_generation == 2)
}

///|
test "StatsLoaded marks deletions, reloads the active change, stales the rest" {
  let emit = test_emit()
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[Relative("a.mbt")] = loaded_doc("a.mbt")
  docs[Relative("b.mbt")] = loaded_doc("b.mbt")
  docs[Relative("c.mbt")] = loaded_doc("c.mbt")
  let state = { ..owned_state(), docs, }
  let ctx = {
    ..test_ctx(),
    open_files: [Relative("a.mbt"), Relative("b.mbt"), Relative("c.mbt")],
    active_file: Some(Relative("a.mbt")),
  }
  let (_, next) = update(
    emit,
    StatsLoaded(owner=test_ctx().owner, stats=[
      // The active file changed: reloaded eagerly, so its document stays
      // loaded (the baseline the scroll-keeping reload compares against).
      { path: Relative("a.mbt"), sig: Some("9:0") },
      // A background file changed: only marked stale.
      { path: Relative("b.mbt"), sig: Some("9:0") },
      // Deleted: the document flips to the deleted notice state.
      { path: Relative("c.mbt"), sig: None },
    ]),
    state,
    ctx,
  )
  assert_true(
    next.docs.get(Relative("a.mbt"))
    is Some({ state: TabLoaded(..), stale: false, .. }),
  )
  assert_true(next.docs.get(Relative("b.mbt")) is Some({ stale: true, .. }))
  assert_true(
    next.docs.get(Relative("c.mbt")) is Some({ state: TabDeleted, .. }),
  )
  // An unchanged signature on a background file still compares against the
  // loaded baseline.
  let solo : Map[@pathx.Relative, Doc] = Map([])
  solo[Relative("b.mbt")] = loaded_doc("b.mbt")
  let (_, same) = update(
    emit,
    StatsLoaded(owner=test_ctx().owner, stats=[
      { path: Relative("b.mbt"), sig: Some("9:0") },
    ]),
    { ..next, docs: solo },
    { ..ctx, active_file: None },
  )
  assert_true(
    same.docs.get(Relative("b.mbt"))
    is Some({ state: TabLoaded(sig="1:0", ..), stale: true, .. }),
  )
  // A watcher proving a previously unreadable review path exists makes a
  // background tab retryable on activation.
  let failed_path = @pathx.Relative("failed.mbt")
  let failed_docs : Map[@pathx.Relative, Doc] = Map([])
  failed_docs[failed_path] = {
    name: "failed.mbt",
    state: TabReadFailed("temporary failure"),
    review: Some({
      generation: 4,
      baseline: ReviewContent("HEAD source"),
      selected: test_modified_change(failed_path),
    }),
    stale: false,
  }
  let (_, retryable) = update(
    emit,
    StatsLoaded(owner=test_ctx().owner, stats=[
      { path: failed_path, sig: Some("10:0") },
    ]),
    { ..owned_state(), docs: failed_docs },
    { ..ctx, active_file: None },
  )
  assert_true(
    retryable.docs.get(failed_path)
    is Some({ state: TabReadFailed(_), review: Some(_), stale: true, .. }),
  )
  // A reply from another conversation is dropped.
  let (_, other) = update(
    emit,
    StatsLoaded(
      owner={
        channel: @interop.ChannelId::Remote("other"),
        session: "desktop-test",
      },
      stats=[{ path: Relative("a.mbt"), sig: None }],
    ),
    state,
    ctx,
  )
  assert_true(
    other.docs.get(Relative("a.mbt")) is Some({ state: TabLoaded(..), .. }),
  )
}

///|
test "StatsLoaded preserves a settled HEAD preview when its active file disappears" {
  let emit = test_emit()
  let path = @pathx.Relative("reviewed.mbt")
  let doc = {
    ..loaded_doc("reviewed.mbt"),
    review: Some({
      generation: 7,
      baseline: ReviewContent("HEAD source"),
      selected: test_modified_change(path),
    }),
  }
  let docs : Map[@pathx.Relative, Doc] = Map([(path, doc)])
  let (_, next) = update(
    emit,
    StatsLoaded(owner=test_ctx().owner, stats=[{ path, sig: None }]),
    { ..owned_state(), docs, },
    { ..test_ctx(), open_files: [path], active_file: Some(path) },
  )
  assert_true(
    next.docs.get(path)
    is Some(
      {
        state: TabDeleted,
        review: Some(
          { generation: 7, baseline: ReviewContent("HEAD source"), .. }
        ),
        stale: false,
        ..,
      }
    ),
  )
}

///|
test "a deleted document whose file reappears reloads on the next stats" {
  let emit = test_emit()
  let docs : Map[@pathx.Relative, Doc] = Map([])
  docs[Relative("a.mbt")] = {
    name: "a.mbt",
    state: TabDeleted,
    review: None,
    stale: false,
  }
  let state = { ..owned_state(), docs, }
  let (_, next) = update(
    emit,
    StatsLoaded(owner=test_ctx().owner, stats=[
      { path: Relative("a.mbt"), sig: Some("3:0") },
    ]),
    state,
    { ..test_ctx(), open_files: [Relative("a.mbt")] },
  )
  // Background reappearance: stale, reloaded on activation.
  assert_true(
    next.docs.get(Relative("a.mbt"))
    is Some({ state: TabDeleted, stale: true, .. }),
  )
}

///|
test "watcher baseline re-lists the root and expanded, listed directories" {
  let emit = test_emit()
  let children : Map[@pathx.Relative, Array[FileEntry]] = Map([])
  children[Relative("")] = []
  children[Relative("src")] = []
  let state = {
    ..owned_state(),
    children,
    expanded: [Relative("src"), Relative("never-listed")],
  }
  let baseline = FsChanged(session=Some("desktop-test"), changes=None)
  let (_, next) = update(emit, baseline, state, test_ctx())
  // Both known directories are marked in flight; the never-listed one is
  // left to its own first expansion.
  assert_true(next.loading.contains(Relative("")))
  assert_true(next.loading.contains(Relative("src")))
  assert_false(next.loading.contains(Relative("never-listed")))
  // A second push while the lists are in flight stacks nothing.
  let (_, again) = update(emit, baseline, next, test_ctx())
  assert_eq(again.loading.length(), next.loading.length())
}

///|
test "concrete watcher events refresh only affected listed directories" {
  let emit = test_emit()
  let children : Map[@pathx.Relative, Array[FileEntry]] = Map([])
  children[Relative("")] = []
  children[Relative("src")] = []
  children[Relative("docs")] = []
  let state = {
    ..owned_state(),
    children,
    expanded: [Relative("src"), Relative("docs")],
  }
  let message = FsChanged(
    session=Some("desktop-test"),
    changes=Some([Created(Relative("src/new.mbt"))]),
  )
  let (_, first) = update(emit, message, state, test_ctx())
  assert_true(first.loading == [Relative("src")])
  // Rabbita purity: the same message and model produce the same state.
  let (_, second) = update(emit, message, state, test_ctx())
  assert_true(first.loading == second.loading)
  // A late batch from the previous conversation is ignored.
  let (_, stale) = update(
    emit,
    FsChanged(
      session=Some("previous-session"),
      changes=Some([Created(Relative("docs/new.md"))]),
    ),
    state,
    test_ctx(),
  )
  assert_true(stale.loading.is_empty())
}

///|
test "moonbit-relevant changes cover sources, interfaces, and manifests" {
  assert_true(Modified(Relative("src/lib.mbt")).moonbit_relevant())
  assert_true(Removed(Relative("pkg.generated.mbti")).moonbit_relevant())
  assert_true(Created(Relative("README.mbt.md")).moonbit_relevant())
  assert_true(Modified(Relative("src/moon.pkg")).moonbit_relevant())
  assert_true(Modified(Relative("moon.mod")).moonbit_relevant())
  assert_true(
    Renamed(old=Relative("notes.md"), new=Relative("src/a.mbt")).moonbit_relevant(),
  )
  assert_false(Modified(Relative("README.md")).moonbit_relevant())
  assert_false(Modified(Relative("src/notmoon.pkg.bak")).moonbit_relevant())
  assert_false(Created(Relative("assets/logo.png")).moonbit_relevant())
}

///|
test "sync reconciles the watcher with the panel and its open files" {
  let emit = test_emit()
  // Open panel: watch the active session.
  let (watched, _) = sync(
    emit,
    { ..owned_state(), watch_error: Some("old watcher failure") },
    test_ctx(),
  )
  assert_true(
    watched.watching
    is Some(
      {
        owner: { session: "desktop-test", .. },
        workspace: None,
        files: [],
        directories: [Relative("")],
      }
    ),
  )
  // Issuing a new watch attempt retires the previous failure.
  assert_true(watched.watch_error is None)
  // Opening a file or expanding a directory replaces the same conversation's
  // watcher with the new exact selection.
  let selected_ctx = { ..test_ctx(), open_files: [Relative("a.mbt")] }
  let selected = { ..watched, expanded: [Relative("src")] }
  let (replaced, _) = sync(emit, selected, selected_ctx)
  assert_true(
    replaced.watching
    is Some(
      {
        files: [Relative("a.mbt")],
        directories: [Relative(""), Relative("src")],
        ..,
      }
    ),
  )
  // Closed panel with files still open: keep watching (staleness tracking).
  let still_ctx = {
    ..test_ctx(),
    panel_open: false,
    open_files: [Relative("a.mbt")],
  }
  let closed = { ..replaced, children: Map([]), loading: [] }
  let (still, _) = sync(emit, closed, still_ctx)
  assert_true(
    still.watching is Some({ files: [Relative("a.mbt")], directories: [], .. }),
  )
  // Closed panel, nothing open: park the watcher.
  let (parked, _) = sync(emit, still, { ..test_ctx(), panel_open: false })
  assert_true(parked.watching is None)
}

///|
test "watcher failures are visible only in their owning conversation" {
  let emit = test_emit()
  let owner = test_ctx().owner
  let (_, failed) = update(
    emit,
    FileWatchFailed(owner~, message="File watching stopped"),
    owned_state(),
    test_ctx(),
  )
  assert_true(failed.watch_error is Some("File watching stopped"))
  let other : @interop.ConversationKey = {
    channel: @interop.ChannelId::Remote("other"),
    session: owner.session,
  }
  let (_, unchanged) = update(
    emit,
    FileWatchFailed(owner=other, message="stale failure"),
    failed,
    test_ctx(),
  )
  assert_true(unchanged.watch_error is Some("File watching stopped"))
}
