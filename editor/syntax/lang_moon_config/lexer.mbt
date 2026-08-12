///|
/// Hand-written lexer for the textual `moon.mod` and `moon.pkg` grammar.
/// MoonBit configuration has no cross-line lexical constructs, so every line
/// starts and finishes in the canonical empty tokenizer state.
struct MoonConfigTokenizer {
  _unit : Unit
}

///|
/// Shared immutable normal state for MoonBit configuration files.
let moon_config_normal_state : @syntax.TokenizerState = TokenizerState()

///|
/// Creates the MoonBit configuration tokenizer.
pub fn MoonConfigTokenizer::MoonConfigTokenizer() -> MoonConfigTokenizer {
  { _unit: () }
}

///|
/// Initial MoonBit configuration lexer state.
pub impl @syntax.LineTokenizer for MoonConfigTokenizer with fn initial_state(
  _self,
) {
  moon_config_normal_state
}

///|
/// Tokenizes one `moon.mod` or `moon.pkg` line.
pub impl @syntax.LineTokenizer for MoonConfigTokenizer with fn tokenize_line(
  _self,
  line_text,
  _state,
) {
  let tokens : Array[@syntax.LineToken] = []
  for at = 0, view = line_text {
    lexmatch view with longest {
      re"^$" => break
      (re"^[ \t]+" as s, after=rest) => continue at + s.length(), rest
      (re"^//.*" as s, after=rest) => {
        let end = at + s.length()
        @syntax.push_token(tokens, at, end, Comment)
        continue end, rest
      }
      (re"^\"(?:\\.|[^\"\\])*\"" as s, after=rest) => {
        let end = at + s.length()
        @syntax.push_token(tokens, at, end, String)
        continue end, rest
      }
      (re"^\"(?:\\.|[^\"\\])*" as s, after=rest) => {
        let end = at + s.length()
        @syntax.push_token(tokens, at, end, String)
        continue end, rest
      }
      (re"^[0-9][0-9_]*" as s, after=rest) => {
        let end = at + s.length()
        @syntax.push_token(tokens, at, end, Number)
        continue end, rest
      }
      (
        re"^@[a-zA-Z_][a-zA-Z0-9_\-]*(?:/[a-zA-Z_][a-zA-Z0-9_\-]*)*" as s,
        after=rest,
      ) => {
        let end = at + s.length()
        @syntax.push_token(tokens, at, end, Type)
        continue end, rest
      }
      (re"^(?:import|for)" as s, after=rest) => {
        let end = at + s.length()
        @syntax.push_token(tokens, at, end, Keyword)
        continue end, rest
      }
      (re"^(?:module|package)" as s, after=rest) => {
        let end = at + s.length()
        @syntax.push_token(tokens, at, end, Type)
        continue end, rest
      }
      (re"^(?:options|rule|dev_build)" as s, after=rest) => {
        let end = at + s.length()
        @syntax.push_token(tokens, at, end, Function)
        continue end, rest
      }
      (re"^as" as s, after=rest) => {
        let end = at + s.length()
        @syntax.push_token(tokens, at, end, Operator)
        continue end, rest
      }
      (re"^(?:true|false)" as s, after=rest) => {
        let end = at + s.length()
        @syntax.push_token(tokens, at, end, Constant)
        continue end, rest
      }
      (re"^[a-zA-Z_][a-zA-Z0-9_\-]*" as s, after=rest) => {
        let end = at + s.length()
        @syntax.push_token(tokens, at, end, Identifier)
        continue end, rest
      }
      (re"^[=]", after=rest) => {
        let end = at + 1
        @syntax.push_token(tokens, at, end, Operator)
        continue end, rest
      }
      (re"^[{}\[\](),:]", after=rest) => {
        let end = at + 1
        @syntax.push_token(tokens, at, end, Delimiter)
        continue end, rest
      }
      (re"^[/;]", after=rest) => {
        let end = at + 1
        @syntax.push_token(tokens, at, end, Punctuation)
        continue end, rest
      }
      (re"^." as c, after=rest) => {
        let end = at + c.utf16_len()
        @syntax.push_token(tokens, at, end, Punctuation)
        continue end, rest
      }
    }
  }
  (tokens, moon_config_normal_state)
}
