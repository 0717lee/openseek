// System notifications are posted through the local host's
// `notification.show` method — a loopback-only operation the desktop
// window's own connection exposes. Keeping the operation in a Rabbita
// command leaves `update` pure; browser pages never emit it (the poster is
// gated on the Local channel), and their host would refuse it anyway.

///|
/// Notification banners get roughly two lines; anything longer is noise.
const NotificationBodyMaxChars : Int = 180

///|
priv struct FinishedSystemNotification {
  run_id : String
  status : String
  answer : String?
}

///|
/// Cancellation is user-initiated and stays quiet. Other terminal statuses
/// preserve the titles used by the former direct native notification path.
fn FinishedSystemNotification::title(
  self : FinishedSystemNotification,
) -> String? {
  match self.status {
    "finished" => Some("Task finished")
    "cancelled" => None
    "max_steps_exhausted" => Some("Task stopped at the step limit")
    _ => Some("Task failed")
  }
}

///|
/// Keep a Unicode character boundary while fitting the system banner.
fn FinishedSystemNotification::body(
  self : FinishedSystemNotification,
) -> String {
  guard self.answer is Some(answer) && !answer.trim().is_empty() else {
    return "The conversation is ready for you."
  }
  let out = StringBuilder()
  let mut count = 0
  for ch in answer.trim() {
    if count >= NotificationBodyMaxChars {
      out.write_string("…")
      break
    }
    out.write_char(ch)
    count += 1
  }
  out.to_string()
}

///|
/// Post the terminal notification through the local host's
/// `notification.show`. A refused method, denied permission, or lost
/// connection is deliberately silent because the transcript remains the
/// authoritative result.
fn FinishedSystemNotification::command(
  self : FinishedSystemNotification,
) -> @cmd.Cmd {
  guard self.title() is Some(title) else { return @cmd.none }
  @cmd.custom_cmd(_scheduler => {
    let payload = @js.Object::new()
    payload["title"] = title
    payload["body"] = self.body()
    payload["payload"] = self.run_id
    @js.async_run(() => {
      let _ : @js.Value = @interop.bridge_request(
        @interop.ChannelId::Local,
        "notification.show",
        payload.to_value(),
      ) catch {
        _ => return
      }
    })
  })
}

///|
test "finished system notifications preserve status titles and fallback body" {
  let completed = FinishedSystemNotification::{
    run_id: "r1",
    status: "finished",
    answer: None,
  }
  assert_eq(completed.title(), Some("Task finished"))
  assert_eq(completed.body(), "The conversation is ready for you.")
  let cancelled = { ..completed, status: "cancelled" }
  assert_eq(cancelled.title(), None)
}
