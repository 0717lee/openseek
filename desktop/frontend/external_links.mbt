// External anchor routing shared by transcript Markdown and the editor's
// foreign hover DOM. The listener runs in the capture phase because the hover
// widget stops click propagation before a document bubble listener can see it.

///|
using @cmd {trait Scheduler}

///|
priv suberror ExternalLinkSubscription {
  ExternalLinkSubscription(desktop~ : Bool, @cmd.Emit[String])
}

///|
fn external_link_sub_loader(
  payload : Error,
  scheduler : &Scheduler,
) -> @sub.RunningSub? {
  match payload {
    ExternalLinkSubscription(desktop~, emit) => {
      let mut emit = emit
      let listener = add_external_link_capture(desktop, url => {
        scheduler.add(emit(url))
      })
      Some({
        unload: _ => remove_external_link_capture(listener),
        update_tagger: payload => {
          guard payload is ExternalLinkSubscription(desktop=_, next) else {
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
/// The shell identity rides the payload because the page cannot tell — the
/// desktop window and the browser console are both plain http origins.
fn external_link_subscription(
  desktop~ : Bool,
  emit : @cmd.Emit[String],
) -> @sub.Sub {
  @sub.custom_sub(
    "external-link-capture",
    Global,
    ExternalLinkSubscription(desktop~, emit),
    external_link_sub_loader,
  )
}

///|
/// Ask the local host to hand an external URL to the system browser.
/// Failures re-enter update as the same host-action toast used by file/app
/// openers; the browser page never emits this command.
fn open_external_link(dispatch : @cmd.Emit[Msg], url : String) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload = @js.Object::new()
      payload["url"] = url
      let _ : @js.Value = @interop.bridge_request(
        @interop.ChannelId::Local,
        "shell.open_external",
        payload.to_value(),
      ) catch {
        error => {
          scheduler.add(
            dispatch(HostActionFailed(@interop.bridge_error_text(error))),
          )
          return
        }
      }
    })
  })
}

///|
/// Install one delegated capture listener and return its identity for removal.
/// Browser pages preserve ordinary navigation but force safe external targets
/// into a new tab. The desktop window prevents every anchor navigation (so
/// the app frame cannot escape into the webview) and emits only allowlisted
/// external schemes for the host to open.
extern "js" fn add_external_link_capture(
  desktop : Bool,
  on_external : (String) -> Unit,
) -> @js.Value =
  #| (desktop, onExternal) => {
  #|   const listener = (event) => {
  #|     if (event.defaultPrevented || event.button !== 0) return;
  #|     const anchor = event.target?.closest?.("a[href]");
  #|     if (!anchor || anchor.hasAttribute("download")) return;
  #|     let destination;
  #|     try {
  #|       destination = new URL(anchor.getAttribute("href"), document.baseURI);
  #|     } catch {
  #|       return;
  #|     }
  #|     const supported = destination.protocol === "http:" ||
  #|       destination.protocol === "https:" ||
  #|       destination.protocol === "mailto:";
  #|     if (desktop) {
  #|       event.preventDefault();
  #|       if (supported) onExternal(destination.href);
  #|       return;
  #|     }
  #|     const leavesOrigin = destination.protocol === "mailto:" ||
  #|       destination.origin !== globalThis.location?.origin;
  #|     if (supported && leavesOrigin) {
  #|       anchor.target = "_blank";
  #|       anchor.rel = "noopener noreferrer";
  #|     }
  #|   };
  #|   document.addEventListener("click", listener, true);
  #|   return listener;
  #| }

///|
extern "js" fn remove_external_link_capture(listener : @js.Value) -> Unit =
  #| (listener) => document.removeEventListener("click", listener, true)
