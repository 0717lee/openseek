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
  for at = 0, view = line_text; view.length() > 0; {
    let rest = lexmatch view with longest {
      (re"^[ \t]+", after=rest) => rest
      (re"^//.*" as s, after=rest) => {
        @syntax.push_token(tokens, at, at + s.length(), Comment)
        rest
      }
      (re"^\"(?:\\.|[^\"\\])*\"" as s, after=rest) => {
        @syntax.push_token(tokens, at, at + s.length(), String)
        rest
      }
      (re"^\"(?:\\.|[^\"\\])*" as s, after=rest) => {
        @syntax.push_token(tokens, at, at + s.length(), String)
        rest
      }
      (re"^[0-9][0-9_]*" as s, after=rest) => {
        @syntax.push_token(tokens, at, at + s.length(), Number)
        rest
      }
      (
        re"^@[a-zA-Z_][a-zA-Z0-9_\-]*(?:/[a-zA-Z_][a-zA-Z0-9_\-]*)*" as s,
        after=rest,
      ) => {
        @syntax.push_token(tokens, at, at + s.length(), Type)
        rest
      }
      (re"^(?:import|for)" as s, after=rest) => {
        @syntax.push_token(tokens, at, at + s.length(), Keyword)
        rest
      }
      (re"^(?:module|package)" as s, after=rest) => {
        @syntax.push_token(tokens, at, at + s.length(), Type)
        rest
      }
      (re"^(?:options|rule|dev_build)" as s, after=rest) => {
        @syntax.push_token(tokens, at, at + s.length(), Function)
        rest
      }
      (re"^as" as s, after=rest) => {
        @syntax.push_token(tokens, at, at + s.length(), Operator)
        rest
      }
      (re"^(?:true|false)" as s, after=rest) => {
        @syntax.push_token(tokens, at, at + s.length(), Constant)
        rest
      }
      (re"^[a-zA-Z_][a-zA-Z0-9_\-]*" as s, after=rest) => {
        @syntax.push_token(tokens, at, at + s.length(), Identifier)
        rest
      }
      (re"^[=]", after=rest) => {
        @syntax.push_token(tokens, at, at + 1, Operator)
        rest
      }
      (re"^[{}\[\](),:]", after=rest) => {
        @syntax.push_token(tokens, at, at + 1, Delimiter)
        rest
      }
      (re"^[/;]", after=rest) => {
        @syntax.push_token(tokens, at, at + 1, Punctuation)
        rest
      }
      (re"^.", after=rest) => {
        @syntax.push_token(
          tokens,
          at,
          at + view.length() - rest.length(),
          Punctuation,
        )
        rest
      }
      // Unreachable while `.` covers the full charset (including lone
      // surrogates); consume the rest defensively so the driver cannot stall.
      _ => ""[:]
    }
    continue at + view.length() - rest.length(), rest
  }
  (tokens, moon_config_normal_state)
}
