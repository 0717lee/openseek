///|
priv struct SourceRange {
  first : Int
  last_exclusive : Int
}

///|
pub fn without_comments(markdown : String) -> String {
  let ranges = comment_ranges(markdown)
  guard !ranges.is_empty() else { markdown }
  ranges.sort_by(fn(left, right) { left.first.compare(right.first) })
  remove_source_ranges(markdown, ranges)
}

///|
fn comment_ranges(markdown : String) -> Array[SourceRange] {
  let ranges = []
  let doc = @cmark.Doc::from_string(locs=true, markdown)
  ignore(
    collect_block_comment_ranges(markdown, doc.block, ranges, raw_text_tag=None),
  )
  ranges
}

///|
fn collect_block_comment_ranges(
  markdown : String,
  block : @cmark.Block,
  ranges : Array[SourceRange],
  raw_text_tag~ : String?,
) -> String? {
  match block {
    HtmlBlock(node) =>
      push_html_block_ranges(markdown, ranges, node.v, raw_text_tag~)
    Heading(node) =>
      collect_inline_comment_ranges_in(node.v.inline, ranges, raw_text_tag~)
    Paragraph(node) =>
      collect_inline_comment_ranges_in(node.v.inline, ranges, raw_text_tag~)
    BlockQuote(node) =>
      collect_block_comment_ranges(
        markdown,
        node.v.block,
        ranges,
        raw_text_tag~,
      )
    Blocks(node) => {
      let mut raw_text_tag = raw_text_tag
      for child in node.v.iter() {
        raw_text_tag = collect_block_comment_ranges(
          markdown,
          child,
          ranges,
          raw_text_tag~,
        )
      }
      raw_text_tag
    }
    List(node) => {
      let mut raw_text_tag = raw_text_tag
      for item in node.v.items.iter() {
        raw_text_tag = collect_block_comment_ranges(
          markdown,
          item.v.block,
          ranges,
          raw_text_tag~,
        )
      }
      raw_text_tag
    }
    ExtFootnoteDefinition(node) =>
      collect_block_comment_ranges(
        markdown,
        node.v.block,
        ranges,
        raw_text_tag~,
      )
    ExtTable(node) => {
      let mut raw_text_tag = raw_text_tag
      for row_entry in node.v.rows.iter() {
        let (row, _) = row_entry
        raw_text_tag = collect_table_row_comment_ranges(
          row.v,
          ranges,
          raw_text_tag~,
        )
      }
      raw_text_tag
    }
    BlankLine(_)
    | CodeBlock(_)
    | LinkRefDefinition(_)
    | ThematicBreak(_)
    | ExtMathBlock(_) => raw_text_tag
  }
}

///|
fn collect_table_row_comment_ranges(
  row : @cmark.TableRow,
  ranges : Array[SourceRange],
  raw_text_tag~ : String?,
) -> String? {
  match row {
    Header(cells) | Data(cells) => {
      let mut raw_text_tag = raw_text_tag
      for cell in cells.iter() {
        let (inline, _) = cell
        raw_text_tag = collect_inline_comment_ranges_in(
          inline,
          ranges,
          raw_text_tag~,
        )
      }
      raw_text_tag
    }
    Sep(_) => raw_text_tag
  }
}

///|
fn collect_inline_comment_ranges(
  inline : @cmark.Inline,
  ranges : Array[SourceRange],
) -> Unit {
  ignore(collect_inline_comment_ranges_in(inline, ranges, raw_text_tag=None))
}

///|
fn collect_inline_comment_ranges_in(
  inline : @cmark.Inline,
  ranges : Array[SourceRange],
  raw_text_tag~ : String?,
) -> String? {
  match inline {
    RawHtml(node) =>
      collect_inline_raw_html_comment_ranges(
        node.v,
        ranges,
        node.meta,
        raw_text_tag~,
      )
    Inlines(node) => {
      let mut raw_text_tag = raw_text_tag
      for child in node.v.iter() {
        raw_text_tag = collect_inline_comment_ranges_in(
          child,
          ranges,
          raw_text_tag~,
        )
      }
      raw_text_tag
    }
    Image(node) | Link(node) => {
      if raw_text_tag is None {
        collect_inline_comment_ranges(node.v.text, ranges)
      }
      raw_text_tag
    }
    Emphasis(node) | StrongEmphasis(node) => {
      if raw_text_tag is None {
        collect_inline_comment_ranges(node.v.inline, ranges)
      }
      raw_text_tag
    }
    ExtStrikethrough(node) => {
      if raw_text_tag is None {
        collect_inline_comment_ranges(node.v.0, ranges)
      }
      raw_text_tag
    }
    Autolink(_) | Break(_) | CodeSpan(_) | ExtMathSpan(_) | Text(_) =>
      raw_text_tag
  }
}

///|
fn push_html_block_ranges(
  markdown : String,
  ranges : Array[SourceRange],
  block : @cmark.HtmlBlock,
  raw_text_tag~ : String?,
) -> String? {
  guard block.0.get(0) is Some(first_line) else { return raw_text_tag }
  guard block.0.get(block.0.length() - 1) is Some(last_line) else {
    return raw_text_tag
  }
  let first_loc = first_line.meta.loc
  let last_loc = last_line.meta.loc
  if first_loc.is_none() ||
    first_loc.is_empty() ||
    last_loc.is_none() ||
    last_loc.is_empty() {
    return raw_text_tag
  }
  let len = markdown.length()
  let start = line_start(markdown, clamp(first_loc.first_ccode, min=0, max=len))
  let stop = clamp(last_loc.last_ccode + 1, min=start, max=len)
  push_html_comment_ranges(markdown, ranges, start~, stop~, raw_text_tag~)
}

///|
fn collect_inline_raw_html_comment_ranges(
  raw : @cmark.InlineRawHtml,
  ranges : Array[SourceRange],
  meta : @cmark_base.Meta,
  raw_text_tag~ : String?,
) -> String? {
  let text = inline_raw_html_text(raw)
  match raw_text_tag {
    Some(tag) =>
      if starts_with_closing_html_tag_at(text, 0, text.length(), tag) {
        None
      } else {
        raw_text_tag
      }
    None =>
      match raw_text_tag_at(text, 0, text.length()) {
        Some(tag) => {
          let after_open = find_html_tag_end(text, start=1, stop=text.length()).unwrap_or(
            text.length(),
          )
          if html_tag_end_is_self_closing(text, after_open) {
            None
          } else if find_raw_text_close(
              text,
              tag~,
              start=after_open,
              stop=text.length(),
            )
            is Some(_) {
            None
          } else {
            Some(tag)
          }
        }
        None => {
          if is_html_comment(text) {
            push_loc_range(ranges, meta)
          }
          None
        }
      }
  }
}

///|
fn inline_raw_html_text(raw : @cmark.InlineRawHtml) -> String {
  let text = StringBuilder()
  for tight in raw.0.iter() {
    text.write_string(tight.to_string())
  }
  text.to_string()
}

///|
fn is_html_comment(text : StringView) -> Bool {
  text.trim_start().has_prefix("<!--")
}

///|
fn push_loc_range(ranges : Array[SourceRange], meta : @cmark_base.Meta) -> Unit {
  let loc = meta.loc
  if loc.is_none() || loc.is_empty() {
    return
  }
  ranges.push({ first: loc.first_ccode, last_exclusive: loc.last_ccode + 1 })
}

///|
fn push_html_comment_ranges(
  markdown : String,
  ranges : Array[SourceRange],
  start~ : Int,
  stop~ : Int,
  raw_text_tag~ : String?,
) -> String? {
  let len = markdown.length()
  let stop = clamp(stop, min=0, max=len)
  let mut cursor = clamp(start, min=0, max=stop)
  let mut raw_text_tag = raw_text_tag
  while cursor < stop {
    match raw_text_tag {
      Some(tag) =>
        match find_raw_text_close(markdown, tag~, start=cursor, stop~) {
          Some(after_close) => {
            cursor = after_close
            raw_text_tag = None
          }
          None => cursor = stop
        }
      None =>
        if html_comment_open_at(markdown, cursor, stop) {
          match find_html_comment_close(markdown, start=cursor + 4, stop~) {
            Some(last_exclusive) => {
              ranges.push({ first: cursor, last_exclusive })
              cursor = last_exclusive
            }
            None => break
          }
        } else {
          match raw_text_tag_at(markdown, cursor, stop) {
            Some(tag) => {
              let after_open = find_html_tag_end(
                markdown,
                start=cursor + 1,
                stop~,
              ).unwrap_or(stop)
              if html_tag_end_is_self_closing(markdown, after_open) {
                cursor = after_open
              } else {
                match
                  find_raw_text_close(markdown, tag~, start=after_open, stop~) {
                  Some(after_close) => cursor = after_close
                  None => {
                    raw_text_tag = Some(tag)
                    cursor = stop
                  }
                }
              }
            }
            None =>
              if markdown[cursor] == '<' {
                cursor = find_html_tag_end(markdown, start=cursor + 1, stop~).unwrap_or(
                  cursor + 1,
                )
              } else {
                cursor = cursor + 1
              }
          }
        }
    }
  }
  raw_text_tag
}

///|
fn raw_text_tag_at(markdown : String, cursor : Int, stop : Int) -> String? {
  if starts_with_html_tag_at(markdown, cursor, stop, "pre") {
    Some("pre")
  } else if starts_with_html_tag_at(markdown, cursor, stop, "script") {
    Some("script")
  } else if starts_with_html_tag_at(markdown, cursor, stop, "style") {
    Some("style")
  } else if starts_with_html_tag_at(markdown, cursor, stop, "textarea") {
    Some("textarea")
  } else if starts_with_html_tag_at(markdown, cursor, stop, "title") {
    Some("title")
  } else {
    None
  }
}

///|
fn find_raw_text_close(
  markdown : String,
  tag~ : String,
  start~ : Int,
  stop~ : Int,
) -> Int? {
  for cursor = start; cursor < stop; cursor = cursor + 1 {
    if starts_with_closing_html_tag_at(markdown, cursor, stop, tag) {
      match
        find_html_tag_end(markdown, start=cursor + 2 + tag.length(), stop~) {
        Some(after_close) => break Some(after_close)
        None => break None
      }
    }
  } nobreak {
    None
  }
}

///|
fn find_html_tag_end(markdown : String, start~ : Int, stop~ : Int) -> Int? {
  let mut quote : UInt16? = None
  for cursor = start; cursor < stop; cursor = cursor + 1 {
    let ch = markdown.code_unit_at(cursor)
    match quote {
      Some(q) => if ch == q { quote = None }
      None =>
        if ch == 34 || ch == 39 {
          quote = Some(ch)
        } else if ch == 62 {
          break Some(cursor + 1)
        }
    }
  } nobreak {
    None
  }
}

///|
fn html_tag_end_is_self_closing(markdown : String, tag_end : Int) -> Bool {
  guard tag_end <= markdown.length() &&
    tag_end >= 2 &&
    markdown[tag_end - 1] == '>' else {
    return false
  }
  for cursor = tag_end - 2; cursor >= 0; {
    match markdown.code_unit_at(cursor) {
      32 | 9 | 10 | 13 => continue cursor - 1
      47 => break true
      _ => break false
    }
  } nobreak {
    false
  }
}

///|
fn starts_with_html_tag_at(
  markdown : String,
  cursor : Int,
  stop : Int,
  tag : String,
) -> Bool {
  guard cursor < stop && markdown[cursor] == '<' else { return false }
  html_tag_name_matches(markdown, start=cursor + 1, stop~, tag~)
}

///|
fn starts_with_closing_html_tag_at(
  markdown : String,
  cursor : Int,
  stop : Int,
  tag : String,
) -> Bool {
  guard cursor + 1 < stop &&
    markdown[cursor] == '<' &&
    markdown[cursor + 1] == '/' else {
    return false
  }
  html_tag_name_matches(markdown, start=cursor + 2, stop~, tag~)
}

///|
fn html_tag_name_matches(
  markdown : String,
  start~ : Int,
  stop~ : Int,
  tag~ : String,
) -> Bool {
  let tag_len = tag.length()
  let tag_end = start + tag_len
  guard tag_end <= stop else { return false }
  for i in 0..<tag_len {
    guard html_tag_char_matches(markdown, start + i, tag, i) else {
      return false
    }
  }
  tag_end >= stop ||
  markdown.code_unit_at(tag_end) is (32 | 9 | 10 | 13 | 47 | 62)
}

///|
fn html_tag_char_matches(
  markdown : String,
  markdown_index : Int,
  tag : String,
  tag_index : Int,
) -> Bool {
  let actual = markdown.code_unit_at(markdown_index).unsafe_to_char().to_int()
  let expected_lower = tag.code_unit_at(tag_index).unsafe_to_char().to_int()
  actual == expected_lower || actual == expected_lower - 32
}

///|
fn html_comment_open_at(markdown : String, cursor : Int, stop : Int) -> Bool {
  cursor + 3 < stop &&
  markdown[cursor] == '<' &&
  markdown[cursor + 1] == '!' &&
  markdown[cursor + 2] == '-' &&
  markdown[cursor + 3] == '-'
}

///|
fn find_html_comment_close(
  markdown : String,
  start~ : Int,
  stop~ : Int,
) -> Int? {
  let stop = clamp(stop, min=0, max=markdown.length())
  let start = clamp(start, min=0, max=stop)
  if start < stop && markdown[start] == '>' {
    return Some(start + 1)
  }
  if start + 1 < stop && markdown[start] == '-' && markdown[start + 1] == '>' {
    return Some(start + 2)
  }
  for cursor = start; cursor + 2 < stop; cursor = cursor + 1 {
    if markdown[cursor] == '-' &&
      markdown[cursor + 1] == '-' &&
      markdown[cursor + 2] == '>' {
      break Some(cursor + 3)
    }
  } nobreak {
    None
  }
}

///|
fn line_start(markdown : String, offset : Int) -> Int {
  for cursor = offset; cursor > 0; {
    if markdown[cursor - 1] == '\n' || markdown[cursor - 1] == '\r' {
      break cursor
    }
    continue cursor - 1
  } nobreak {
    cursor
  }
}

///|
fn remove_source_ranges(
  markdown : String,
  ranges : Array[SourceRange],
) -> String {
  let len = markdown.length()
  let out = StringBuilder(size_hint=len)
  let mut cursor = 0
  for range in ranges {
    let first = clamp(range.first, min=0, max=len)
    let last_exclusive = clamp(range.last_exclusive, min=0, max=len)
    if last_exclusive <= cursor {
      continue
    }
    if first > cursor {
      out.write_string(markdown.unsafe_substring(start=cursor, end=first))
    }
    cursor = last_exclusive
  }
  if cursor < len {
    out.write_string(markdown.unsafe_substring(start=cursor, end=len))
  }
  out.to_string()
}

///|
fn clamp(value : Int, min~ : Int, max~ : Int) -> Int {
  if value < min {
    min
  } else if value > max {
    max
  } else {
    value
  }
}
