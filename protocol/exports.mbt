// Deliberate exports with no in-repo production consumer (see
// shrink_package.md): test seams, round-trip/protocol surface, and
// future-proof API kept on purpose. Each entry documents its reason.

///|
/// The command as a JSONL line, newline included.
pub fn Command::to_jsonl(self : Command) -> String {
  self.to_json().stringify() + "\n"
}
