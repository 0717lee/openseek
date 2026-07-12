///|
/// Decoded arguments of the `remove` tool: delete the file at `path`, with a
/// `reason` recorded for auditing this destructive action.
pub struct RemoveInput {
  path : String
  reason : String
} derive(Debug)

///|
/// Decode `remove` tool-call arguments.
///
/// `path` and `reason` are required strings, and `reason` must not be blank — a
/// destructive action must carry a real explanation, so a whitespace-only reason
/// is rejected rather than recorded as an empty audit entry. Failures name the
/// first offending field (`arguments.reason` / `arguments.path` /
/// `object arguments`) so the error fed back to the model says exactly which
/// argument to fix.
pub fn decode(arguments : Json) -> RemoveInput raise {
  match arguments {
    { "path": String(path), "reason": String(reason), .. } => {
      guard !reason.trim().is_empty() else {
        fail("arguments.reason to be a non-empty explanation")
      }
      { path, reason }
    }
    { "path": String(_), .. } => fail("arguments.reason")
    Object(_) => fail("arguments.path")
    _ => fail("object arguments")
  }
}
