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

///|
/// Appends a mode to the encoded tokenizer state without materializing an
/// `Array[Char]`.
pub fn push(
  state : @syntax.TokenizerState,
  mode : Char,
) -> @syntax.TokenizerState {
  let state = normalize(state)
  TokenizerState("\{state.0}\{mode}")
}

///|
/// Removes the current mode directly from the encoded tokenizer state. The
/// base mode is retained so the stack is never empty.
pub fn pop(state : @syntax.TokenizerState) -> @syntax.TokenizerState {
  let state = normalize(state)
  lexscan state.0 {
    (re".$", before=remaining) =>
      if remaining.length() == 0 {
        state
      } else {
        TokenizerState(remaining.to_owned())
      }
    _ => TokenizerState("n")
  }
}
