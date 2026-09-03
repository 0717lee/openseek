// The application-shell context menu. Stable domain rows keep using
// `context_attrs`; this adjacent adapter owns ephemeral DOM context such as a
// text selection or a rendered link. Both paths share the same menu surface,
// focus behavior, positioning, and theme.

///|
pub(all) enum ClientPlatform {
  Web
  MacOS
  Windows
  Linux
} derive(Eq)

///|
pub(all) struct ContextInput {
  platform : ClientPlatform
  // Whether ordinary web links have a visible in-app Browser destination on
  // the current screen. This is a screen capability, not a platform fact.
  open_web_links_in_app : Bool
  // Reveal is intentionally local-window-only. A browser or a Desktop viewing
  // a remote host must not unexpectedly open a file manager on another device.
  reveal_files : Bool
} derive(Eq)

///|
pub(all) struct ContextActions {
  open_link : (String) -> @cmd.Cmd
  open_external_link : (String) -> @cmd.Cmd
  open_file : (String) -> @cmd.Cmd
  reveal_file : (String) -> @cmd.Cmd
}

///|
priv enum ContextTarget {
  NoTarget
  WebLink(String)
  EmailLink(url~ : String, address~ : String)
  FileLink(String)
} derive(Eq)

///|
priv struct ContextRequest {
  target : ContextTarget
  selected_text : String?
} derive(Eq)

///|
priv struct ContextOpen {
  request : ContextRequest
  x : Int
  y : Int
  restore_focus_id : String?
} derive(Eq)

///|
priv struct ContextState {
  open_context : ContextOpen?
} derive(Eq)

///|
priv enum ContextMsg {
  Requested(ContextRequest, Int, Int, String?)
  CloseContext
}

///|
const GlobalContextTarget : String = "app-context-menu"

///|
fn context_string_field(value : @js.Value, key : String) -> String? {
  let field : @js.Value = value.get_with_string(key)
  if field.is_string() {
    Some(field.cast())
  } else {
    None
  }
}

///|
fn context_target(value : @js.Value) -> Result[ContextTarget, Unit] {
  if value.is_null() {
    return Ok(NoTarget)
  }
  if value.is_undefined() {
    return Err(())
  }
  guard context_string_field(value, "kind") is Some(kind) else {
    return Err(())
  }
  match kind {
    "web" =>
      match context_string_field(value, "url") {
        Some(url) => Ok(WebLink(url))
        None => Err(())
      }
    "email" =>
      match
        (
          context_string_field(value, "url"),
          context_string_field(value, "address"),
        ) {
        (Some(url), Some(address)) => Ok(EmailLink(url~, address~))
        _ => Err(())
      }
    "file" =>
      match context_string_field(value, "path") {
        Some(path) => Ok(FileLink(path))
        None => Err(())
      }
    _ => Err(())
  }
}

///|
fn optional_context_string(value : @js.Value) -> Result[String?, Unit] {
  if value.is_null() {
    Ok(None)
  } else if value.is_string() {
    Ok(Some(value.cast()))
  } else {
    Err(())
  }
}

///|
fn context_request(
  target : @js.Value,
  selected_text : @js.Value,
) -> ContextRequest? {
  match (context_target(target), optional_context_string(selected_text)) {
    (Ok(target), Ok(selected_text)) => Some({ target, selected_text, })
    _ => None
  }
}

///|
extern "js" fn install_context_menu_listener(
  close : () -> Unit,
  open : (@js.Value, @js.Value, @js.Value, Int, Int) -> Unit,
) -> @js.Value =
  #| (close, open) => {
  #|   let rememberedSelection = null;
  #|   let temporaryFocus = null;
  #|   let nextFocusId = 0;
  #|
  #|   const discardTemporaryFocus = () => {
  #|     if (temporaryFocus &&
  #|         temporaryFocus.getAttribute("data-action-menu-temporary-focus") === temporaryFocus.id) {
  #|       temporaryFocus.removeAttribute("data-action-menu-temporary-focus");
  #|       temporaryFocus.removeAttribute("id");
  #|     }
  #|     temporaryFocus = null;
  #|   };
  #|
  #|   const rememberFocus = () => {
  #|     discardTemporaryFocus();
  #|     const active = document.activeElement;
  #|     if (!(active instanceof HTMLElement) || active === document.body) return null;
  #|     if (active.id) return active.id;
  #|     const id = `app-context-focus:${++nextFocusId}`;
  #|     active.id = id;
  #|     active.setAttribute("data-action-menu-temporary-focus", id);
  #|     temporaryFocus = active;
  #|     return id;
  #|   };
  #|
  #|   const eventElement = (event) => {
  #|     const target = event.target;
  #|     if (target instanceof Element) return target;
  #|     return target?.parentElement ?? null;
  #|   };
  #|
  #|   const editable = (element) => {
  #|     const control = element?.closest?.("input, textarea, select, [contenteditable]");
  #|     if (!control) return false;
  #|     return control.getAttribute("contenteditable") !== "false";
  #|   };
  #|
  #|   const selectedAt = (element, x, y, keyboard) => {
  #|     const selection = document.getSelection?.();
  #|     if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null;
  #|     const text = selection.toString();
  #|     if (text.length === 0) return null;
  #|     for (let index = 0; index < selection.rangeCount; index += 1) {
  #|       const range = selection.getRangeAt(index);
  #|       if (keyboard) {
  #|         try {
  #|           if (element && range.intersectsNode(element)) return text;
  #|         } catch (_) {}
  #|       }
  #|       for (const rect of range.getClientRects()) {
  #|         if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
  #|           return text;
  #|         }
  #|       }
  #|     }
  #|     return null;
  #|   };
  #|
  #|   const onMouseDown = (event) => {
  #|     if (event.button !== 2) return;
  #|     const element = eventElement(event);
  #|     rememberedSelection = {
  #|       x: event.clientX,
  #|       y: event.clientY,
  #|       text: selectedAt(element, event.clientX, event.clientY, false),
  #|     };
  #|   };
  #|
  #|   // Closing in capture means an editor-owned menu that stops propagation
  #|   // still dismisses this surface. An unhandled event reopens it in the
  #|   // bubble listener below, after every more-specific owner had a chance.
  #|   const onContextCapture = () => {
  #|     discardTemporaryFocus();
  #|     close();
  #|   };
  #|
  #|   const onContextMenu = (event) => {
  #|     if (event.defaultPrevented) return;
  #|     const element = eventElement(event);
  #|     if (!element || editable(element)) return;
  #|
  #|     event.preventDefault();
  #|     const keyboard = event.clientX === 0 && event.clientY === 0;
  #|     let selected = selectedAt(element, event.clientX, event.clientY, keyboard);
  #|     if (!selected && rememberedSelection &&
  #|         Math.abs(rememberedSelection.x - event.clientX) <= 2 &&
  #|         Math.abs(rememberedSelection.y - event.clientY) <= 2) {
  #|       selected = rememberedSelection.text;
  #|     }
  #|     rememberedSelection = null;
  #|
  #|     let target = null;
  #|     const file = element.closest?.("[data-context-file]");
  #|     if (file) {
  #|       const path = file.getAttribute("data-context-file");
  #|       if (path !== null) target = { kind: "file", path };
  #|     } else {
  #|       const anchor = element.closest?.("a[href]");
  #|       if (anchor && !anchor.hasAttribute("download")) {
  #|         const protocol = anchor.protocol.toLowerCase();
  #|         if (protocol === "http:" || protocol === "https:") {
  #|           target = { kind: "web", url: anchor.href };
  #|         } else if (protocol === "mailto:") {
  #|           const raw = anchor.getAttribute("href")?.slice(7).split("?")[0] ?? "";
  #|           let address = raw;
  #|           try { address = decodeURIComponent(raw); } catch (_) {}
  #|           target = { kind: "email", url: anchor.href, address };
  #|         }
  #|       }
  #|     }
  #|
  #|     let x = event.clientX;
  #|     let y = event.clientY;
  #|     if (keyboard) {
  #|       const selection = document.getSelection?.();
  #|       const rangeRect = selection && selection.rangeCount > 0
  #|         ? selection.getRangeAt(0).getBoundingClientRect()
  #|         : null;
  #|       const rect = rangeRect && (rangeRect.width > 0 || rangeRect.height > 0)
  #|         ? rangeRect
  #|         : element.getBoundingClientRect();
  #|       x = rect.left;
  #|       y = rect.bottom;
  #|     }
  #|     open(
  #|       target,
  #|       selected,
  #|       rememberFocus(),
  #|       Math.round(x),
  #|       Math.round(y),
  #|     );
  #|   };
  #|
  #|   document.addEventListener("mousedown", onMouseDown, true);
  #|   document.addEventListener("contextmenu", onContextCapture, true);
  #|   document.addEventListener("contextmenu", onContextMenu);
  #|   return { onMouseDown, onContextCapture, onContextMenu, discardTemporaryFocus };
  #| }

///|
extern "js" fn remove_context_menu_listener(listeners : @js.Value) -> Unit =
  #| (listeners) => {
  #|   document.removeEventListener("mousedown", listeners.onMouseDown, true);
  #|   document.removeEventListener("contextmenu", listeners.onContextCapture, true);
  #|   document.removeEventListener("contextmenu", listeners.onContextMenu);
  #|   listeners.discardTemporaryFocus();
  #| }

///|
priv suberror ContextMenuSubscription {
  ContextMenuSubscription(@cmd.Emit[ContextMsg])
}

///|
fn context_menu_subscription(emit : @cmd.Emit[ContextMsg]) -> @sub.Sub {
  @sub.custom_sub("app-context-menu", Global, ContextMenuSubscription(emit), (
    payload,
    scheduler,
  ) => {
    guard payload is ContextMenuSubscription(emit) else { return None }
    let mut emit = emit
    let listeners = install_context_menu_listener(
      () => scheduler.add(emit(CloseContext)),
      (target, selected_text, restore_focus, x, y) => {
        match
          (
            context_request(target, selected_text),
            optional_context_string(restore_focus),
          ) {
          (Some(request), Ok(restore_focus_id)) =>
            scheduler.add(emit(Requested(request, x, y, restore_focus_id)))
          _ => ()
        }
      },
    )
    Some({
      unload: _ => remove_context_menu_listener(listeners),
      update_tagger: payload => {
        guard payload is ContextMenuSubscription(next) else { return }
        emit = next
      },
    })
  })
}

///|
fn context_item(
  label : String,
  title : String,
  icon : @html.Html,
  command : @cmd.Cmd,
) -> Entry {
  Action({
    label,
    title,
    icon: Some(icon),
    enabled: true,
    destructive: false,
    command,
  })
}

///|
fn copy_item(label : String, title : String, text : String) -> Entry {
  context_item(label, title, @icons.icon_copy(), @clipboard.copy(Text(text)))
}

///|
fn reveal_label(platform : ClientPlatform) -> String? {
  match platform {
    MacOS => Some("Show in Finder")
    Windows => Some("Show in File Explorer")
    Linux => Some("Show in Folder")
    Web => None
  }
}

///|
fn context_definition(
  input : ContextInput,
  request : ContextRequest,
  actions : ContextActions,
) -> Definition? {
  let navigation : Array[Entry] = []
  let clipboard : Array[Entry] = []
  match request.target {
    NoTarget => ()
    WebLink(url) => {
      if input.platform is Web {
        navigation.push(
          context_item(
            "Open in New Tab",
            "Open in New Tab",
            @icons.icon_link_external(),
            (actions.open_link)(url),
          ),
        )
      } else if input.open_web_links_in_app {
        navigation.push(
          context_item(
            "Open",
            "Open",
            @icons.icon_link_external(),
            (actions.open_link)(url),
          ),
        )
        navigation.push(
          context_item(
            "Open in Default Browser",
            "Open in the system default browser",
            @icons.icon_link_external(),
            (actions.open_external_link)(url),
          ),
        )
      } else {
        navigation.push(
          context_item(
            "Open in Default Browser",
            "Open in the system default browser",
            @icons.icon_link_external(),
            (actions.open_external_link)(url),
          ),
        )
      }
      clipboard.push(copy_item("Copy Link", "Copy link address", url))
    }
    EmailLink(url~, address~) => {
      navigation.push(
        context_item(
          "Open",
          "Open email link",
          @icons.icon_link_external(),
          (actions.open_link)(url),
        ),
      )
      clipboard.push(
        copy_item("Copy Email Address", "Copy email address", address),
      )
    }
    FileLink(path) => {
      navigation.push(
        context_item(
          "Open",
          "Open file",
          @icons.icon_link_external(),
          (actions.open_file)(path),
        ),
      )
      if input.reveal_files && reveal_label(input.platform) is Some(label) {
        navigation.push(
          context_item(
            label,
            label,
            @icons.icon_folder_opened(),
            (actions.reveal_file)(path),
          ),
        )
      }
      clipboard.push(copy_item("Copy Path", "Copy file path", path))
    }
  }
  if request.selected_text is Some(text) {
    clipboard.insert(0, copy_item("Copy", "Copy selected text", text))
  }
  guard !navigation.is_empty() || !clipboard.is_empty() else { return None }
  let entries = navigation
  if !navigation.is_empty() && !clipboard.is_empty() {
    entries.push(Separator)
  }
  for entry in clipboard {
    entries.push(entry)
  }
  Some({ label: "Context menu", entries, })
}

///|
fn ContextOpen::as_menu_open(self : ContextOpen) -> Open {
  {
    target: GlobalContextTarget,
    anchor: Pointer(self.x, self.y),
    restore_focus_id: self.restore_focus_id,
  }
}

///|
/// Own the application shell's fallback context menu. More-specific controls
/// run first through ordinary DOM bubbling; unclaimed events are either
/// converted into this themed menu or suppressed when they have no action.
pub fn context_component(
  input : @rabbita.Val[ContextInput],
  actions : ContextActions,
) -> @rabbita.Val[@html.Html] {
  let (state, emit) = @rabbita.create_state_with_input(
    input~,
    init=(_, _) => ({ open_context: None, }, @cmd.none),
    update=(_state, input, msg, _) => {
      match msg {
        Requested(request, x, y, restore_focus_id) => {
          guard context_definition(input, request, actions) is Some(definition) &&
            definition.enabled_indices() is [_, ..] else {
            return ({ open_context: None, }, @cmd.none)
          }
          let open : ContextOpen = { request, x, y, restore_focus_id, }
          (
            { open_context: Some(open), },
            @cmd.batch([
              position(GlobalContextTarget, Pointer(x, y)),
              focus_element(menu_id(GlobalContextTarget), true),
            ]),
          )
        }
        CloseContext => ({ open_context: None, }, @cmd.none)
      }
    },
    subscriptions=(state, input, emit) => {
      let requests = context_menu_subscription(emit)
      guard state.open_context is Some(open) else { return requests }
      let enabled = context_definition(input, open.request, actions).map(definition => {
        definition.enabled_indices()
      })
      let focus = focus_subscription(
        GlobalContextTarget,
        enabled,
        emit.map((_ : Unit) => CloseContext),
      )
      @sub.batch([
        requests,
        dismiss_subscription(
          GlobalContextTarget,
          emit.map((_ : Unit) => CloseContext),
          dismiss_on_context=false,
        ),
        focus,
      ])
    },
  )
  state.map2(input, (state, input) => {
    guard state.open_context is Some(open) &&
      context_definition(input, open.request, actions) is Some(definition) &&
      !definition.enabled_indices().is_empty() else {
      return @html.nothing
    }
    render_menu(open.as_menu_open(), definition, emit(CloseContext))
  })
}

///|
pub extend ClientPlatform with Eq::{equal, not_equal}

///|
pub extend ContextInput with Eq::{equal, not_equal}
