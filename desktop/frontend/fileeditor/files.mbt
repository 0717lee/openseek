// The editor side-panel's filesystem calls: list a directory and read a file
// under the active conversation's workspace, through the host's
// `read_directory` / `read_file` ops. The host resolves every path against
// the session's workspace and rejects escapes, so the panel only ever sees
// that one conversation's tree. Each reply carries the `session` and `path`
// it answers so a reply that lost a conversation switch can be discarded.

///|
/// The optional workspace hint as it appears on the bridge. An empty hint is
/// omitted, matching the old object-building path's wire behavior.
fn workspace_hint(workspace : @pathx.Absolute?) -> String? {
  guard workspace is Some(workspace) else { return None }
  let path = workspace.0.trim().to_owned()
  if path.is_empty() {
    None
  } else {
    Some(path)
  }
}

///|
/// List `path` (relative to the conversation workspace; "" is the root) and
/// fold the entries back as `DirLoaded`.
fn read_directory(
  dispatch : @cmd.Emit[Msg],
  session : String,
  path : @pathx.Relative,
  workspace~ : @pathx.Absolute?,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload : @protocol.ReadDirPayload = {
        session,
        path: path.0,
        workspace: workspace_hint(workspace),
      }
      let raw_reply = @interop.bridge_request("read_directory", payload) catch {
        error => {
          scheduler.add(
            dispatch(
              DirFailed(
                session~,
                path~,
                message=@interop.bridge_error_text(error),
              ),
            ),
          )
          return
        }
      }
      let reply : @protocol.ReadDirReply? = @interop.bridge_reply(raw_reply)
      if reply is Some(reply) {
        let entries = decode_dir_entries(reply, path)
        scheduler.add(dispatch(DirLoaded(session~, path~, entries~)))
      } else {
        scheduler.add(
          dispatch(
            DirFailed(session~, path~, message="could not read directory"),
          ),
        )
      }
    })
  })
}

///|
/// Ask the host for the workspace's full file list (the fuzzy filter's
/// index) and fold it back as `FilesIndexed`. Failures fold as
/// `FileIndexFailed`, dropping the index so a later keystroke retries.
fn list_files(
  dispatch : @cmd.Emit[Msg],
  session : String,
  workspace~ : @pathx.Absolute?,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload : @protocol.ListFilesPayload = {
        session,
        workspace: workspace_hint(workspace),
      }
      let raw_reply = @interop.bridge_request("list_files", payload) catch {
        _ => {
          scheduler.add(dispatch(FileIndexFailed(session~)))
          return
        }
      }
      let reply : @protocol.ListFilesReply? = @interop.bridge_reply(raw_reply)
      if reply is Some(reply) {
        let (files, truncated) = decode_file_index(reply)
        scheduler.add(dispatch(FilesIndexed(session~, files~, truncated~)))
      } else {
        scheduler.add(dispatch(FileIndexFailed(session~)))
      }
    })
  })
}

///|
/// Parse a `list_files` reply into relative paths plus the truncation flag.
fn decode_file_index(
  reply : @protocol.ListFilesReply,
) -> (Array[@pathx.Relative], Bool) {
  (reply.files.map(path => Relative(path)), reply.truncated)
}

///|
/// Read `path` and fold its contents back as `FileLoaded`. `name` is the
/// entry's display name, forwarded for the viewer's title and language guess.
/// `range`, when present (a symbol jump's target), is forwarded for the
/// viewer to reveal and select once loaded; `annotation` (an annotation
/// chip's comment) rides along the same way, re-shown as an editor bubble
/// over that range.
pub fn read_file(
  dispatch : @cmd.Emit[Msg],
  session : String,
  path : @pathx.Relative,
  name : String,
  range~ : @common.Range?,
  annotation? : String,
  workspace~ : @pathx.Absolute?,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload : @protocol.ReadFilePayload = {
        session,
        path: path.0,
        workspace: workspace_hint(workspace),
      }
      let raw_reply = @interop.bridge_request("read_file", payload) catch {
        error => {
          scheduler.add(
            dispatch(
              FileFailed(session~, message=@interop.bridge_error_text(error)),
            ),
          )
          return
        }
      }
      let reply : @protocol.ReadFileReply? = @interop.bridge_reply(raw_reply)
      if reply is Some(reply) {
        let file = decode_file_content(reply)
        scheduler.add(
          dispatch(
            FileLoaded(session~, path~, name~, file~, range~, annotation~),
          ),
        )
      } else {
        scheduler.add(
          dispatch(FileFailed(session~, message="could not read file")),
        )
      }
    })
  })
}

///|
/// A workspace-relative path's final `/`-segment, for a mention chip's jump
/// target — it carries only the path, not a display name.
pub fn basename(path : @pathx.Relative) -> String {
  match path.0.split("/").collect() {
    [] => path.0
    segments => segments[segments.length() - 1].to_owned()
  }
}

///|
/// An entry's workspace-relative path: the parent directory's path joined with
/// the entry name ("" parent = workspace root, so the child path is `name`).
fn child_path(parent : @pathx.Relative, name : String) -> @pathx.Relative {
  if parent.is_root() {
    Relative(name)
  } else {
    Relative(parent.0 + "/" + name)
  }
}

///|
/// Parse a `read_directory` reply into entries carrying full relative paths.
/// The shared protocol decoder has already rejected a malformed envelope and
/// skipped malformed rows.
fn decode_dir_entries(
  reply : @protocol.ReadDirReply,
  parent : @pathx.Relative,
) -> Array[FileEntry] {
  let entries : Array[FileEntry] = []
  for entry in reply.entries {
    entries.push({
      name: entry.name,
      path: child_path(parent, entry.name),
      is_dir: entry.is_dir,
    })
  }
  entries
}

///|
fn decode_file_content(reply : @protocol.ReadFileReply) -> FileContent {
  match reply {
    @protocol.Binary => Binary
    @protocol.Oversized => Oversized
    @protocol.Content(content~, absolute~, sig~) =>
      Content(content~, absolute=Absolute(absolute), sig~)
  }
}

///|
/// Stat the open tabs' files and fold the signatures back as `StatsLoaded`.
/// Best-effort: a failed call is dropped — the next change push retries.
fn stat_files(
  dispatch : @cmd.Emit[Msg],
  session : String,
  paths : Array[@pathx.Relative],
  workspace~ : @pathx.Absolute?,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload : @protocol.StatFilesPayload = {
        session,
        paths: paths.map(path => path.0),
        workspace: workspace_hint(workspace),
      }
      let raw_reply = @interop.bridge_request("stat_files", payload) catch {
        _ => return
      }
      let reply : @protocol.StatFilesReply? = @interop.bridge_reply(raw_reply)
      guard reply is Some(reply) else { return }
      let stats = decode_file_stats(reply)
      scheduler.add(dispatch(StatsLoaded(session~, stats~)))
    })
  })
}

///|
fn decode_file_stats(reply : @protocol.StatFilesReply) -> Array[FileStat] {
  let stats : Array[FileStat] = []
  for stat in reply.stats {
    stats.push({ path: Relative(stat.path), sig: stat.sig })
  }
  stats
}

///|
/// Point the host's workspace watcher at `session`'s workspace (`""` parks
/// it). Fire-and-forget: there is no reply worth folding, and a failure just
/// means no live updates until the next reconciliation re-sends.
fn watch_workspace(session : String, workspace~ : @pathx.Absolute?) -> @cmd.Cmd {
  @cmd.custom_cmd(_scheduler => {
    @js.async_run(() => {
      let payload : @protocol.WatchWorkspacePayload = {
        session,
        workspace: workspace_hint(workspace),
      }
      let _ : @js.Value = @interop.bridge_request("watch_workspace", payload) catch {
        _ => return
      }
    })
  })
}
