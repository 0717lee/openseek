///|
fn lex(command : String) -> LexResult {
  let chars : Array[Char] = []
  for ch in command {
    chars.push(ch)
  }
  let tokens : Array[Token] = []
  let mut word = StringBuilder()
  let mut word_empty = true
  let mut word_has_quote_or_escape = false
  let mut word_quote_or_escape_before_equals = false
  let mut word_seen_unquoted_equals = false
  let mut word_assignment_tilde_candidate = false
  let mut word_has_assignment_tilde_expansion = false
  let mut state = Plain
  let mut index = 0
  while index < chars.length() {
    let ch = chars[index]
    match state {
      Plain => {
        if is_shell_space(ch) {
          push_word(
            tokens, word, word_empty, word_has_quote_or_escape, word_quote_or_escape_before_equals,
            word_has_assignment_tilde_expansion,
          )
          word = StringBuilder()
          word_empty = true
          word_has_quote_or_escape = false
          word_quote_or_escape_before_equals = false
          word_seen_unquoted_equals = false
          word_assignment_tilde_candidate = false
          word_has_assignment_tilde_expansion = false
          index += 1
          continue
        }
        match ch {
          '\'' => {
            state = SingleQuoted
            word_empty = false
            word_has_quote_or_escape = true
            if !word_seen_unquoted_equals {
              word_quote_or_escape_before_equals = true
            }
            word_assignment_tilde_candidate = false
            index += 1
          }
          '"' => {
            state = DoubleQuoted
            word_empty = false
            word_has_quote_or_escape = true
            if !word_seen_unquoted_equals {
              word_quote_or_escape_before_equals = true
            }
            word_assignment_tilde_candidate = false
            index += 1
          }
          '\\' => {
            if index + 1 >= chars.length() {
              return LexSyntaxError("trailing backslash")
            }
            if chars[index + 1] == '\n' || chars[index + 1] == '\r' {
              return LexTooComplex("line continuation is not supported")
            }
            word.write_char(chars[index + 1])
            word_empty = false
            word_has_quote_or_escape = true
            if !word_seen_unquoted_equals {
              word_quote_or_escape_before_equals = true
            }
            word_assignment_tilde_candidate = false
            index += 2
          }
          '$' | '`' => return LexTooComplex("shell expansion is not supported")
          '(' | ')' =>
            return LexTooComplex(
              "subshells and command groups are not supported",
            )
          '{' | '}' => return LexTooComplex("brace expansion is not supported")
          '#' => return LexTooComplex("shell comments are not supported")
          '*' | '?' | '[' =>
            return LexTooComplex("unquoted glob expansion is not supported")
          '~' if word_empty =>
            return LexTooComplex("tilde expansion is not supported")
          '&' => {
            let attached = !word_empty
            push_word(
              tokens, word, word_empty, word_has_quote_or_escape, word_quote_or_escape_before_equals,
              word_has_assignment_tilde_expansion,
            )
            word = StringBuilder()
            word_empty = true
            word_has_quote_or_escape = false
            word_quote_or_escape_before_equals = false
            word_seen_unquoted_equals = false
            word_assignment_tilde_candidate = false
            word_has_assignment_tilde_expansion = false
            if peek_char(chars, index + 1) == Some('&') {
              tokens.push(Op("&&", attached))
              index += 2
            } else if peek_char(chars, index + 1) == Some('>') {
              tokens.push(Op("&>", attached))
              index += 2
            } else {
              return LexTooComplex("background operator is not supported")
            }
          }
          '|' => {
            let attached = !word_empty
            push_word(
              tokens, word, word_empty, word_has_quote_or_escape, word_quote_or_escape_before_equals,
              word_has_assignment_tilde_expansion,
            )
            word = StringBuilder()
            word_empty = true
            word_has_quote_or_escape = false
            word_quote_or_escape_before_equals = false
            word_seen_unquoted_equals = false
            word_assignment_tilde_candidate = false
            word_has_assignment_tilde_expansion = false
            if peek_char(chars, index + 1) == Some('|') {
              tokens.push(Op("||", attached))
              index += 2
            } else {
              tokens.push(Op("|", attached))
              index += 1
            }
          }
          ';' => {
            let attached = !word_empty
            push_word(
              tokens, word, word_empty, word_has_quote_or_escape, word_quote_or_escape_before_equals,
              word_has_assignment_tilde_expansion,
            )
            word = StringBuilder()
            word_empty = true
            word_has_quote_or_escape = false
            word_quote_or_escape_before_equals = false
            word_seen_unquoted_equals = false
            word_assignment_tilde_candidate = false
            word_has_assignment_tilde_expansion = false
            tokens.push(Op(";", attached))
            index += 1
          }
          '>' => {
            let attached = !word_empty
            push_word(
              tokens, word, word_empty, word_has_quote_or_escape, word_quote_or_escape_before_equals,
              word_has_assignment_tilde_expansion,
            )
            word = StringBuilder()
            word_empty = true
            word_has_quote_or_escape = false
            word_quote_or_escape_before_equals = false
            word_seen_unquoted_equals = false
            word_assignment_tilde_candidate = false
            word_has_assignment_tilde_expansion = false
            if peek_char(chars, index + 1) == Some('&') {
              tokens.push(Op(">&", attached))
              index += 2
            } else if peek_char(chars, index + 1) == Some('>') {
              tokens.push(Op(">>", attached))
              index += 2
            } else {
              tokens.push(Op(">", attached))
              index += 1
            }
          }
          '<' => {
            let attached = !word_empty
            push_word(
              tokens, word, word_empty, word_has_quote_or_escape, word_quote_or_escape_before_equals,
              word_has_assignment_tilde_expansion,
            )
            word = StringBuilder()
            word_empty = true
            word_has_quote_or_escape = false
            word_quote_or_escape_before_equals = false
            word_seen_unquoted_equals = false
            word_assignment_tilde_candidate = false
            word_has_assignment_tilde_expansion = false
            if peek_char(chars, index + 1) == Some('<') {
              return LexTooComplex("here documents are not supported")
            }
            tokens.push(Op("<", attached))
            index += 1
          }
          '\n' | '\r' => {
            let attached = !word_empty
            push_word(
              tokens, word, word_empty, word_has_quote_or_escape, word_quote_or_escape_before_equals,
              word_has_assignment_tilde_expansion,
            )
            word = StringBuilder()
            word_empty = true
            word_has_quote_or_escape = false
            word_quote_or_escape_before_equals = false
            word_seen_unquoted_equals = false
            word_assignment_tilde_candidate = false
            word_has_assignment_tilde_expansion = false
            tokens.push(Op(";", attached))
            index += 1
          }
          _ => {
            if word_assignment_tilde_candidate && ch == '~' {
              word_has_assignment_tilde_expansion = true
            }
            word.write_char(ch)
            word_empty = false
            if ch == '=' && !word_seen_unquoted_equals {
              word_seen_unquoted_equals = true
              word_assignment_tilde_candidate = true
            } else if word_seen_unquoted_equals && ch == ':' {
              word_assignment_tilde_candidate = true
            } else {
              word_assignment_tilde_candidate = false
            }
            index += 1
          }
        }
      }
      SingleQuoted => {
        if ch == '\'' {
          state = Plain
        } else {
          word.write_char(ch)
          word_empty = false
        }
        index += 1
      }
      DoubleQuoted =>
        match ch {
          '"' => {
            state = Plain
            index += 1
          }
          '$' | '`' =>
            return LexTooComplex(
              "expansion inside double quotes is not supported",
            )
          '\\' => {
            if index + 1 >= chars.length() {
              return LexSyntaxError("trailing backslash in double quotes")
            }
            let next = chars[index + 1]
            if next == '\n' || next == '\r' {
              return LexTooComplex("line continuation is not supported")
            }
            if next == '"' || next == '\\' || next == '$' || next == '`' {
              word.write_char(next)
              word_empty = false
              word_has_quote_or_escape = true
              if !word_seen_unquoted_equals {
                word_quote_or_escape_before_equals = true
              }
              word_assignment_tilde_candidate = false
              index += 2
            } else {
              word.write_char(ch)
              word_empty = false
              index += 1
            }
          }
          _ => {
            word.write_char(ch)
            word_empty = false
            index += 1
          }
        }
    }
  }
  match state {
    SingleQuoted => LexSyntaxError("unterminated single quote")
    DoubleQuoted => LexSyntaxError("unterminated double quote")
    Plain => {
      push_word(
        tokens, word, word_empty, word_has_quote_or_escape, word_quote_or_escape_before_equals,
        word_has_assignment_tilde_expansion,
      )
      LexOk(tokens)
    }
  }
}

///|
fn push_word(
  tokens : Array[Token],
  word : StringBuilder,
  empty : Bool,
  has_quote_or_escape : Bool,
  quote_or_escape_before_equals : Bool,
  has_assignment_tilde_expansion : Bool,
) -> Unit {
  if !empty {
    tokens.push(
      Word(word.to_string(), {
        has_quote_or_escape,
        quote_or_escape_before_equals,
        has_assignment_tilde_expansion,
      }),
    )
  }
}

///|
fn peek_char(chars : Array[Char], index : Int) -> Char? {
  if index < chars.length() {
    Some(chars[index])
  } else {
    None
  }
}

///|
fn is_shell_space(ch : Char) -> Bool {
  ch == ' ' || ch == '\t'
}
