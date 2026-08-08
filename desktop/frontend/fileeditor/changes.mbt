// The desktop explorer's Git changed-file inventory. Git interpretation and
// repository access stay in the host; this side only decodes its typed reply,
// fences it to the requesting conversation, and presents stable categories.

///|
fn ChangeKind::parse(value : String) -> ChangeKind {
  match value {
    "modified" => ChangeModified
    "added" => ChangeAdded
    "deleted" => ChangeDeleted
    "renamed" => ChangeRenamed
    "copied" => ChangeCopied
    "unmerged" => ChangeUnmerged
    "type-changed" => ChangeTypeChanged
    "untracked" => ChangeUntracked
    "submodule" => ChangeSubmodule
    "symlink" => ChangeSymlink
    _ => ChangeUnknown
  }
}

///|
fn ChangedFile::from_reply(change : @protocol.GitChange) -> ChangedFile? {
  guard !change.path.is_empty() else { return None }
  Some({
    path: @pathx.Relative(change.path),
    original_path: change.original_path.map(path => @pathx.Relative(path)),
    index_status: change.index_status,
    worktree_status: change.worktree_status,
    kind: ChangeKind::parse(change.kind),
  })
}

///|
/// Ask the owning host for the checkout's current staged + unstaged inventory.
/// As with the filesystem calls, a resource hint belonging to another host is
/// rejected before any bridge request is made.
fn list_changes(
  dispatch : @cmd.Emit[Msg],
  owner : @interop.ConversationKey,
  generation : Int,
  workspace~ : @common.Uri?,
) -> @cmd.Cmd {
  match workspace {
    Some(resource) if !@resource.belongs_to(resource, owner.channel) =>
      // `refresh_changes` has already marked this generation in flight. A
      // silent no-op would wedge the inventory in Loading/refreshing forever;
      // settle it through the ordinary fenced failure path instead.
      return dispatch(
        ChangesFailed(
          owner~,
          generation~,
          message="workspace moved to another host before Git refresh",
        ),
      )
    _ => ()
  }
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let reply = @interop.bridge_request(
        owner.channel,
        @commands.git_changes,
        {
          session: owner.session,
          workspace: workspace.map(value => value.path),
        },
      ) catch {
        error => {
          scheduler.add(
            dispatch(
              ChangesFailed(
                owner~,
                generation~,
                message=@interop.bridge_error_text(error),
              ),
            ),
          )
          return
        }
      }
      let files = reply.changes.filter_map(ChangedFile::from_reply)
      scheduler.add(
        dispatch(
          ChangesLoaded(
            owner~,
            generation~,
            repository=reply.repository,
            files~,
          ),
        ),
      )
    })
  })
}

///|
/// Compact label used by each changed-file row. Raw index/worktree columns
/// remain available in the title for precise staged/unstaged detail.
fn ChangedFile::status_label(self : ChangedFile) -> String {
  if self.kind is ChangeSubmodule && self.has_unmerged_status() {
    return "U"
  }
  match self.kind {
    ChangeModified => "M"
    ChangeAdded => "A"
    ChangeDeleted => "D"
    ChangeRenamed => "R"
    ChangeCopied => "C"
    ChangeUnmerged => "U"
    ChangeTypeChanged => "T"
    ChangeUntracked => "?"
    ChangeSubmodule => "S"
    ChangeSymlink => "L"
    ChangeUnknown => "!"
  }
}

///|
fn ChangedFile::has_unmerged_status(self : ChangedFile) -> Bool {
  ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(
    self.index_status + self.worktree_status,
  )
}

///|
fn ChangedFile::status_title(self : ChangedFile) -> String {
  let detail = "index: \{self.index_status}, worktree: \{self.worktree_status}"
  match self.original_path {
    Some(original) => "\{original.0} → \{self.path.0} (\{detail})"
    None => "\{self.path.0} (\{detail})"
  }
}

///|
/// A path absent from the working tree has nothing for the ordinary file
/// reader to open. Besides a plain deletion, that includes a renamed path
/// deleted again (`RD`) and a both-deleted conflict (`DD`). The
/// follow-up diff PR provides a Git-baseline preview; until then these rows
/// remain informative but inert instead of surfacing a failed read over the
/// previously visible document.
fn ChangedFile::selectable(self : ChangedFile) -> Bool {
  if self.kind is ChangeSubmodule ||
    self.kind is ChangeSymlink ||
    self.path.0.has_suffix("/") {
    false
  } else if self.kind is ChangeUnmerged {
    // Conflict codes are exceptional: the retained side remains readable for
    // `DU` and `UD`; only `DD` has no working-tree file.
    !(self.index_status == "D" && self.worktree_status == "D")
  } else {
    // Rename/copy classification takes precedence over worktree deletion in
    // the host, so the raw second column is still required for `RD` / `CD`.
    !(self.kind is ChangeDeleted) && self.worktree_status != "D"
  }
}

///|
/// Explain why an informative row cannot use the ordinary file reader.
fn ChangedFile::unselectable_title(self : ChangedFile) -> String {
  let reason = if self.kind is ChangeSubmodule {
    "Git submodule; open its nested checkout separately"
  } else if self.kind is ChangeSymlink {
    "Git symlink; opening its target is disabled"
  } else if self.path.0.has_suffix("/") {
    "untracked directory; open its nested checkout separately"
  } else {
    "deleted from the working tree"
  }
  self.status_title() + " — " + reason
}

///|
test "changed-file replies decode presentation categories and rename sources" {
  assert_true(ChangeKind::parse("submodule") is ChangeSubmodule)
  assert_true(ChangeKind::parse("symlink") is ChangeSymlink)
  let change : @protocol.GitChange = {
    path: "new.mbt",
    original_path: Some("old.mbt"),
    index_status: "R",
    worktree_status: " ",
    kind: "renamed",
  }
  assert_true(
    ChangedFile::from_reply(change)
    is Some(
      {
        path: @pathx.Relative("new.mbt"),
        original_path: Some(@pathx.Relative("old.mbt")),
        index_status: "R",
        worktree_status: " ",
        kind: ChangeRenamed,
      }
    ),
  )
}

///|
test "empty changed-file paths are ignored defensively" {
  assert_true(
    ChangedFile::from_reply({
      path: "",
      original_path: None,
      index_status: "?",
      worktree_status: "?",
      kind: "untracked",
    })
    is None,
  )
}

///|
test "change rows without a working-tree file are not selectable" {
  let deleted : ChangedFile = {
    path: @pathx.Relative("removed.mbt"),
    original_path: None,
    index_status: " ",
    worktree_status: "D",
    kind: ChangeDeleted,
  }
  assert_false(deleted.selectable())
  assert_false(
    { ..deleted, index_status: "R", worktree_status: "D", kind: ChangeRenamed }.selectable(),
  )
  assert_false(
    { ..deleted, index_status: "D", worktree_status: "D", kind: ChangeUnmerged }.selectable(),
  )
  assert_false(
    { ..deleted, worktree_status: "M", kind: ChangeSubmodule }.selectable(),
  )
  assert_false(
    { ..deleted, worktree_status: "M", kind: ChangeSymlink }.selectable(),
  )
  assert_false(
    {
      ..deleted,
      path: @pathx.Relative("nested/"),
      index_status: "?",
      worktree_status: "?",
      kind: ChangeUntracked,
    }.selectable(),
  )
  assert_true(
    { ..deleted, index_status: "D", worktree_status: "U", kind: ChangeUnmerged }.selectable(),
  )
  assert_true(
    { ..deleted, index_status: "U", worktree_status: "D", kind: ChangeUnmerged }.selectable(),
  )
  assert_true(
    { ..deleted, worktree_status: "M", kind: ChangeModified }.selectable(),
  )
  assert_eq(
    {
      ..deleted,
      index_status: "U",
      worktree_status: "U",
      kind: ChangeSubmodule,
    }.status_label(),
    "U",
  )
}
