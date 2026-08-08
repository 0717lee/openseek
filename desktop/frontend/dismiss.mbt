// Click-away dismissal for the app's transient menus and popovers.
//
// The obvious way to write this is a full-screen transparent element behind
// the menu whose click closes it, and it is the wrong behavior: the backdrop
// swallows that click. Every interaction while a menu happens to be open then
// costs two — one to dismiss, one to act — and a link inside the menu leaves
// the menu sitting over whatever it just opened. A capture-phase document
// listener closes on the same click that goes on to reach its target.
//
// Modal surfaces are the opposite case and keep their backdrops: a dialog, the
// workspace picker, Quick Open, and the narrow layout's drawer all mean to
// stop the page from being used until they are answered.

///|
/// Close a menu on the next click that is not its own trigger.
///
/// `key` names the running subscription, so two menus open at once (or a menu
/// reopened under a different trigger) do not share one listener. `trigger` is
/// a CSS selector for the control that toggles the menu: a click there must
/// not close it here, or the toggle that follows would reopen what the click
/// meant to dismiss. Everything else closes it, the menu's own contents
/// included — an item that acts and an item that navigates both leave.
fn dismiss_subscription(
  key : String,
  trigger~ : String,
  emit : @cmd.Emit[Unit],
) -> @sub.Sub {
  @sub.custom_sub(
    key,
    Global,
    DismissSubscription(trigger, emit),
    dismiss_sub_loader,
  )
}

///|
priv suberror DismissSubscription {
  DismissSubscription(String, @cmd.Emit[Unit])
}

///|
fn dismiss_sub_loader(
  payload : Error,
  scheduler : &Scheduler,
) -> @sub.RunningSub? {
  match payload {
    DismissSubscription(trigger, emit) => {
      let mut emit = emit
      let listener = add_dismiss_capture(trigger, () => scheduler.add(emit(())))
      Some({
        unload: _ => remove_dismiss_capture(listener),
        update_tagger: payload => {
          // The trigger belongs to the subscription's identity, not to its
          // tagger: a payload naming a different one is a different menu.
          guard payload is DismissSubscription(next_trigger, next) &&
            next_trigger == trigger else {
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
/// The listener runs in the capture phase so it sees the click before the
/// menu's own handlers, and never calls `preventDefault`: closing is all it
/// does. `closest` is guarded because an event target can be a text or SVG
/// node the method does not exist on.
extern "js" fn add_dismiss_capture(
  trigger : String,
  on_dismiss : () -> Unit,
) -> @js.Value =
  #| (trigger, onDismiss) => {
  #|   const listener = (event) => {
  #|     if (event.target?.closest?.(trigger)) return;
  #|     onDismiss();
  #|   };
  #|   document.addEventListener("click", listener, true);
  #|   return listener;
  #| }

///|
extern "js" fn remove_dismiss_capture(listener : @js.Value) -> Unit =
  #| (listener) => document.removeEventListener("click", listener, true)
