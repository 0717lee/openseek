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
  Requested(ContextRequest, Int, Int)
  CloseContext
}

///|
const GlobalContextTarget : String = "app-context-menu"

///|
fn context_target(
  kind : String,
  value : String,
  detail : String,
) -> ContextTarget {
  match kind {
    "web" => WebLink(value)
    "email" => EmailLink(url=value, address=detail)
    "file" => FileLink(value)
    _ => NoTarget
  }
}

///|
fn context_request(
  kind : String,
  value : String,
  detail : String,
  has_selection : Bool,
  selected_text : String,
) -> ContextRequest {
  {
    target: context_target(kind, value, detail),
    selected_text: if has_selection {
      Some(selected_text)
    } else {
      None
    },
  }
}

///|
extern "js" fn install_context_menu_listener(
  close : () -> Unit,
  open : (String, String, String, Bool, String, Int, Int) -> Unit,
) -> @js.Value =
  #| (close, open) => {
  #|   let rememberedSelection = null;
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
  #|   const onContextCapture = () => close();
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
  #|     let kind = "none";
  #|     let value = "";
  #|     let detail = "";
  #|     const file = element.closest?.("[data-context-file]");
  #|     if (file) {
  #|       kind = "file";
  #|       value = file.getAttribute("data-context-file") ?? "";
  #|     } else {
  #|       const anchor = element.closest?.("a[href]");
  #|       if (anchor && !anchor.hasAttribute("download")) {
  #|         const protocol = anchor.protocol.toLowerCase();
  #|         if (protocol === "http:" || protocol === "https:") {
  #|           kind = "web";
  #|           value = anchor.href;
  #|         } else if (protocol === "mailto:") {
  #|           kind = "email";
  #|           value = anchor.href;
  #|           const raw = anchor.getAttribute("href")?.slice(7).split("?")[0] ?? "";
  #|           try { detail = decodeURIComponent(raw); } catch (_) { detail = raw; }
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
  #|       kind,
  #|       value,
  #|       detail,
  #|       selected !== null,
  #|       selected ?? "",
  #|       Math.round(x),
  #|       Math.round(y),
  #|     );
  #|   };
  #|
  #|   document.addEventListener("mousedown", onMouseDown, true);
  #|   document.addEventListener("contextmenu", onContextCapture, true);
  #|   document.addEventListener("contextmenu", onContextMenu);
  #|   return { onMouseDown, onContextCapture, onContextMenu };
  #| }

///|
extern "js" fn remove_context_menu_listener(listeners : @js.Value) -> Unit =
  #| (listeners) => {
  #|   document.removeEventListener("mousedown", listeners.onMouseDown, true);
  #|   document.removeEventListener("contextmenu", listeners.onContextCapture, true);
  #|   document.removeEventListener("contextmenu", listeners.onContextMenu);
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
      (kind, value, detail, has_selection, selected_text, x, y) => {
        scheduler.add(
          emit(
            Requested(
              context_request(kind, value, detail, has_selection, selected_text),
              x,
              y,
            ),
          ),
        )
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
      let label = if input.platform is Web { "Open in New Tab" } else { "Open" }
      navigation.push(
        context_item(
          label,
          label,
          @icons.icon_link_external(),
          (actions.open_link)(url),
        ),
      )
      if !(input.platform is Web) {
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
        Requested(request, x, y) => {
          guard context_definition(input, request, actions) is Some(definition) &&
            definition.enabled_indices() is [_, ..] else {
            return ({ open_context: None, }, @cmd.none)
          }
          let open : ContextOpen = {
            request,
            x,
            y,
            restore_focus_id: focused_element_id(),
          }
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
