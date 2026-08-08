///|
/// Normalizes an encoded tokenizer state without decoding it into an array.
/// An empty payload is the normal base mode, matching `decode_mode_stack`.
pub fn normalize(state : @syntax.TokenizerState) -> @syntax.TokenizerState {
  if state.0 is "" {
    TokenizerState("n")
  } else {
    state
  }
}

///|
/// Reads the current mode directly from the end of the encoded stack.
pub fn top(state : @syntax.TokenizerState) -> Char {
  lexscan state.0 {
    (re".$" as mode, before=_) => mode
    _ => 'n'
  }
}
