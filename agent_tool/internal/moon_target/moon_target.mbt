///|
/// The MoonBit compilation backends accepted by `moon`'s `--target` flag. The
/// list is shared by every tool that decodes a `target` argument so a new
/// backend is added in exactly one place.
let supported_targets : Array[String] = [
  "wasm", "wasm-gc", "js", "native", "llvm", "all",
]

///|
/// Validate a `--target` value, raising the decode error tools feed back to the
/// model when it is not one of `supported_targets`.
pub fn validate_target(target : String) -> Unit raise {
  if !supported_targets.contains(target) {
    fail("arguments.target to be one of wasm, wasm-gc, js, native, llvm, all")
  }
}
