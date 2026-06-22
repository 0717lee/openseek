///|
/// A handle for incrementally writing one transcript item.
///
/// The writer is owned by `Ui`: completed hard lines are committed into
/// scrollback, while the current unfinished line stays in the live surface until
/// `finish` commits it.
struct ItemWriter {
  ui : Ui
  item : LiveTranscriptItem
}

///|
priv struct LiveTranscriptItem {
  kind : @core.StreamingItemKind
  completed : Array[@doc.Text]
  mut current : @doc.Text
  mut finished : Bool
}

///|
fn LiveTranscriptItem::new(
  kind : @core.StreamingItemKind,
) -> LiveTranscriptItem {
  { kind, completed: [], current: Text([]), finished: false }
}

///|
fn streaming_prefix(
  kind : @core.StreamingItemKind,
  line_index : Int,
) -> @doc.Span {
  let marker = match kind {
    Response => if line_index == 0 { "⏺ " } else { "  " }
    Thought => if line_index == 0 { "✻ " } else { "  " }
  }
  Span(DisplayText(marker), style=@style.dim)
}

///|
fn streaming_line_text(
  kind : @core.StreamingItemKind,
  line : @doc.Text,
  line_index~ : Int,
) -> @doc.Text {
  line.prepend_span(streaming_prefix(kind, line_index))
}

///|
fn LiveTranscriptItem::line_rows(
  self : LiveTranscriptItem,
  line : @doc.Text,
  line_index~ : Int,
  cols~ : Int,
) -> Array[@surface.Line] {
  let rows : Array[@surface.Line] = []
  if line_index == 0 {
    rows.push(@surface.Line::new([]))
  }
  let doc = @doc.Doc::Doc([streaming_line_text(self.kind, line, line_index~)])
  for row in doc.layout(width=cols) {
    rows.push(row)
  }
  rows
}

///|
fn LiveTranscriptItem::completed_doc(self : LiveTranscriptItem) -> @doc.Doc? {
  guard self.completed.length() > 0 else { return None }
  let texts : Array[@doc.Text] = []
  for index, line in self.completed {
    texts.push(streaming_line_text(self.kind, line, line_index=index))
  }
  Some(Doc(texts))
}

///|
fn LiveTranscriptItem::current_rows(
  self : LiveTranscriptItem,
  cols~ : Int,
) -> Array[@surface.Line] {
  if self.current.is_empty() {
    return []
  }
  self.line_rows(self.current, line_index=self.completed.length(), cols~)
}

///|
fn LiveTranscriptItem::append_spans(
  self : LiveTranscriptItem,
  spans : Array[@doc.Span],
) -> Array[@doc.Text] {
  let split = self.current.append_spans(spans).split_lines()
  let completed : Array[@doc.Text] = []
  guard split.length() > 0 else {
    self.current = Text([])
    return completed
  }
  for index in 0..<(split.length() - 1) {
    completed.push(split[index])
  }
  self.current = split[split.length() - 1]
  completed
}

///|
fn Ui::live_transcript_rows(self : Ui, cols~ : Int) -> Array[@surface.Line] {
  match self.live_item {
    Some(item) => item.current_rows(cols~)
    None => []
  }
}

///|
fn ItemWriter::is_active(self : ItemWriter) -> Bool {
  !self.item.finished &&
  self.ui.live_item is Some(active) &&
  physical_equal(active, self.item)
}

///|
async fn ItemWriter::commit_completed_line(
  self : ItemWriter,
  viewport : @viewport.Viewport,
  line : @doc.Text,
) -> Unit {
  let line_index = self.item.completed.length()
  viewport.insert_before(
    self.ui.tty,
    self.item.line_rows(line, line_index~, cols=viewport.cols()),
  )
  self.item.completed.push(line)
}

///|
/// Start a streaming transcript item and return its writer.
///
/// Only one item may be open at a time. This matches the TUI's single active
/// agent turn and keeps line ownership unambiguous.
pub async fn Ui::append_streaming_item(
  self : Ui,
  kind : @core.StreamingItemKind,
) -> ItemWriter {
  let item = LiveTranscriptItem::new(kind)
  self.commands.wait(() => {
    guard self.live_item is None else { abort("streaming item already open") }
    self.live_item = Some(item)
  })
  { ui: self, item }
}

///|
/// Append styled inline fragments to this item.
///
/// Hard line breaks inside the spans complete transcript lines. Completed lines
/// are pushed to scrollback immediately; the final unfinished line remains live
/// and is redrawn in place until another hard break or `finish`.
pub async fn ItemWriter::write(
  self : ItemWriter,
  spans : Array[@doc.Span],
) -> Unit {
  self.ui.commands.wait(() => {
    guard self.is_active() else { return }
    let completed = self.item.append_spans(spans)
    guard self.ui.viewport is Some(viewport) else {
      abort("stream write without an entered UI")
    }
    viewport.refresh_size(self.ui.tty)
    for line in completed {
      self.commit_completed_line(viewport, line)
    }
    self.ui.redraw_frame(viewport)
  })
}

///|
/// Finish this item, committing any unfinished line and closing the writer.
pub async fn ItemWriter::finish(self : ItemWriter) -> Unit {
  self.ui.commands.wait(() => {
    guard self.is_active() else { return }
    guard self.ui.viewport is Some(viewport) else {
      abort("stream finish without an entered UI")
    }
    viewport.refresh_size(self.ui.tty)
    if !self.item.current.is_empty() {
      self.commit_completed_line(viewport, self.item.current)
      self.item.current = Text([])
    }
    if self.item.completed_doc() is Some(doc) {
      self.ui.transcript.push(doc)
    }
    self.item.finished = true
    self.ui.live_item = None
    self.ui.redraw_frame(viewport)
  })
}
