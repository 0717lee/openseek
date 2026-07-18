// Deliberate exports with no in-repo production consumer (see
// shrink_package.md): test seams, round-trip/protocol surface, and
// future-proof API kept on purpose. Each entry documents its reason.

///|
/// The fixed case suite, ordered: exact replace, ambiguous replace,
/// multiline replace, file creation, and a compile fix — one case per
/// editing skill the `edit`/`write` tools must get right.
pub fn eval_cases() -> Array[EvalCase] {
  [
    exact_replace_case(),
    ambiguous_replace_case(),
    multiline_replace_case(),
    create_file_case(),
    compile_fix_case(),
  ]
}
