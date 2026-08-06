// Native desktop workspace-symbol quick pick. This is Workbench chrome: it
// owns the global shortcut, transient query state, result navigation, and the
// handoff to the existing cross-file open/reveal path. The single-document
// Viewer and the browser console remain unaware of it.

///|
const SymbolSearchDebounceMs : Int = 150

///|
const SymbolSearchInputId : String = "symbol-search-input"

///|
const SymbolSearchListId : String = "symbol-search-list"

///|
priv suberror SymbolSearchShortcutSubscription {
  SymbolSearchShortcutSubscription(@cmd.Emit[Msg])
}

///|
fn symbol_search_shortcut_sub_loader(
  payload : Error,
  scheduler : &Scheduler,
) -> @sub.RunningSub? {
  match payload {
    SymbolSearchShortcutSubscription(emit) => {
      let mut emit = emit
      let target = @dom.document().as_event_target()
      let is_apple = symbol_search_platform_is_apple()
      let listener : @dom.Listener = event => {
        guard event.to_keyboard_event() is Some(keyboard) &&
          symbol_search_shortcut_matches(keyboard, is_apple) else {
          return
        }
        event.prevent_default()
        event.stop_propagation()
        scheduler.add(emit(SymbolSearchOpen))
      }
      target.add_event_listener_with_options("keydown", listener, capture=true)
      Some({
        unload: _ => {
          target.remove_event_listener_with_options(
            "keydown",
            listener,
            capture=true,
          )
        },
        update_tagger: payload => {
          guard payload is SymbolSearchShortcutSubscription(next) else {
            return
          }
          emit = next
        },
      })
    }
    _ => None
  }
}

///|
/// Subscribe to Cmd+T on Apple platforms and Ctrl+T elsewhere. `boot` adds
/// this subscription only for the injected desktop bridge, so a browser tab
/// keeps its native new-tab shortcut.
fn symbol_search_shortcut_subscription(emit : @cmd.Emit[Msg]) -> @sub.Sub {
  @sub.custom_sub(
    "symbol-search-shortcut-capture",
    Global,
    SymbolSearchShortcutSubscription(emit),
    symbol_search_shortcut_sub_loader,
  )
}

///|
/// Browser platform label used to keep Ctrl+T available to terminal programs
/// on Apple systems while using the conventional Ctrl shortcut elsewhere.
fn symbol_search_browser_platform() -> String {
  let navigator = @js.Value::cast_from(@dom.window().navigator())
  if @interop.js_prop(navigator, "userAgentData") is Some(user_agent_data) &&
    @interop.js_prop(user_agent_data, "platform") is Some(value) &&
    (@js.Cast::into(value) : String?) is Some(platform) &&
    !platform.is_empty() {
    return platform
  }
  if @interop.js_prop(navigator, "platform") is Some(value) &&
    (@js.Cast::into(value) : String?) is Some(platform) {
    platform
  } else {
    ""
  }
}

///|
fn symbol_search_platform_is_apple() -> Bool {
  let platform = symbol_search_browser_platform().to_lower()
  platform.contains("mac") ||
  platform.contains("iphone") ||
  platform.contains("ipad") ||
  platform.contains("ipod")
}

///|
/// Match only the platform's exact, non-repeating command chord. The capture
/// listener calls this before Monaco/xterm or the focused input can consume it.
fn symbol_search_shortcut_matches(
  keyboard : @dom.KeyboardEvent,
  is_apple : Bool,
) -> Bool {
  let command = if is_apple {
    keyboard.meta_key() && !keyboard.ctrl_key()
  } else {
    keyboard.ctrl_key() && !keyboard.meta_key()
  }
  keyboard.code() == "KeyT" &&
  command &&
  !keyboard.shift_key() &&
  !keyboard.alt_key() &&
  !keyboard.is_composing() &&
  !keyboard.repeat()
}

///|
fn active_symbol_search_owner(model : Model) -> @interop.ConversationKey {
  { channel: model.focused, session: model.active().session_id }
}

///|
fn symbol_search_request(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  owner : @interop.ConversationKey,
  query : String,
  generation : Int,
) -> @cmd.Cmd {
  read_workspace_symbols(
    dispatch,
    owner,
    query,
    workspace=workspace_root(
      model.session_workspace(owner.channel, owner.session),
    ),
    generation~,
  )
}

///|
/// Open a fresh palette for the focused conversation. Another invocation is a
/// reset: it clears the query/results, starts the empty-query request, closes
/// overlapping transient menus, and restores input focus after render.
fn open_symbol_search(
  dispatch : @cmd.Emit[Msg],
  model : Model,
) -> (@cmd.Cmd, Model) {
  guard model.is_desktop &&
    model.workspace_picker is None &&
    model.archive_confirm is None &&
    !(model.update_ux is ConfirmingRestart(..)) &&
    !(model.bridge_state() is BridgeLost(_)) else {
    return (@cmd.none, model)
  }
  let owner = active_symbol_search_owner(model)
  let generation = model.symbol_search_generation + 1
  let search : SymbolSearch = {
    owner,
    query: "",
    items: [],
    selected: 0,
    phase: SymbolSearchLoading,
    generation,
  }
  let next = {
    ..model,
    completion: None,
    launcher: { ..model.launcher, open: false },
    symbol_search: Some(search),
    symbol_search_generation: generation,
  }
  (
    @cmd.batch([
      symbol_search_request(dispatch, next, owner, "", generation),
      focus_symbol_search_after_render(),
    ]),
    next,
  )
}

///|
/// Replace the query and arm a delayed request. Rows disappear immediately so
/// Enter can never accept a result belonging to the previous text.
fn change_symbol_search_query(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  query : String,
) -> (@cmd.Cmd, Model) {
  guard model.symbol_search is Some(search) else { return (@cmd.none, model) }
  if query == search.query {
    return (@cmd.none, model)
  }
  let generation = model.symbol_search_generation + 1
  let next_search = {
    ..search,
    query,
    items: [],
    selected: 0,
    phase: SymbolSearchDebouncing,
    generation,
  }
  (
    @cmd.delay(
      dispatch(SymbolSearchDue(owner=search.owner, query~, generation~)),
      SymbolSearchDebounceMs,
    ),
    {
      ..model,
      symbol_search: Some(next_search),
      symbol_search_generation: generation,
    },
  )
}

///|
/// Start the delayed host request only when no later keystroke, close, reopen,
/// or conversation switch has overtaken it.
fn begin_symbol_search_request(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  owner : @interop.ConversationKey,
  query : String,
  generation : Int,
) -> (@cmd.Cmd, Model) {
  guard model.symbol_search is Some(search) &&
    search.owner == owner &&
    search.query == query &&
    search.generation == generation &&
    search.phase is SymbolSearchDebouncing else {
    return (@cmd.none, model)
  }
  let next = {
    ..model,
    symbol_search: Some({ ..search, phase: SymbolSearchLoading }),
  }
  (symbol_search_request(dispatch, next, owner, query, generation), next)
}

///|
/// Adopt only the exact outstanding result. Symbols without a source path
/// remain available to composer mentions but are omitted from this quick-open
/// surface because there is nowhere useful to navigate.
fn apply_symbol_search_result(
  model : Model,
  owner : @interop.ConversationKey,
  query : String,
  generation : Int,
  items : Array[WorkspaceSymbol],
) -> (@cmd.Cmd, Model) {
  guard model.symbol_search is Some(search) &&
    search.owner == owner &&
    search.query == query &&
    search.generation == generation &&
    search.phase is SymbolSearchLoading else {
    return (@cmd.none, model)
  }
  let openable : Array[WorkspaceSymbol] = []
  for item in items {
    if !item.path.is_empty() {
      openable.push(item)
    }
  }
  (
    @cmd.none,
    {
      ..model,
      symbol_search: Some({
        ..search,
        items: rank_symbol_search_items(query, openable),
        selected: 0,
        phase: SymbolSearchReady,
      }),
    },
  )
}

///|
fn fail_symbol_search_request(
  model : Model,
  owner : @interop.ConversationKey,
  query : String,
  generation : Int,
) -> (@cmd.Cmd, Model) {
  guard model.symbol_search is Some(search) &&
    search.owner == owner &&
    search.query == query &&
    search.generation == generation &&
    search.phase is SymbolSearchLoading else {
    return (@cmd.none, model)
  }
  (
    @cmd.none,
    {
      ..model,
      symbol_search: Some({
        ..search,
        items: [],
        selected: 0,
        phase: SymbolSearchFailed,
      }),
    },
  )
}

///|
fn move_symbol_search_selection(
  model : Model,
  delta : Int,
) -> (@cmd.Cmd, Model) {
  guard model.symbol_search is Some(search) else { return (@cmd.none, model) }
  let count = search.items.length()
  guard count > 0 else { return (@cmd.none, model) }
  let selected = (search.selected + delta + count) % count
  (
    scroll_symbol_search_selection_after_render(selected),
    { ..model, symbol_search: Some({ ..search, selected, }) },
  )
}

///|
fn select_symbol_search_row(model : Model, index : Int) -> (@cmd.Cmd, Model) {
  guard model.symbol_search is Some(search) &&
    search.items.get(index) is Some(_) else {
    return (@cmd.none, model)
  }
  (@cmd.none, { ..model, symbol_search: Some({ ..search, selected: index }) })
}

///|
fn SymbolSearch::current(self : SymbolSearch) -> WorkspaceSymbol? {
  self.items.get(self.selected)
}

///|
fn open_symbol_search_item(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  item : WorkspaceSymbol,
) -> (@cmd.Cmd, Model) {
  let prepared = { ..model, symbol_search: None, screen: Chat }
  open_editor_at(dispatch, prepared, item.path, Some(item.range))
}

///|
fn accept_symbol_search(
  dispatch : @cmd.Emit[Msg],
  model : Model,
) -> (@cmd.Cmd, Model) {
  guard model.symbol_search is Some(search) && search.current() is Some(item) else {
    return (@cmd.none, model)
  }
  open_symbol_search_item(dispatch, model, item)
}

///|
fn pick_symbol_search_row(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  index : Int,
) -> (@cmd.Cmd, Model) {
  guard model.symbol_search is Some(search) &&
    search.items.get(index) is Some(item) else {
    return (@cmd.none, model)
  }
  open_symbol_search_item(dispatch, model, item)
}

///|
/// Conversation ownership is checked after every message, including pushes
/// that switch the focused device/session without coming from the palette.
fn close_stale_symbol_search(model : Model) -> Model {
  guard model.symbol_search is Some(search) else { return model }
  let owner = active_symbol_search_owner(model)
  if owner == search.owner {
    model
  } else {
    { ..model, symbol_search: None }
  }
}

///|
fn focus_symbol_search_after_render() -> @cmd.Cmd {
  @cmd.custom_cmd(
    _ => {
      if @dom.document().get_element_by_id(SymbolSearchInputId).to_option()
        is Some(input) {
        let _ : @js.Value = @js.Value::cast_from(input).apply_with_string(
          "focus",
          ([] : Array[@js.Value]),
        )
      }
    },
    kind=@cmd.after_render,
  )
}

///|
fn symbol_search_row_id(index : Int) -> String {
  "symbol-search-row-\{index}"
}

///|
fn scroll_symbol_search_selection_after_render(index : Int) -> @cmd.Cmd {
  @cmd.custom_cmd(
    _ => {
      if @dom.document()
        .get_element_by_id(symbol_search_row_id(index))
        .to_option()
        is Some(row) {
        row.scroll_into_view_with_options(block="nearest", inline="nearest")
      }
    },
    kind=@cmd.after_render,
  )
}

///|
/// Codicon class for the LSP SymbolKind numeric wire value. Related kinds are
/// intentionally grouped so the small quick-pick row has a stable visual
/// vocabulary rather than 26 barely distinguishable glyphs.
fn symbol_kind_icon_class(kind : Int?) -> String {
  match kind {
    Some(1) => "codicon-symbol-file"
    Some(2) | Some(3) | Some(4) | Some(19) => "codicon-symbol-namespace"
    Some(5) => "codicon-symbol-class"
    Some(6) | Some(9) | Some(12) | Some(24) => "codicon-symbol-method"
    Some(7) => "codicon-symbol-property"
    Some(8) => "codicon-symbol-field"
    Some(10) => "codicon-symbol-enum"
    Some(11) => "codicon-symbol-interface"
    Some(13)
    | Some(15)
    | Some(16)
    | Some(17)
    | Some(18)
    | Some(20)
    | Some(21) => "codicon-symbol-variable"
    Some(14) => "codicon-symbol-constant"
    Some(22) => "codicon-symbol-enum-member"
    Some(23) => "codicon-symbol-struct"
    Some(25) => "codicon-symbol-operator"
    Some(26) => "codicon-symbol-type-parameter"
    _ => "codicon-symbol-misc"
  }
}

///|
fn symbol_search_key_attrs(dispatch : @cmd.Emit[Msg]) -> @html.Attrs {
  @html.Attrs::build().on_keydown(event => {
    if event.is_composing() {
      return @cmd.none
    }
    match event.key() {
      "ArrowDown" => {
        event.prevent_default()
        dispatch(SymbolSearchMove(1))
      }
      "ArrowUp" => {
        event.prevent_default()
        dispatch(SymbolSearchMove(-1))
      }
      "Enter" => {
        event.prevent_default()
        dispatch(SymbolSearchAccept)
      }
      "Escape" => {
        event.prevent_default()
        dispatch(SymbolSearchDismiss)
      }
      _ => @cmd.none
    }
  })
}

///|
fn symbol_search_empty_view(search : SymbolSearch) -> @html.Html {
  let (class, message) = match search.phase {
    SymbolSearchDebouncing | SymbolSearchLoading =>
      ("symbol-search-empty", "Searching symbols…")
    SymbolSearchFailed => ("symbol-search-empty error", "Symbol search failed")
    SymbolSearchReady => ("symbol-search-empty", "No symbols found")
  }
  @html.div(
    class~,
    attrs=@html.Attrs::build().role("status").aria_live("polite"),
    message,
  )
}

///|
fn symbol_search_view(
  dispatch : @cmd.Emit[Msg],
  search : SymbolSearch,
) -> @html.Html {
  let active_id = if search.current() is Some(_) {
    symbol_search_row_id(search.selected)
  } else {
    ""
  }
  let base_input_attrs = symbol_search_key_attrs(dispatch)
    .id(SymbolSearchInputId)
    .role("combobox")
    .aria_label("Search workspace symbols")
    .aria_controls(SymbolSearchListId)
    .aria_expanded("true")
    .aria_autocomplete("list")
    .aria_keyshortcuts("Meta+T Control+T")
  let input_attrs = if active_id.is_empty() {
    base_input_attrs
  } else {
    base_input_attrs.aria_activedescendant(active_id)
  }
  let rows : Array[@html.Html] = []
  for index, item in search.items {
    let selected = index == search.selected
    rows.push(
      @html.div(
        class=if selected {
          "symbol-search-row selected"
        } else {
          "symbol-search-row"
        },
        attrs=@html.Attrs::build()
          .id(symbol_search_row_id(index))
          .role("option")
          .aria_selected(if selected { "true" } else { "false" })
          .on_mouseenter(_ => dispatch(SymbolSearchSelect(index)))
          .on_mousedown(event => {
            event.prevent_default()
            dispatch(SymbolSearchPick(index))
          }),
        [
          @html.span(
            class="symbol-search-kind codicon \{symbol_kind_icon_class(item.kind)}",
            attrs=@html.Attrs::build().aria_hidden("true"),
            ([] : Array[@html.Html]),
          ),
          @html.div(class="symbol-search-row-text", [
            @html.div(class="symbol-search-name", item.name),
            @html.div(class="symbol-search-detail", item.detail()),
          ]),
        ],
      ),
    )
  }
  let list_children = if rows.is_empty() {
    [symbol_search_empty_view(search)]
  } else {
    rows
  }
  let list_busy = match search.phase {
    SymbolSearchDebouncing | SymbolSearchLoading => "true"
    _ => "false"
  }
  @html.div(
    class="symbol-search-backdrop",
    on_click=dispatch(SymbolSearchDismiss),
    [
      @html.div(
        class="symbol-search-dialog",
        attrs=@html.Attrs::build()
          .role("dialog")
          .aria_modal("true")
          .aria_label("Search workspace symbols")
          .on_click(event => {
            event.stop_propagation()
            @cmd.none
          }),
        [
          @html.div(class="symbol-search-input-wrap", [
            icon(icon_search),
            @html.input(
              input_type=@html.InputType::Text,
              value=search.query,
              placeholder="Search symbols",
              on_input=dispatch.map(query => SymbolSearchQueryChanged(query)),
              attrs=input_attrs,
            ),
          ]),
          @html.div(
            class="symbol-search-group-label",
            attrs=@html.Attrs::build().id("symbol-search-group-label"),
            "Symbols",
          ),
          @html.div(
            class="symbol-search-list",
            attrs=@html.Attrs::build()
              .id(SymbolSearchListId)
              .role("listbox")
              .aria_labelledby("symbol-search-group-label")
              .aria_busy(list_busy),
            list_children,
          ),
        ],
      ),
    ],
  )
}

// State-transition coverage for the quick pick. Commands are intentionally
// opaque here; tests assert that only the matching owner/query/generation can
// change the plain-data model and that accepting a row reaches the existing
// file-panel state.

///|
fn test_workspace_symbol(name : String, path : String) -> WorkspaceSymbol {
  {
    name,
    kind: Some(12),
    container: Some("Parser"),
    path,
    range: @common.Range::Range(5, 2, 5, 13),
  }
}

///|
test "native symbol search opens immediately, debounces edits, and resets" {
  let dispatch = test_dispatch()
  let desktop = { ..test_model(), is_desktop: true }
  let (_, opened) = update(dispatch, SymbolSearchOpen, desktop)
  guard opened.symbol_search is Some(first) else {
    fail("the native shortcut should open the palette")
  }
  assert_eq(first.query, "")
  assert_true(first.phase is SymbolSearchLoading)
  assert_eq(first.items.length(), 0)
  let (_, changed) = update(dispatch, SymbolSearchQueryChanged("parse"), opened)
  guard changed.symbol_search is Some(pending) else {
    fail("typing should keep the palette open")
  }
  assert_eq(pending.query, "parse")
  assert_true(pending.phase is SymbolSearchDebouncing)
  assert_true(pending.generation > first.generation)
  let (_, reset) = update(dispatch, SymbolSearchOpen, changed)
  guard reset.symbol_search is Some(fresh) else {
    fail("repeating the shortcut should reset the palette")
  }
  assert_eq(fresh.query, "")
  assert_true(fresh.phase is SymbolSearchLoading)
  assert_true(fresh.generation > pending.generation)
  let (_, browser) = update(dispatch, SymbolSearchOpen, {
    ..desktop,
    is_desktop: false,
  })
  assert_true(browser.symbol_search is None)
}

///|
test "symbol search drops stale replies and distinguishes failure from empty" {
  let dispatch = test_dispatch()
  let (_, opened) = update(dispatch, SymbolSearchOpen, {
    ..test_model(),
    is_desktop: true,
  })
  guard opened.symbol_search is Some(initial) else { fail("palette expected") }
  let (_, changed) = update(dispatch, SymbolSearchQueryChanged("parse"), opened)
  guard changed.symbol_search is Some(pending) else { fail("palette expected") }
  let item = test_workspace_symbol("parse_hover", "src/main.mbt")
  let (_, stale) = update(
    dispatch,
    SymbolSearchLoaded(
      owner=initial.owner,
      query="",
      generation=initial.generation,
      items=[item],
    ),
    changed,
  )
  guard stale.symbol_search is Some(still_pending) else {
    fail("a stale reply must not close the palette")
  }
  assert_true(still_pending.phase is SymbolSearchDebouncing)
  assert_eq(still_pending.items.length(), 0)
  let (_, loading) = update(
    dispatch,
    SymbolSearchDue(
      owner=pending.owner,
      query=pending.query,
      generation=pending.generation,
    ),
    stale,
  )
  guard loading.symbol_search is Some(in_flight) else {
    fail("palette expected")
  }
  assert_true(in_flight.phase is SymbolSearchLoading)
  let (_, loaded) = update(
    dispatch,
    SymbolSearchLoaded(
      owner=pending.owner,
      query=pending.query,
      generation=pending.generation,
      items=[item],
    ),
    loading,
  )
  guard loaded.symbol_search is Some(ready) else { fail("palette expected") }
  assert_true(ready.phase is SymbolSearchReady)
  assert_eq(ready.items.length(), 1)
  let (_, next_query) = update(
    dispatch,
    SymbolSearchQueryChanged("missing"),
    loaded,
  )
  guard next_query.symbol_search is Some(next_pending) else {
    fail("palette expected")
  }
  let (_, next_loading) = update(
    dispatch,
    SymbolSearchDue(
      owner=next_pending.owner,
      query=next_pending.query,
      generation=next_pending.generation,
    ),
    next_query,
  )
  let (_, failed) = update(
    dispatch,
    SymbolSearchRequestFailed(
      owner=next_pending.owner,
      query=next_pending.query,
      generation=next_pending.generation,
    ),
    next_loading,
  )
  guard failed.symbol_search is Some(failure) else { fail("palette expected") }
  assert_true(failure.phase is SymbolSearchFailed)
  assert_eq(failure.items.length(), 0)
  let (_, empty) = update(
    dispatch,
    SymbolSearchLoaded(
      owner=next_pending.owner,
      query=next_pending.query,
      generation=next_pending.generation,
      items=[],
    ),
    next_loading,
  )
  guard empty.symbol_search is Some(no_results) else {
    fail("palette expected")
  }
  assert_true(no_results.phase is SymbolSearchReady)
  assert_eq(no_results.items.length(), 0)
}

///|
test "symbol search selection wraps and empty acceptance is a no-op" {
  let dispatch = test_dispatch()
  let (_, opened) = update(dispatch, SymbolSearchOpen, {
    ..test_model(),
    is_desktop: true,
  })
  guard opened.symbol_search is Some(search) else { fail("palette expected") }
  let (_, ready) = update(
    dispatch,
    SymbolSearchLoaded(
      owner=search.owner,
      query=search.query,
      generation=search.generation,
      items=[
        test_workspace_symbol("alpha", "a.mbt"),
        test_workspace_symbol("beta", "b.mbt"),
        test_workspace_symbol("gamma", "c.mbt"),
      ],
    ),
    opened,
  )
  let (_, up) = update(dispatch, SymbolSearchMove(-1), ready)
  guard up.symbol_search is Some(last) else { fail("palette expected") }
  assert_eq(last.selected, 2)
  let (_, wrapped) = update(dispatch, SymbolSearchMove(1), up)
  guard wrapped.symbol_search is Some(first) else { fail("palette expected") }
  assert_eq(first.selected, 0)
  let (_, hovered) = update(dispatch, SymbolSearchSelect(1), wrapped)
  guard hovered.symbol_search is Some(second) else { fail("palette expected") }
  assert_eq(second.selected, 1)
  let (_, empty) = update(dispatch, SymbolSearchQueryChanged("none"), hovered)
  let (_, unchanged) = update(dispatch, SymbolSearchAccept, empty)
  assert_true(unchanged.symbol_search == empty.symbol_search)
}

///|
test "accepting a symbol opens the editor at its file and returns to chat" {
  let dispatch = test_dispatch()
  let base = { ..test_model(), is_desktop: true, screen: Settings }
  let (_, opened) = update(dispatch, SymbolSearchOpen, base)
  guard opened.symbol_search is Some(search) else { fail("palette expected") }
  let (_, ready) = update(
    dispatch,
    SymbolSearchLoaded(
      owner=search.owner,
      query=search.query,
      generation=search.generation,
      items=[test_workspace_symbol("parse_hover", "src/main.mbt")],
    ),
    opened,
  )
  let (_, accepted) = update(dispatch, SymbolSearchAccept, ready)
  assert_true(accepted.symbol_search is None)
  assert_true(accepted.screen is Chat)
  assert_true(accepted.file_panel.open)
  assert_true(accepted.file_panel.active is Some(Relative("src/main.mbt")))
  // Reopening over an already-open panel reuses the same open/reveal path.
  let (_, reopened) = update(dispatch, SymbolSearchOpen, accepted)
  guard reopened.symbol_search is Some(next_search) else {
    fail("palette expected")
  }
  let (_, next_ready) = update(
    dispatch,
    SymbolSearchLoaded(
      owner=next_search.owner,
      query=next_search.query,
      generation=next_search.generation,
      items=[test_workspace_symbol("render", "src/render.mbt")],
    ),
    reopened,
  )
  let (_, picked) = update(dispatch, SymbolSearchPick(0), next_ready)
  assert_true(picked.file_panel.open)
  assert_true(picked.file_panel.active is Some(Relative("src/render.mbt")))
}

///|
test "switching conversations closes the workspace-symbol palette" {
  let dispatch = test_dispatch()
  let second = {
    ..empty_conversation(@interop.ChannelId::Local, "desktop-second"),
    messages: [{ kind: User, content: "earlier" }],
  }
  let desktop = {
    ..test_model().replace_conversation(second),
    is_desktop: true,
  }
  let (_, opened) = update(dispatch, SymbolSearchOpen, desktop)
  assert_true(opened.symbol_search is Some(_))
  let (_, switched) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-second"),
    opened,
  )
  assert_eq(switched.active_session, "desktop-second")
  assert_true(switched.symbol_search is None)
}
