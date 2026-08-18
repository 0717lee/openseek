// Port of `vscode/src/vs/editor/common/diff/linesDiffComputers.ts` (vscode
// checked-in submodule): the computer
// registry.
//
// Parity ledger: `getDefault` — PORTED (package-level fn; the viewer has no
// namespace object). The other source registry entries are N-A; this package
// exposes one Core-diff-backed computer.

///|
/// `linesDiffComputers.getDefault()` (`linesDiffComputers.ts:11`).
pub fn get_default() -> DefaultLinesDiffComputer {
  DefaultLinesDiffComputer()
}
