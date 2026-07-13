// The composer's `#` symbol completion: search the active conversation's
// workspace symbol index through the host's `workspace_symbols` op (which
// proxies the workspace's moon-lsp) and fold the matches into completion rows.
// Each reply carries the `session` and `query` it answers, so a reply that lost
// a conversation switch or was overtaken by a later keystroke is discarded.

///|
/// Search `query` against the conversation's workspace symbols and fold the
/// matches back as `SymbolsLoaded`.
fn read_workspace_symbols(
  dispatch : @cmd.Emit[Msg],
  session : String,
  query : String,
  workspace~ : @pathx.Absolute?,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload : @protocol.WorkspaceSymbolsPayload = {
        session,
        query,
        workspace: workspace_hint(workspace),
      }
      let raw_reply = @interop.bridge_request("workspace_symbols", payload) catch {
        _ => {
          scheduler.add(dispatch(SymbolsFailed(session~, query~)))
          return
        }
      }
      let reply : @protocol.WorkspaceSymbolsReply? = @interop.bridge_reply(
        raw_reply,
      )
      match reply {
        Some(reply) => {
          let items = symbols_from_reply(reply)
          scheduler.add(dispatch(SymbolsLoaded(session~, query~, items~)))
        }
        None => scheduler.add(dispatch(SymbolsFailed(session~, query~)))
      }
    })
  })
}

///|
/// Map a decoded `workspace_symbols` reply into completion rows. The shared
/// protocol decoder skips malformed rows before this display conversion.
fn symbols_from_reply(
  reply : @protocol.WorkspaceSymbolsReply,
) -> Array[CompletionItem] {
  let rows : Array[CompletionItem] = []
  for item in reply.symbols {
    let range = @common.Range::Range(
      item.range.start.line + 1,
      item.range.start.col + 1,
      item.range.end.line + 1,
      item.range.end.col + 1,
    )
    rows.push(
      symbol_item(item.name, container=item.container, path=item.path, range~),
    )
  }
  rows
}

///|
/// Build a symbol's completion row. The label is the bare name; the detail
/// reads as `container · path:line` (each part dropped when blank). Accepting it
/// drops a reference into the composer for the agent — the name in backticks and
/// the location as the clickable `path:line` convention. `range` is one-based
/// (viewer coordinates); an empty range still anchors the reference's line,
/// it just gives the jump nothing to select.
fn symbol_item(
  name : String,
  container~ : String?,
  path~ : String,
  range~ : @common.Range,
) -> CompletionItem {
  let location = if path.is_empty() {
    ""
  } else {
    "\{path}:\{range.start_line_number}"
  }
  let detail = if container is Some(container) && !container.is_empty() {
    if location.is_empty() {
      container
    } else {
      "\{container} · \{location}"
    }
  } else {
    location
  }
  let reference = if location.is_empty() {
    "`\{name}`"
  } else {
    "`\{name}` — \{location}"
  }
  let (target_path, target_range) = if path.is_empty() {
    (None, None)
  } else {
    (Some(path), Some(range))
  }
  {
    label: name,
    detail,
    command: "",
    insert: reference + " ",
    path: target_path,
    range: target_range,
  }
}
