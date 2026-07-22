// Deliberate exports with no in-repo production consumer (see
// shrink_package.md): test seams, round-trip/protocol surface, and
// future-proof API kept on purpose. Each entry documents its reason.

///|
/// Ceiling a caller-supplied `max_output_chars` is clamped to, so a single
/// tool call can never flood the conversation with an arbitrarily large
/// file. Exported as a test seam: `read`'s own tests assert the decoded
/// input clamps to exactly this ceiling.
pub let hard_max_output_chars : Int = 50000
