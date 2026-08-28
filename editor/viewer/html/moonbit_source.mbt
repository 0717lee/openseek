///|
/// Tokenizes MoonBit source into one escaped Rabbita fragment per source line.
///
/// Each fragment carries the editor's production `mtk<n>` classes but no line
/// break or wrapper. Lexer state flows across the whole input before the array
/// is returned, so callers that add gutters or other line chrome do not lose
/// multiline comments and strings by tokenizing each line independently.
pub fn moonbit_source_lines(source : String) -> Array[@rhtml.Html] {
  let tokenizer : &@syntax.LineTokenizer = @lang_moonbit.MoonBitTokenizer()
  let lines : Array[@rhtml.Html] = []
  let mut state = tokenizer.initial_state()
  for line_view in source.split("\n") {
    let line = line_view.to_owned()
    let children : Array[@rhtml.Html] = []
    let (syntax_tokens, next_state) = tokenizer.tokenize_line(line, state)
    state = next_state
    let tokens = @model.line_tokens_from_lexer_tokens(
      line, syntax_tokens, @services.language_id_codec,
    ).inflate()
    let mut offset = 0
    for token_index in 0..<tokens.get_count() {
      let end_offset = tokens.get_end_offset(token_index)
      if offset < end_offset {
        children.push(
          @rhtml.span(
            class=tokens.get_class_name(token_index),
            line[offset:end_offset].to_owned(),
          ),
        )
      }
      offset = end_offset
    }
    lines.push(@rhtml.fragment(children))
  }
  lines
}

///|
/// Numbered rendering keeps every row of a real program: the bound exists only
/// for a degenerate payload (a transcript's argument ceiling still admits tens
/// of thousands of two-character lines), where it caps the DOM at head + tail
/// rows around one unnumbered skip marker. Recorded programs top out near 40
/// lines, so an honest clamp this generous is display-invisible in practice.
const NUMBERED_HEAD_LINES = 400

///|
const NUMBERED_TAIL_LINES = 100

///|
/// Renders MoonBit source as escaped Rabbita text nodes carrying the editor's
/// `mtk<n>` token classes. The lexer and the token-to-theme projection both use
/// the editor's production pipeline, so lightweight HTML hosts render the same
/// syntax classes as the full viewer without installing source as raw HTML.
///
/// With `numbered=true`, each line instead becomes a `moonbit-line` row pairing
/// a right-aligned 1-based line number with that line's source. Numbers are
/// space-padded to the width of the last line's number so rows align without
/// the gutter cells sharing a measured column — each row is its own
/// `moonbit-line` grid, and `white-space: pre` on the gutter keeps the padding.
/// The numbers are display chrome for matching diagnostics that cite
/// `line:column` positions, not part of the program: hosts mark the gutter
/// `user-select: none` so copied text is the source alone.
///
/// A numbered render never lies about a line's position: past the degenerate
/// line-count bound it keeps the head and tail rows under their true numbers
/// with an unnumbered `moonbit-skip` row stating what was elided, rather than
/// renumbering or growing the DOM without bound.
pub fn moonbit_source_code(
  source : String,
  numbered? : Bool = false,
) -> @rhtml.Html {
  let lines = moonbit_source_lines(source)
  if numbered {
    return numbered_rows(lines)
  }
  let children : Array[@rhtml.Html] = []
  for line_number, line in lines {
    if line_number > 0 {
      children.push(@rhtml.text("\n"))
    }
    children.push(line)
  }
  @rhtml.code(class="language-moonbit", children)
}

///|
/// The gutter grid behind `numbered=true`: one `moonbit-line` row per kept
/// line, with the degenerate line-count bound applied around an unnumbered
/// `moonbit-skip` row.
fn numbered_rows(lines : Array[@rhtml.Html]) -> @rhtml.Html {
  let width = lines.length().to_string().length()
  let rows : Array[@rhtml.Html] = []
  let push_row = (index : Int) => {
    let number = (index + 1).to_string()
    rows.push(
      @rhtml.span(class="moonbit-line", [
        @rhtml.span(
          class="moonbit-gutter",
          " ".repeat(width - number.length()) + number,
        ),
        @rhtml.code(class="language-moonbit moonbit-code", [lines[index]]),
      ]),
    )
  }
  if lines.length() <= NUMBERED_HEAD_LINES + NUMBERED_TAIL_LINES + 1 {
    for index in 0..<lines.length() {
      push_row(index)
    }
  } else {
    for index in 0..<NUMBERED_HEAD_LINES {
      push_row(index)
    }
    let skipped = lines.length() - NUMBERED_HEAD_LINES - NUMBERED_TAIL_LINES
    rows.push(
      @rhtml.span(class="moonbit-line", [
        @rhtml.span(class="moonbit-gutter", ""),
        @rhtml.span(class="moonbit-code moonbit-skip", "⋯ \{skipped} lines skipped ⋯"),
      ]),
    )
    for index in (lines.length() - NUMBERED_TAIL_LINES)..<lines.length() {
      push_row(index)
    }
  }
  @rhtml.fragment(rows)
}
