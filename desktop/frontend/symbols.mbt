// Root-shell routing for the shared workspace-symbol package. OpenSeek keeps
// owner/generation identity in its own Msg; wire projection and transport live
// in `frontend/symbols`.

///|
type WorkspaceSymbol = @symbols.Symbol

///|
/// Which root-shell surface owns a workspace-symbol request. Each surface
/// carries its own generation so an overtaken response cannot settle a newer
/// query.
priv enum SymbolRequest {
  ComposerSymbolRequest(Int)
  QuickOpenSymbolRequest(Int)
}

///|
/// Search `query` and route the reply back to the exact owning surface. The
/// shared symbols package owns transport; this method only projects its reply
/// into the root shell's two message shapes.
fn SymbolRequest::search(
  self : SymbolRequest,
  dispatch : @cmd.Emit[Msg],
  owner : @interop.ConversationKey,
  query : String,
  root~ : @common.Uri?,
) -> @cmd.Cmd {
  guard root is Some(root) && @resource.belongs_to(root, owner.channel) else {
    return @cmd.none
  }
  let loaded = items => {
    dispatch(
      match self {
        ComposerSymbolRequest(generation) =>
          SymbolsLoaded(owner~, root~, query~, generation~, items~)
        QuickOpenSymbolRequest(generation) =>
          QuickOpenSymbolsLoaded(owner~, query~, generation~, items~)
      },
    )
  }
  let failed = dispatch(
    match self {
      ComposerSymbolRequest(generation) =>
        SymbolsFailed(owner~, root~, query~, generation~)
      QuickOpenSymbolRequest(generation) =>
        QuickOpenSymbolsRequestFailed(owner~, query~, generation~)
    },
  )
  @symbols.search(owner.channel, query, root~, loaded~, failed~)
}

///|
/// Map the shared symbol into the composer's row and insertion payload.
fn CompletionItem::from_symbol(symbol : WorkspaceSymbol) -> CompletionItem {
  CompletionItem::symbol(
    symbol.name,
    container=symbol.container,
    path=symbol.path,
    range=symbol.range,
  )
}

///|
/// Build a symbol's completion row. The label is the bare name; the detail
/// reads as `container · path:line` (each part dropped when blank). Accepting it
/// drops a reference into the composer for the agent — the name in backticks and
/// the location as the clickable `path:line` convention. `range` is one-based
/// (viewer coordinates); an empty range still anchors the reference's line,
/// it just gives the jump nothing to select.
fn CompletionItem::symbol(
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
