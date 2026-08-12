///|
/// JSON (and JSONC comments) behind the `syntax.LineTokenizer` contract:
/// the trivial two-state machine. The empty state is normal; mode `b'c'` means
/// inside a `/* ... */` block comment, the one construct that carries across
/// lines.
struct JsonTokenizer {
  _unit : Unit
}

///|
/// JSON's two immutable carried states, allocated once and compared by value.
let json_normal_state : @syntax.TokenizerState = TokenizerState()

///|
let json_comment_state : @syntax.TokenizerState = json_normal_state.push_mode(
  b'c',
)

///|
/// Creates the JSON/JSONC tokenizer.
pub fn JsonTokenizer::JsonTokenizer() -> JsonTokenizer {
  { _unit: () }
}

///|
/// Initial JSON lexer state outside block comments.
pub impl @syntax.LineTokenizer for JsonTokenizer with fn initial_state(_self) {
  json_normal_state
}

///|
/// Tokenizes one JSON/JSONC line while carrying block-comment state.
pub impl @syntax.LineTokenizer for JsonTokenizer with fn tokenize_line(
  _self,
  line_text,
  state,
) {
  let tokens : Array[@syntax.LineToken] = []
  let in_comment = for at = 0, view = line_text, in_comment = state ==
                         json_comment_state {
    if in_comment {
      lexmatch view with longest {
        re"^$" => break true
        (re"^\*/", after=rest) => {
          let end = at + 2
          tokens.push({ start: at, end, tag: Comment })
          continue end, rest, false
        }
        (re"^[^*]+" as s, after=rest) => {
          let end = at + s.length()
          tokens.push({ start: at, end, tag: Comment })
          continue end, rest, true
        }
        (re"^\*", after=rest) => {
          let end = at + 1
          tokens.push({ start: at, end, tag: Comment })
          continue end, rest, true
        }
      }
    } else {
      lexmatch view with longest {
        re"^$" => break false
        (re"^[ \t]+" as s, after=rest) => continue at + s.length(), rest, false
        (re"^//.*" as s, after=rest) => {
          let end = at + s.length()
          tokens.push({ start: at, end, tag: Comment })
          continue end, rest, false
        }
        (re"^/\*", after=rest) => {
          let end = at + 2
          tokens.push({ start: at, end, tag: Comment })
          continue end, rest, true
        }
        (re"^\"(?:\\.|[^\"\\])*\"" as s, after=rest) => {
          let end = at + s.length()
          tokens.push({ start: at, end, tag: String })
          continue end, rest, false
        }
        (re"^\"(?:\\.|[^\"\\])*" as s, after=rest) => {
          let end = at + s.length()
          tokens.push({ start: at, end, tag: String })
          continue end, rest, false
        }
        (re"^-?[0-9]+(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?" as s, after=rest) => {
          let end = at + s.length()
          tokens.push({ start: at, end, tag: Number })
          continue end, rest, false
        }
        (re"^(?:true|false|null)" as s, after=rest) => {
          let end = at + s.length()
          tokens.push({ start: at, end, tag: Constant })
          continue end, rest, false
        }
        (re"^[a-zA-Z_][a-zA-Z0-9_]*" as s, after=rest) => {
          let end = at + s.length()
          tokens.push({ start: at, end, tag: Invalid })
          continue end, rest, false
        }
        (re"^[{}\[\],:]", after=rest) => {
          let end = at + 1
          tokens.push({ start: at, end, tag: Delimiter })
          continue end, rest, false
        }
        (re"^." as c, after=rest) => {
          let end = at + c.utf16_len()
          tokens.push({ start: at, end, tag: Punctuation })
          continue end, rest, false
        }
      }
    }
  }
  (tokens, if in_comment { json_comment_state } else { json_normal_state })
}
