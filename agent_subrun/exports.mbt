// Deliberate exports with no in-repo production consumer (see
// shrink_package.md): test seams, round-trip/protocol surface, and
// future-proof API kept on purpose. Each entry documents its reason.

///|
/// Provider prompt tokens the child consumed, summed over its requests.
/// Token accounting is part of the runner's observable contract — the
/// runner tests assert it — and completes the `steps_used`/`subrun_id`
/// getter family.
pub fn[T] SubrunResult::prompt_tokens(self : SubrunResult[T]) -> Int {
  self.prompt_tokens
}

///|
/// Completion tokens summed from the child's observed usage events.
pub fn[T] SubrunResult::completion_tokens(self : SubrunResult[T]) -> Int {
  self.completion_tokens
}
