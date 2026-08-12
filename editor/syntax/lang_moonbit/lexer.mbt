///|
/// Hand-written MoonBit lexer behind the `syntax.LineTokenizer` contract.
/// Monarch's state-machine structure, but every rule set is a `lexmatch`
/// compiled to a tagged DFA at build time — no runtime regexes, no
/// grammar data.
///
/// The carried `TokenizerState` is empty because no MoonBit string construct
/// survives a line end. A mutable per-line scratch stack records lexical modes,
/// bottom first: normal expression code, string text, `$|` multiline-string
/// text, string interpolation, and nested interpolation braces.
/// No MoonBit string construct survives a line end, so every line both
/// enters and leaves in normal mode; the stack only drives within-line lexing.
struct MoonBitTokenizer {
  _unit : Unit
}

///|
/// Lexical modes used only by one `tokenize_line` invocation.
priv enum MoonBitMode {
  Normal
  StringText
  MultilineStringText
  Interpolation
  InterpolationBrace
}

///|
/// Shared immutable base stack; MoonBit's lexer always returns to it at the
/// end of a line.
let moonbit_normal_state : @syntax.TokenizerState = TokenizerState()

///|
/// Creates the MoonBit tokenizer.
pub fn MoonBitTokenizer::MoonBitTokenizer() -> MoonBitTokenizer {
  { _unit: () }
}

///|
/// Initial MoonBit lexer mode stack.
pub impl @syntax.LineTokenizer for MoonBitTokenizer with fn initial_state(_) {
  moonbit_normal_state
}

///|
/// Tokenizes one MoonBit source line and resets to normal mode at line end.
pub impl @syntax.LineTokenizer for MoonBitTokenizer with fn tokenize_line(
  _,
  line_text,
  _state,
) {
  let stack : Array[MoonBitMode] = [Normal]
  let tokens : Array[@syntax.LineToken] = []
  for at = 0, view = line_text {
    let top = stack[stack.length() - 1]
    match top {
      StringText =>
        lexmatch view with longest {
          re"^$" => break
          (re"^\\u[{][0-9a-fA-F]+[}]" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, StringEscape)
            continue end, rest
          }
          (re"^\\[{]", after=rest) => {
            let end = at + 2
            @syntax.push_token(tokens, at, end, StringEscape)
            stack.push(Interpolation)
            continue end, rest
          }
          (re"^\\." as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, StringEscape)
            continue end, rest
          }
          (re"^\"", after=rest) => {
            let end = at + 1
            @syntax.push_token(tokens, at, end, String)
            ignore(stack.pop())
            continue end, rest
          }
          (re"^[^\"\\]+" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, String)
            continue end, rest
          }
          (re"^." as c, after=rest) => {
            let end = at + c.utf16_len()
            @syntax.push_token(tokens, at, end, String)
            continue end, rest
          }
        }
      MultilineStringText =>
        lexmatch view with longest {
          re"^$" => break
          (re"^\\[{]", after=rest) => {
            let end = at + 2
            @syntax.push_token(tokens, at, end, StringEscape)
            stack.push(Interpolation)
            continue end, rest
          }
          (re"^\\." as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, StringEscape)
            continue end, rest
          }
          (re"^[^\\]+" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, String)
            continue end, rest
          }
          (re"^." as c, after=rest) => {
            let end = at + c.utf16_len()
            @syntax.push_token(tokens, at, end, String)
            continue end, rest
          }
        }
      _ =>
        lexmatch view with longest {
          re"^$" => break
          (re"^[ \t]+" as s, after=rest) => continue at + s.length(), rest
          (re"^///.*" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, CommentDoc)
            continue end, rest
          }
          (re"^//.*" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, Comment)
            continue end, rest
          }
          (re"^#\|.*" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, String)
            continue end, rest
          }
          (re"^\$\|", after=rest) => {
            let end = at + 2
            @syntax.push_token(tokens, at, end, String)
            stack.push(MultilineStringText)
            continue end, rest
          }
          (re"^#[a-zA-Z_][a-zA-Z0-9_.]*" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, Attribute)
            continue end, rest
          }
          (re"^b?\"" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, String)
            stack.push(StringText)
            continue end, rest
          }
          (re"^b?'(?:\\.|[^'\\])+'" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, String)
            continue end, rest
          }
          (re"^0[xX][0-9a-fA-F_]+[UL]*" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, Number)
            continue end, rest
          }
          (re"^0[oO][0-7_]+[UL]*" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, Number)
            continue end, rest
          }
          (re"^0[bB][01_]+[UL]*" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, Number)
            continue end, rest
          }
          (
            re"^[0-9][0-9_]*(?:\.[0-9_]+)?(?:[eE][+\-]?[0-9]+)?[ULN]*" as s,
            after=rest,
          ) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, Number)
            continue end, rest
          }
          (re"^@[a-zA-Z_][a-zA-Z0-9_/]*" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, Type)
            continue end, rest
          }
          (
            re"^(?:fnalias|traitalias|typealias|fn|let|mut|const|pub|priv|struct|enum|trait|impl|with|derive|type|suberror|raise|try|catch|noraise|async|test|if|else|match|guard|while|for|in|loop|break|continue|return|as|is|not|using|import|extern|declare|where|nobreak)" as s,
            after=rest,
          ) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, Keyword)
            continue end, rest
          }
          (re"^(?:true|false)" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, Constant)
            continue end, rest
          }
          (re"^self" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, Variable)
            continue end, rest
          }
          (re"^[A-Z][a-zA-Z0-9_]*" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, Type)
            continue end, rest
          }
          (re"^[a-z_][a-zA-Z0-9_]*" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, Identifier)
            continue end, rest
          }
          (re"^[+\-*/%=<>!&^~?\|]+" as s, after=rest) => {
            let end = at + s.length()
            @syntax.push_token(tokens, at, end, Operator)
            continue end, rest
          }
          (re"^[()\[\],;:.]", after=rest) => {
            let end = at + 1
            @syntax.push_token(tokens, at, end, Delimiter)
            continue end, rest
          }
          (re"^[{]", after=rest) => {
            let end = at + 1
            @syntax.push_token(tokens, at, end, Delimiter)
            if top is (Interpolation | InterpolationBrace) {
              stack.push(InterpolationBrace)
            }
            continue end, rest
          }
          (re"^[}]", after=rest) => {
            let end = at + 1
            if top is Interpolation {
              @syntax.push_token(tokens, at, end, StringEscape)
              ignore(stack.pop())
            } else {
              @syntax.push_token(tokens, at, end, Delimiter)
              if top is InterpolationBrace {
                ignore(stack.pop())
              }
            }
            continue end, rest
          }
          (re"^." as c, after=rest) => {
            let end = at + c.utf16_len()
            @syntax.push_token(tokens, at, end, Punctuation)
            continue end, rest
          }
        }
    }
  }
  (tokens, moonbit_normal_state)
}
