// The worktree launch mode: a fresh conversation in a workspace can run in
// a host-named git worktree instead of the workspace root — its own
// execution environment, bound 1:1 to the conversation. The composer
// carries the mode toggle; the first submit
// creates the worktree and starts the run in one command. Sidebar rows of
// worktree conversations wear a name chip joined from the registry, and
// clicking the chip stages the removal flow.

///|
/// One registry row of `worktree.list` / `worktree.changed`, reduced to
/// what the sidebar reads: the name (chip), the bound session (chip join),
/// and whether the checkout still exists on disk.
priv struct WorktreeRow {
  name : String
  session : String?
  present : Bool
} derive(Eq)

///|
/// One workspace's worktree rows, keyed by the registry path the host also
/// uses in `worktree.changed`. `generation` is the request token the rows
/// were applied under — the staleness fence is per workspace, so a
/// broadcast for one workspace can never discard another's still-current
/// list reply.
priv struct WorkspaceWorktrees {
  workspace : String
  rows : Array[WorktreeRow]
  generation : Int
} derive(Eq)

///|
/// The archive-discard confirmation: the host refused to archive because
/// the conversation's worktree holds uncommitted changes; confirming
/// retries the archive with force. `message` is the host's own refusal
/// text, which names the worktree.
priv struct ArchiveConfirm {
  channel : @interop.ChannelId
  session : String
  message : String
} derive(Eq)

///|
fn fetch_worktrees(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  workspace : String,
  connection_generation : Int,
  request_generation : Int,
) -> @cmd.Cmd {
  let dispatch = dispatch.map((msg : DeviceMsg) => FromDevice(channel, msg))
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      // A host without the op just reads as "no worktrees".
      let reply : @protocol.WorktreesReply = @interop.bridge_request(
        channel,
        @commands.worktree_list,
        { workspace, },
      ) catch {
        _ => return
      }
      scheduler.add(
        dispatch(
          WorktreesLoaded(
            worktree_rows(reply.worktrees),
            workspace~,
            connection_generation~,
            request_generation~,
          ),
        ),
      )
    })
  })
}

///|
/// The worktree launch mode's first start: create the environment (the
/// host names it), bind the composing conversation, then fire the same
/// `agent.start` a plain submit would — one command, so a create failure
/// settles through the ordinary start-rejection path and restores the
/// draft.
fn start_in_new_worktree(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  task : String,
  submission_id : String,
  selected_model : String,
  max_steps : String,
  session : String,
  workspace : @pathx.Absolute,
) -> @cmd.Cmd {
  let device_dispatch = dispatch.map((msg : DeviceMsg) => {
    FromDevice(channel, msg)
  })
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      // The session is the create's idempotency key: a retry after a lost
      // reply gets the same worktree back instead of minting a second one.
      let reply : @protocol.WorktreeCreateReply = @interop.bridge_request(
        channel,
        @commands.worktree_create,
        { workspace: workspace.0, session },
      ) catch {
        error => {
          // Nothing started: reject the submission so the draft restores.
          scheduler.add(
            device_dispatch(
              StartRejected(
                session~,
                submission_id~,
                message="worktree setup failed: " +
                  @interop.bridge_error_text(error),
              ),
            ),
          )
          return
        }
      }
      // The host generates the name; the reply carries it so the chain
      // knows what to bind.
      guard !reply.name.is_empty() else {
        scheduler.add(
          device_dispatch(
            StartRejected(
              session~,
              submission_id~,
              message="malformed worktree.create reply",
            ),
          ),
        )
        return
      }
      // Bind the conversation's local state before the start settles, so
      // the chip and a retried submit both know the environment. The
      // canonical registry list still arrives as `worktree.changed` from
      // the commit seam, and the start itself carries no worktree — the
      // host routes the bound session's cwd through the registry.
      scheduler.add(
        device_dispatch(
          WorktreeCreated(workspace=workspace.0, name=reply.name, session~),
        ),
      )
      let start = start_payload(
        task,
        selected_model,
        max_steps,
        session,
        submission_id,
        workspace=Some(workspace),
      )
      request_agent_start(
        scheduler, dispatch, channel, start, session, submission_id,
      )
    })
  })
}

///|
/// Rebuild a checkout that was deleted outside the app. The host repairs the
/// existing registry entry on its surviving branch, so this restores the
/// conversation's real environment; the canonical rows arrive as
/// `worktree.changed` from the commit seam.
fn repair_worktree_cmd(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  workspace : String,
  session : String,
) -> @cmd.Cmd {
  let dispatch = dispatch.map((msg : DeviceMsg) => FromDevice(channel, msg))
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let _ : @protocol.WorktreeCreateReply = @interop.bridge_request(
        channel,
        @commands.worktree_create,
        { workspace, session },
      ) catch {
        error => {
          scheduler.add(
            dispatch(WorktreeFailed(@interop.bridge_error_text(error))),
          )
          return
        }
      }
    })
  })
}

///|
/// Release a conversation from a worktree whose checkout is gone: dropping
/// the registry row unbinds it, and the host then runs it in the workspace
/// itself. Never forced — the checkout it would have discarded no longer
/// exists.
fn release_worktree_cmd(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  workspace : String,
  name : String,
) -> @cmd.Cmd {
  let dispatch = dispatch.map((msg : DeviceMsg) => FromDevice(channel, msg))
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let _ : @protocol.WorktreesReply = @interop.bridge_request(
        channel,
        @commands.worktree_remove,
        { workspace, name, force: None },
      ) catch {
        error => {
          scheduler.add(
            dispatch(WorktreeFailed(@interop.bridge_error_text(error))),
          )
          return
        }
      }
    })
  })
}

///|
/// Reduce the typed registry rows shared by list replies and the host's
/// post-commit broadcast to what the sidebar reads, dropping blank names
/// and blank session ids a hand-edited registry file could carry.
fn worktree_rows(infos : Array[@protocol.WorktreeInfo]) -> Array[WorktreeRow] {
  let rows : Array[WorktreeRow] = []
  for info in infos {
    guard !info.name.is_empty() else { continue }
    rows.push({
      name: info.name,
      session: if info.session is Some(id) && !id.is_empty() {
        Some(id)
      } else {
        None
      },
      present: info.present,
    })
  }
  rows
}

///|
/// The `worktree.changed` notification: the workspace it belongs to plus its
/// canonical post-commit rows.
fn worktree_changed_msg(
  payload : @protocol.WorktreeChangedPayload,
) -> DeviceMsg? {
  guard !payload.workspace.is_empty() else { return None }
  Some(
    WorktreesChanged(
      worktree_rows(payload.worktrees),
      workspace=payload.workspace,
    ),
  )
}

///|
/// The registry row for a durable session's worktree, if one binds it.
fn worktree_row_for(
  dev : DeviceState,
  workspace : String,
  session : String,
) -> WorktreeRow? {
  guard !workspace.is_empty() else { return None }
  for group in dev.worktrees {
    guard group.workspace == workspace else { continue }
    for row in group.rows {
      if row.session is Some(bound) && bound == session {
        return Some(row)
      }
    }
  }
  None
}

///|
/// The worktree a durable session runs in — the sidebar chip's data source.
fn worktree_name_for(
  dev : DeviceState,
  workspace : String,
  session : String,
) -> String? {
  worktree_row_for(dev, workspace, session).map(row => row.name)
}

///|
/// The worktree a conversation is bound to whose checkout no longer exists,
/// deleted outside the app. The host refuses to run such a conversation
/// rather than silently moving it into the main checkout, so the composer
/// says so and offers the way out.
fn missing_worktree_for(model : Model, conv : Conversation) -> String? {
  guard model.device_state(conv.device) is Some(dev) else { return None }
  guard worktree_row_for(dev, workspace_token(conv.workspace), conv.session_id)
    is Some(row) else {
    return None
  }
  if row.present {
    None
  } else {
    Some(row.name)
  }
}

///|
fn DeviceState::with_worktrees(
  self : DeviceState,
  workspace : String,
  rows : Array[WorktreeRow],
  generation~ : Int,
) -> DeviceState {
  let groups = self.worktrees.filter(group => group.workspace != workspace)
  groups.push({ workspace, rows, generation })
  { ..self, worktrees: groups }
}

///|
/// The token one workspace's rows were last applied under; a reply carrying
/// an older token is stale for that workspace alone.
fn DeviceState::worktree_generation(
  self : DeviceState,
  workspace : String,
) -> Int {
  for group in self.worktrees {
    if group.workspace == workspace {
      return group.generation
    }
  }
  -1
}

///|
/// Whether the next submit should run the create-then-start chain: the
/// composer chose worktree mode, nothing is bound yet, and the
/// conversation has no durable history. Local overlay notices — exactly
/// what a rejected setup attempt leaves behind — deliberately do not
/// count: the retry after a failed create must re-enter the chain, never
/// silently fall back to the workspace root.
fn Conversation::wants_fresh_worktree(self : Conversation) -> Bool {
  self.worktree_mode && self.worktree is None && self.messages.length() == 0
}

///|
/// The composer's launch-mode chip: visible while the conversation can
/// still choose (a workspace conversation that has not begun), fixed to
/// the worktree's name once the chain has bound one.
fn worktree_mode_chip(
  dispatch : @cmd.Emit[Msg],
  conv : Conversation,
) -> @html.Html? {
  // Durable emptiness, not `has_begun`: a rejected setup attempt leaves a
  // local overlay notice, and hiding the toggle then would lock the user
  // into retrying the failing create with no way back to Local.
  guard conv.workspace is Some(_) && conv.messages.length() == 0 else {
    return None
  }
  if conv.worktree is Some(name) {
    return Some(
      @html.span(
        class="composer-worktree on",
        title="This chat runs in worktree \{name}",
        [icon(icon_worktree), @html.span(name)],
      ),
    )
  }
  let (class, label, title) = if conv.worktree_mode {
    (
      "composer-worktree on", "Worktree", "First prompt creates a git worktree and runs there — click for local",
    )
  } else {
    (
      "composer-worktree", "Local", "Runs in the workspace itself — click to run in a fresh git worktree",
    )
  }
  Some(
    @html.button(
      class~,
      type_="button",
      title~,
      on_click=dispatch(ToggleWorktreeMode),
      [icon(icon_worktree), @html.span(label)],
    ),
  )
}

///|
/// The banner above the composer when this conversation's worktree checkout
/// was deleted outside the app. The host refuses to run the conversation in
/// that state, so the banner names the reason and carries both ways out
/// rather than leaving the user at a dead end. Committed work is safe either
/// way — it lives on the branch, which the deletion did not touch.
fn missing_worktree_notice(
  dispatch : @cmd.Emit[Msg],
  name : String,
) -> @html.Html {
  @html.div(class="composer-notice", [
    @html.span(
      class="composer-notice-text",
      "Worktree \{name} is gone — its checkout was deleted outside OpenSeek. Commits on its branch are safe.",
    ),
    @html.button(
      class="composer-notice-btn",
      type_="button",
      title="Check the branch out again at .worktrees/\{name}",
      on_click=dispatch(RepairWorktree),
      "Rebuild it",
    ),
    @html.button(
      class="composer-notice-btn",
      type_="button",
      title="Forget the worktree and continue in the workspace itself",
      on_click=dispatch(ReleaseWorktree),
      "Use the workspace",
    ),
  ])
}

///|
/// The archive-discard dialog (the `update_confirm_modal` shape): archiving
/// takes the worktree with the conversation, and this is the one moment
/// uncommitted changes can be lost — only behind this explicit confirm.
fn archive_discard_modal(
  dispatch : @cmd.Emit[Msg],
  confirm : ArchiveConfirm,
) -> @html.Html {
  @html.div(class="modal-backdrop", on_click=dispatch(CancelArchiveDiscard), [
    @html.div(class="modal", [
      @html.div(class="modal-title", "Archive this chat?"),
      @html.div(
        class="modal-body",
        "\{confirm.message}. Committed work stays on the worktree's branch; only uncommitted changes are discarded.",
      ),
      @html.div(class="modal-actions", [
        @html.button(on_click=dispatch(CancelArchiveDiscard), "Keep working"),
        @html.button(
          class="primary",
          on_click=dispatch(ConfirmArchiveDiscard),
          "Discard and archive",
        ),
      ]),
    ]),
  ])
}

// Tests for the worktree flow's pure pieces: the notification decoder and
// the update handlers that flag the launch mode, bind the chain's created
// environment, adopt registry rows, and stage removals.

///|
fn test_worktree_rows() -> Array[WorktreeRow] {
  [{ name: "wt", session: Some("desktop-wt"), present: true }]
}

///|
test "worktree commit decoder carries the workspace and its rows" {
  let row : Json = {
    "name": "wt",
    "branch": "openseek/wt",
    "base": "main",
    "session": "s1",
    "path": "/proj/.worktrees/wt",
    "present": true,
  }
  guard @protocol.Notification::from_wire("worktree.changed", {
      "workspace": "/proj",
      "worktrees": [row],
    })
    is Some(notification) else {
    fail("known notification was rejected")
  }
  guard bridge_msg(@interop.ChannelId::Local, notification)
    is Some(FromDevice(_, WorktreesChanged(rows, workspace~))) else {
    fail("expected a worktree change")
  }
  inspect(workspace, content="/proj")
  inspect(rows.length(), content="1")
  inspect(rows[0].name, content="wt")
  assert_eq(rows[0].session, Some("s1"))
  assert_true(rows[0].present)
  // A broadcast without its workspace is structurally unusable.
  assert_true(
    @protocol.Notification::from_wire("worktree.changed", { "worktrees": [] })
    is None,
  )
}

///|
test "proton subscribes to the worktree commit notification" {
  assert_true(proton_event_methods().contains(WorktreeChanged))
}

///|
test "the launch mode toggles only before the conversation begins" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    workspace: Some(Absolute("/proj")),
  })
  let (_, on) = update(dispatch, ToggleWorktreeMode, model)
  assert_true(on.active().worktree_mode)
  let (_, off) = update(dispatch, ToggleWorktreeMode, on)
  assert_false(off.active().worktree_mode)
  // A begun conversation keeps its environment; the toggle is inert.
  let begun = test_model().replace_conversation({
    ..test_conversation(),
    workspace: Some(Absolute("/proj")),
    messages: [{ kind: User, content: "hi" }],
  })
  let (_, still) = update(dispatch, ToggleWorktreeMode, begun)
  assert_false(still.active().worktree_mode)
  // A scratch conversation has no workspace to fork from.
  let (_, scratch) = update(dispatch, ToggleWorktreeMode, test_model())
  assert_false(scratch.active().worktree_mode)
}

///|
test "worktree created binds the composing conversation" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    workspace: Some(Absolute("/proj")),
    worktree_mode: true,
  })
  let (_, bound) = update_dev(
    dispatch,
    WorktreeCreated(workspace="/proj", name="wt-1", session="desktop-test"),
    model,
  )
  assert_true(bound.active().worktree is Some("wt-1"))
  assert_false(bound.active().worktree_mode)
  // A created notice for an unknown session changes nothing.
  let (_, unknown) = update_dev(
    dispatch,
    WorktreeCreated(workspace="/proj", name="wt-2", session="desktop-else"),
    bound,
  )
  assert_true(unknown.active().worktree is Some("wt-1"))
}

///|
test "a vanished checkout is surfaced and both recoveries stay reachable" {
  let dispatch = test_dispatch()
  let bound = test_model()
    .replace_conversation({
      ..test_conversation(),
      workspace: Some(Absolute("/proj")),
      worktree: Some("wt"),
    })
    .with_dev(dev => {
      ..dev,
      workspaces: ["/proj"],
      worktrees: [
        {
          workspace: "/proj",
          rows: [{ name: "wt", session: Some("desktop-test"), present: true }],
          generation: 1,
        },
      ],
    })
  // A live checkout says nothing.
  assert_true(missing_worktree_for(bound, bound.active()) is None)
  // The row survives the external deletion carrying `present: false` — that
  // is what distinguishes it from our own removal, which drops the row.
  let (_, gone) = update_dev(
    dispatch,
    WorktreesChanged(
      [{ name: "wt", session: Some("desktop-test"), present: false }],
      workspace="/proj",
    ),
    bound,
  )
  assert_eq(missing_worktree_for(gone, gone.active()), Some("wt"))
  // The binding is NOT dropped: releasing it is the user's choice, and the
  // conversation must not silently read as a plain workspace chat.
  assert_true(gone.active().worktree is Some("wt"))
  // Neither exit mutates optimistically: the registry is the authority, and
  // both recoveries land as a `worktree.changed` broadcast.
  let (_, repairing) = update(dispatch, RepairWorktree, gone)
  assert_eq(missing_worktree_for(repairing, repairing.active()), Some("wt"))
  assert_true(repairing.active().worktree is Some("wt"))
  let (_, releasing) = update(dispatch, ReleaseWorktree, gone)
  assert_eq(missing_worktree_for(releasing, releasing.active()), Some("wt"))
  // Both are inert for a healthy conversation, so a stale click cannot
  // rebuild or release a worktree that is fine.
  let (_, noop) = update(dispatch, ReleaseWorktree, bound)
  assert_true(noop.active().worktree is Some("wt"))
  assert_true(missing_worktree_for(noop, noop.active()) is None)
  // Once the host prunes the row, the conversation is an ordinary workspace
  // chat again and the banner goes away.
  let (_, released) = update_dev(
    dispatch,
    WorktreesChanged([], workspace="/proj"),
    gone,
  )
  assert_true(missing_worktree_for(released, released.active()) is None)
  assert_true(released.active().worktree is None)
}

///|
test "a worktree mode submit opens the run like any other" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    workspace: Some(Absolute("/proj")),
    worktree_mode: true,
    task: "go",
  })
  let (_, sent) = update(dispatch, Send, model)
  assert_true(sent.active().run is Starting(..))
  inspect(sent.active().task, content="")
  // The mode survives until the chain's create binds a name, so a rejected
  // create (which restores the draft) can retry in the same mode.
  assert_true(sent.active().worktree_mode)
}

///|
test "worktrees loaded respects the request generation fence" {
  let dispatch = test_dispatch()
  let model = test_model().with_dev(dev => {
    ..dev,
    worktrees_request_generation: 2,
  })
  let (_, applied) = update_dev(
    dispatch,
    WorktreesLoaded(
      test_worktree_rows(),
      workspace="/proj",
      connection_generation=0,
      request_generation=2,
    ),
    model,
  )
  assert_true(
    worktree_name_for(applied.dev(), "/proj", "desktop-wt") is Some("wt"),
  )
  let (_, stale) = update_dev(
    dispatch,
    WorktreesLoaded(
      [],
      workspace="/proj",
      connection_generation=0,
      request_generation=1,
    ),
    applied,
  )
  assert_true(
    worktree_name_for(stale.dev(), "/proj", "desktop-wt") is Some("wt"),
  )
}

///|
test "a broadcast for one workspace never fences a sibling's reply" {
  let dispatch = test_dispatch()
  // One fan-out round (token 1) has replies for /a and /b in flight; /a's
  // broadcast lands between them. /b's still-current reply must apply.
  let model = test_model().with_dev(dev => {
    ..dev,
    workspaces: ["/a", "/b"],
    worktrees_request_generation: 1,
  })
  let (_, changed) = update_dev(
    dispatch,
    WorktreesChanged(
      [{ name: "wt-a", session: Some("s-a"), present: true }],
      workspace="/a",
    ),
    model,
  )
  let (_, both) = update_dev(
    dispatch,
    WorktreesLoaded(
      [{ name: "wt-b", session: Some("s-b"), present: true }],
      workspace="/b",
      connection_generation=0,
      request_generation=1,
    ),
    changed,
  )
  assert_true(worktree_name_for(both.dev(), "/a", "s-a") is Some("wt-a"))
  assert_true(worktree_name_for(both.dev(), "/b", "s-b") is Some("wt-b"))
  // /a's own in-flight round-1 reply IS fenced by its broadcast.
  let (_, fenced) = update_dev(
    dispatch,
    WorktreesLoaded(
      [],
      workspace="/a",
      connection_generation=0,
      request_generation=1,
    ),
    both,
  )
  assert_true(worktree_name_for(fenced.dev(), "/a", "s-a") is Some("wt-a"))
}

///|
test "a worktree commit broadcast supersedes lists and unbinds removed names" {
  let dispatch = test_dispatch()
  let model = test_model()
    .replace_conversation({
      ..test_conversation(),
      workspace: Some(Absolute("/proj")),
      worktree: Some("wt"),
      cwd: Some(Absolute("/proj/.worktrees/wt")),
      branch: Some("openseek/wt"),
    })
    .with_dev(dev => {
      ..dev,
      workspaces: ["/proj"],
      worktrees: [
        { workspace: "/proj", rows: test_worktree_rows(), generation: 1 },
      ],
      worktrees_request_generation: 1,
    })
  let (_, changed) = update_dev(
    dispatch,
    WorktreesChanged([], workspace="/proj"),
    model,
  )
  inspect(changed.dev().worktrees_request_generation, content="2")
  assert_true(worktree_name_for(changed.dev(), "/proj", "desktop-wt") is None)
  // The removed worktree's conversation is a plain workspace conversation
  // now — exactly what the host's registry prune did to the mapping — and
  // every placement derived from the dead checkout (cwd for open/launch,
  // the composer's branch chip) went with it.
  assert_true(changed.active().worktree is None)
  assert_true(changed.active().cwd is None)
  assert_true(changed.active().branch is None)
  let (_, stale) = update_dev(
    dispatch,
    WorktreesLoaded(
      test_worktree_rows(),
      workspace="/proj",
      connection_generation=0,
      request_generation=1,
    ),
    changed,
  )
  assert_true(worktree_name_for(stale.dev(), "/proj", "desktop-wt") is None)
}

///|
test "a failed worktree setup keeps the retry eligible" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    workspace: Some(Absolute("/proj")),
    worktree_mode: true,
    task: "go",
  })
  let (_, sent) = update(dispatch, Send, model)
  guard sent.active().input_ledger is [entry] else {
    fail("expected the submission in the ledger")
  }
  let (_, rejected) = update_dev(
    dispatch,
    StartRejected(
      session="desktop-test",
      submission_id=entry.submission_id,
      message="worktree setup failed: boom",
    ),
    sent,
  )
  // The rejection leaves a local overlay notice — which must NOT disqualify
  // the retry: the next submit re-enters the create-then-start chain
  // instead of silently running in the workspace root.
  assert_true(rejected.active().overlay.length() > 0)
  assert_true(rejected.active().worktree_mode)
  assert_true(rejected.active().wants_fresh_worktree())
  // And the escape hatch stays open: the toggle still switches the chat
  // back to Local despite the overlay notice.
  let (_, switched) = update(dispatch, ToggleWorktreeMode, rejected)
  assert_false(switched.active().worktree_mode)
}

///|
test "a remote removal closes this client's discard dialog" {
  let dispatch = test_dispatch()
  let model = test_model()
    .replace_conversation({
      ..test_conversation(),
      workspace: Some(Absolute("/proj")),
      worktree: Some("wt"),
    })
    .with_dev(dev => {
      ..dev,
      workspaces: ["/proj"],
      worktrees: [
        { workspace: "/proj", rows: test_worktree_rows(), generation: 1 },
      ],
    })
  let (_, staged) = update_dev(
    dispatch,
    ArchiveNeedsForce(session="desktop-test", message="dirty"),
    model,
  )
  assert_true(staged.archive_confirm is Some(_))
  // A broadcast for an unrelated workspace leaves the dialog alone…
  let (_, unrelated) = update_dev(
    dispatch,
    WorktreesChanged([], workspace="/other"),
    staged,
  )
  assert_true(unrelated.archive_confirm is Some(_))
  // …but the session's own mapping disappearing (another client removed or
  // force-archived it) closes the dialog: its confirm would be stale.
  let (_, swept) = update_dev(
    dispatch,
    WorktreesChanged([], workspace="/proj"),
    unrelated,
  )
  assert_true(swept.archive_confirm is None)
  assert_true(swept.active().worktree is None)
}

///|
test "a dirty archive stages the discard dialog and confirm retries forced" {
  let dispatch = test_dispatch()
  // The host's refusal stages the dialog with its own message.
  let (_, staged) = update_dev(
    dispatch,
    ArchiveNeedsForce(
      session="desktop-test",
      message="worktree wt-1 has uncommitted changes; archiving discards them",
    ),
    test_model(),
  )
  guard staged.archive_confirm is Some(confirm) else {
    fail("refusal staged no dialog")
  }
  inspect(confirm.session, content="desktop-test")
  assert_true(confirm.message.contains("wt-1"))
  // Cancel stands down without any request.
  let (_, cancelled) = update(dispatch, CancelArchiveDiscard, staged)
  assert_true(cancelled.archive_confirm is None)
  // Confirm fires the forced retry (the archive generations advance, as on
  // a plain archive click) and closes the dialog.
  let (_, restaged) = update_dev(
    dispatch,
    ArchiveNeedsForce(session="desktop-test", message="dirty"),
    cancelled,
  )
  let before = restaged.dev().archived_request_generation
  let (_, confirmed) = update(dispatch, ConfirmArchiveDiscard, restaged)
  assert_true(confirmed.archive_confirm is None)
  assert_eq(confirmed.dev().archived_request_generation, before + 1)
  // Confirming with nothing staged is inert.
  let (_, inert) = update(dispatch, ConfirmArchiveDiscard, confirmed)
  assert_true(inert.archive_confirm is None)
}

///|
test "a start payload never names a worktree" {
  // Creation is the binding; the host routes a bound session's cwd through
  // its registry, so the start wire shape has no worktree field to leak.
  let payload = start_payload(
    "go",
    "deepseek-v4-pro",
    "1000",
    "desktop-wt",
    "sub-1",
    workspace=Some(Absolute("/proj")),
  )
  // The typed wire shape has no worktree field at all; the workspace hint
  // is the only placement the start carries.
  assert_true(
    payload.to_json() is Object(fields) && fields.get("worktree") is None,
  )
  assert_eq(payload.workspace, Some("/proj"))
}
