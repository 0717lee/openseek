///|
fn lex(command : String) -> LexResult {
  let chars : Array[Char] = []
  for ch in command {
    chars.push(ch)
  }
  let tokens : Array[Token] = []
  let mut word = StringBuilder()
  let mut word_empty = true
  let mut state = Plain
  let mut index = 0
  while index < chars.length() {
    let ch = chars[index]
    match state {
      Plain => {
        if is_shell_space(ch) {
          push_word(tokens, word, word_empty)
          word = StringBuilder()
          word_empty = true
          index += 1
          continue
        }
        match ch {
          '\'' => {
            state = SingleQuoted
            word_empty = false
            index += 1
          }
          '"' => {
            state = DoubleQuoted
            word_empty = false
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
            push_word(tokens, word, word_empty)
            word = StringBuilder()
            word_empty = true
            if peek_char(chars, index + 1) == Some('&') {
              tokens.push(Op("&&"))
              index += 2
            } else if peek_char(chars, index + 1) == Some('>') {
              tokens.push(Op("&>"))
              index += 2
            } else {
              return LexTooComplex("background operator is not supported")
            }
          }
          '|' => {
            push_word(tokens, word, word_empty)
            word = StringBuilder()
            word_empty = true
            if peek_char(chars, index + 1) == Some('|') {
              tokens.push(Op("||"))
              index += 2
            } else {
              tokens.push(Op("|"))
              index += 1
            }
          }
          ';' => {
            push_word(tokens, word, word_empty)
            word = StringBuilder()
            word_empty = true
            tokens.push(Op(";"))
            index += 1
          }
          '>' => {
            push_word(tokens, word, word_empty)
            word = StringBuilder()
            word_empty = true
            if peek_char(chars, index + 1) == Some('&') {
              tokens.push(Op(">&"))
              index += 2
            } else if peek_char(chars, index + 1) == Some('>') {
              tokens.push(Op(">>"))
              index += 2
            } else {
              tokens.push(Op(">"))
              index += 1
            }
          }
          '<' => {
            push_word(tokens, word, word_empty)
            word = StringBuilder()
            word_empty = true
            if peek_char(chars, index + 1) == Some('<') {
              return LexTooComplex("here documents are not supported")
            }
            tokens.push(Op("<"))
            index += 1
          }
          '\n' | '\r' => {
            push_word(tokens, word, word_empty)
            word = StringBuilder()
            word_empty = true
            tokens.push(Op(";"))
            index += 1
          }
          _ => {
            word.write_char(ch)
            word_empty = false
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
      push_word(tokens, word, word_empty)
      LexOk(tokens)
    }
  }
}

///|
fn push_word(tokens : Array[Token], word : StringBuilder, empty : Bool) -> Unit {
  if !empty {
    tokens.push(Word(word.to_string()))
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
