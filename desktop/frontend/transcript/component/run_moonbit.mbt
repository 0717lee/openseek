// The `run_moonbit` tool's arguments, read back out of the transcript.
//
// A call to it is a whole `.mbtx` program, and the generic arguments rendering
// shows the recorded JSON: the program arrives as one long line with every
// newline spelled `\n`, so the one field a reader came for is the one field
// they cannot read. The card below lifts `source` out as verbatim program text
// and states the call's remaining arguments as chips above it.
//
// Nothing is hidden by that: the payload as the model actually sent it stays a
// click away under the card's own Original JSON disclosure, the same escape
// hatch `viz` gives its rendered tool arguments. So the card is free to show
// only what it can state plainly — an argument it cannot chip (a nested value,
// which this tool's schema has none of) is simply left to the original.
//
// Unlike the `plan` card this is not gated on the result: a snippet that
// compiled and then failed is exactly when its source matters, and for this
// tool `is_error` means the run failed, not that the arguments were refused.

///|
/// A recorded `run_moonbit` call, decoded for display.
priv struct RunMoonbitCall {
  /// The `.mbtx` program, exactly as the model sent it.
  source : String
  /// The call's other scalar arguments, as `key: value` chip text.
  chips : Array[String]
}

///|
/// Ceiling on the recorded payload worth decoding, in UTF-16 code units.
///
/// Every render decodes, including one behind a collapsed `details` (a
/// collapsed node is still built), and the transcript records a call's
/// arguments whether or not the tool accepted them — so a degenerate payload
/// reaches this package too. Past this bound the call keeps the generic
/// rendering, which clamps before parsing. Snippets are throwaway scripts, far
/// smaller than this; the bound is a cost guard, not a second copy of the
/// tool's validation.
const MAX_RUN_MOONBIT_PAYLOAD_CHARS = 128_000

///|
/// A chip's value, clamped so one pathological argument cannot push the meta
/// row across the transcript. The program itself is clamped separately, by the
/// shared `truncate_output`.
const MAX_RUN_MOONBIT_CHIP_CHARS = 120

///|
/// Decode recorded `run_moonbit` arguments, or `None` when they are not a call
/// this card can show: past the bound above, not JSON, not an object, or
/// carrying no program to display.
///
/// Deliberately more permissive than the tool's own decoder — it does not
/// re-check the target name, or that `warning` is `on`/`off`. Whether the call
/// was accepted is the paired result, not a rule re-implemented here, and a
/// second copy of the validation would only drift from the one that matters.
/// An argument with an unexpected value therefore still shows, as its own
/// chip, which is what a reader looking at a rejected call needs to see.
fn decode_run_moonbit(arguments : String) -> RunMoonbitCall? {
  if arguments.length() > MAX_RUN_MOONBIT_PAYLOAD_CHARS {
    return None
  }
  let json = @json.parse(arguments) catch { _ => return None }
  guard json is Object(fields) &&
    fields.get("source") is Some(String(source)) &&
    !source.is_blank() else {
    return None
  }
  let chips : Array[String] = []
  for key in chip_keys(fields) {
    if fields.get(key) is Some(value) && chip_text(key, value) is Some(text) {
      chips.push(text)
    }
  }
  Some({ source, chips })
}

///|
/// The argument keys to show, in display order: the ones the tool documents
/// first, in the order its README introduces them, then anything else sorted.
/// The recorded JSON's own field order is not a display order — it is whatever
/// the model emitted, and the parsed map does not promise to preserve it — so
/// without this the chip row could reorder itself between two identical calls.
fn chip_keys(fields : Map[String, Json]) -> Array[String] {
  let known = ["target", "cwd", "warning", "run_in_background"]
  let others : Array[String] = []
  for key, _ in fields {
    if key != "source" && !known.contains(key) {
      others.push(key)
    }
  }
  others.sort()
  [..known.filter(key => fields.get(key) is Some(_)), ..others]
}

///|
/// One argument as chip text, or `None` for a value the chip row cannot state
/// in one line, which the Original JSON disclosure carries instead. A JSON
/// null is the tool's own spelling of "unset", so it gets no chip either:
/// `target: null` would report a choice the model did not make.
fn chip_text(key : String, value : Json) -> String? {
  let text = match value {
    String(text) => text
    True => "true"
    False => "false"
    Number(number, repr~) =>
      match repr {
        Some(text) => text
        None => number.to_string()
      }
    Null => return None
    Object(_) | Array(_) => return None
  }
  let text = if text.length() > MAX_RUN_MOONBIT_CHIP_CHARS {
    text.clamped_view(end=MAX_RUN_MOONBIT_CHIP_CHARS).to_owned() + "…"
  } else {
    text
  }
  Some("\{key}: \{text}")
}

///|
/// The card body for a `run_moonbit` tool call: the program it asked to run,
/// verbatim, under a row of chips for the arguments that shaped the run, with
/// the recorded payload itself behind a closed disclosure. `None` when the
/// payload is not a readable call, which keeps the generic JSON rendering.
fn run_moonbit_card(arguments : String) -> @html.Html? {
  guard decode_run_moonbit(arguments) is Some(call) else { return None }
  let children : Array[@html.Html] = []
  if !call.chips.is_empty() {
    children.push(
      @html.div(
        class="run-moonbit-meta",
        call.chips.map(chip => @html.span(class="run-moonbit-chip", chip)),
      ),
    )
  }
  children.push(
    @html.pre(class="run-moonbit-source", [
      moonbit_source_code(truncate_output(call.source)),
    ]),
  )
  children.push(original_json_view(arguments))
  Some(@html.div(class="run-moonbit-args", children))
}

///|
/// Render MoonBit source with the editor's lexer and token color classes. Text
/// stays in Rabbita text nodes, so source containing HTML remains escaped.
fn moonbit_source_code(source : String) -> @html.Html {
  let tokenizer : &@syntax.LineTokenizer = @lang_moonbit.MoonBitTokenizer()
  let children : Array[@html.Html] = []
  let mut state = tokenizer.initial_state()
  for line_number, line in source.split("\n") {
    if line_number > 0 {
      children.push(@html.text("\n"))
    }
    let (tokens, next_state) = tokenizer.tokenize_line(line, state)
    state = next_state
    let mut offset = 0
    for token in tokens {
      if offset < token.start {
        children.push(
          @html.span(class="mtk1", line[offset:token.start].to_owned()),
        )
      }
      if token.start < token.end {
        children.push(
          @html.span(
            class=moonbit_token_class(token.tag),
            line[token.start:token.end].to_owned(),
          ),
        )
      }
      offset = token.end
    }
    if offset < line.length() {
      children.push(@html.span(class="mtk1", line[offset:].to_owned()))
    }
  }
  @html.code(class="language-moonbit", children)
}

///|
/// Map the lexer tags to the same Monaco color ids used by the editor model.
fn moonbit_token_class(tag : @syntax.HighlightTag) -> String {
  match tag {
    Plain => "mtk1"
    Keyword | Constant | Tag => "mtk3"
    Identifier | Variable | Attribute => "mtk4"
    String => "mtk5"
    Number => "mtk6"
    Comment | CommentDoc => "mtk7"
    Punctuation | Operator | Delimiter => "mtk8"
    Type => "mtk9"
    Function => "mtk10"
    StringEscape => "mtk11"
    Regexp => "mtk12"
    Invalid => "mtk13"
  }
}

///|
/// The recorded arguments as the model sent them, pretty-printed behind a
/// closed disclosure — so the card can render the call in the shape a reader
/// wants without becoming the only account of what was actually sent. Its open
/// state is the browser's, like every other disclosure in the transcript.
fn original_json_view(arguments : String) -> @html.Html {
  let bounded = truncate_output(arguments)
  let pretty = truncate_output(
    @json.parse(bounded).stringify(indent=2) catch {
      _ => bounded
    },
  )
  @html.details(class="run-moonbit-original", [
    @html.summary(class="run-moonbit-original-summary", "Original JSON"),
    @html.pre(class="run-moonbit-original-json", pretty),
  ])
}
