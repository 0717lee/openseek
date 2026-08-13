///|
/// One renderer-private key for a direct child of `#stream`.
priv struct TranscriptRenderKey {
  value : String
} derive(Eq)

///|
fn TranscriptRenderKey::wire(self : TranscriptRenderKey) -> String {
  self.value
}

///|
/// Encode the renderer-private key as a DOM id without leaking separators or
/// user-controlled text into HTML syntax. Unicode scalar values are delimited,
/// so distinct render keys cannot collapse to the same owner id.
fn TranscriptRenderKey::diagram_owner(self : TranscriptRenderKey) -> String {
  let owner = StringBuilder::new()
  owner.write_string("transcript-block-")
  for unit in self.value {
    owner.write_string(unit.to_int().to_string(radix=16))
    owner.write_char('-')
  }
  owner.to_string()
}

///|
fn TranscriptRenderKey::row(identity : String) -> TranscriptRenderKey {
  { value: "row\u{0}\{identity}" }
}

///|
fn TranscriptRenderKey::turn_rule(identity : String) -> TranscriptRenderKey {
  { value: "rule\u{0}\{identity}" }
}

///|
/// An activity card belongs to the stable non-activity row on its left. New
/// reasoning or tool rows can therefore extend either end of that card without
/// replacing its browser-owned `<details>` element.
fn TranscriptRenderKey::activity_after(
  boundary : String?,
) -> TranscriptRenderKey {
  match boundary {
    Some(identity) => { value: "activity\u{0}after\u{0}\{identity}" }
    None => { value: "activity\u{0}head" }
  }
}

///|
fn TranscriptRenderKey::streaming_reasoning(
  identity : String,
) -> TranscriptRenderKey {
  { value: "streaming-reasoning\u{0}\{identity}" }
}

///|
fn TranscriptRenderKey::streaming_response(
  identity : String,
) -> TranscriptRenderKey {
  { value: "streaming-response\u{0}\{identity}" }
}

///|
fn TranscriptRenderKey::subrun(
  lane : @transcript.SubrunLane,
) -> TranscriptRenderKey {
  match lane.run {
    Some(run_id) => { value: "subrun\u{0}\{run_id}\u{0}\{lane.id}" }
    None => { value: "subrun\u{0}unowned\u{0}\{lane.id}" }
  }
}

///|
fn TranscriptRenderKey::empty() -> TranscriptRenderKey {
  { value: "empty" }
}

///|
/// One renderer-private key for a direct child of `#transcript`.
priv struct TranscriptSectionKey {
  value : String
}

///|
fn TranscriptSectionKey::wire(self : TranscriptSectionKey) -> String {
  self.value
}

///|
fn TranscriptSectionKey::overview() -> TranscriptSectionKey {
  { value: "overview" }
}

///|
/// A stream is scoped by both channel and session because separate devices
/// may legitimately use the same session id.
fn TranscriptSectionKey::stream(input : Input) -> TranscriptSectionKey {
  {
    value: "stream\u{0}\{input.focused.uri_authority()}\u{0}\{input.active_session}",
  }
}

///|
fn TranscriptSectionKey::jump_latest() -> TranscriptSectionKey {
  { value: "jump-latest" }
}

///|
/// Pure rendering context for one transcript component. Its child-building
/// methods return `Map[String, Html]`, which is the Rabbita API that preserves
/// a child by key while moving, inserting, or removing its siblings.
priv struct TranscriptRenderer {
  input : Input
  on_open : (String) -> @cmd.Cmd
  on_jump : (@mention_context.Target) -> @cmd.Cmd
}

///|
/// The data needed to render one independently updating direct stream child.
/// Its String key is shared by Rabbita's `assoc_by` branch and the keyed VDOM
/// map, while the DOM owner is used only for exact diagram wrapper ids.
priv struct TranscriptBlock {
  scope : String
  key : TranscriptRenderKey
  content : TranscriptBlockContent
} derive(Eq)

///|
priv enum TranscriptBlockContent {
  Empty
  Row(item~ : @transcript.TranscriptItem, anchor~ : String?)
  TurnRule(Double?)
  Activity(Array[@transcript.TranscriptItem])
  StreamingReasoning(content~ : String, streaming~ : Bool)
  StreamingResponse(String)
  Subrun(@transcript.SubrunLane)
} derive(Eq)

///|
fn TranscriptBlock::TranscriptBlock(
  scope : String,
  key : TranscriptRenderKey,
  content : TranscriptBlockContent,
) -> Self {
  { scope, key, content }
}

///|
fn TranscriptBlock::wire(self : TranscriptBlock) -> String {
  self.key.wire()
}

///|
fn TranscriptBlock::assoc_key(self : TranscriptBlock) -> String {
  "\{self.scope}\u{0}\{self.key.wire()}"
}

///|
fn TranscriptBlock::diagram_owner(self : TranscriptBlock) -> String {
  TranscriptRenderKey::{ value: "\{self.scope}\u{0}\{self.key.wire()}" }.diagram_owner()
}

///|
/// The stable keyed Html plus every exact diagram wrapper rendered inside it.
/// Keeping this value behind the block's `assoc_by` branch prevents unrelated
/// transcript changes from re-parsing historical Markdown.
priv struct RenderedTranscriptBlock {
  key : String
  html : @html.Html
  diagrams : Array[@markdown.MarkdownDiagram]
} derive(Eq)

///|
fn RenderedTranscriptBlock::stream_children(
  blocks : @vec.Vector[RenderedTranscriptBlock],
) -> Map[String, @html.Html] {
  let children : Map[String, @html.Html] = Map([])
  for block in blocks {
    children.set(block.key, block.html)
  }
  children
}

///|
fn RenderedTranscriptBlock::diagram_targets(
  blocks : @vec.Vector[RenderedTranscriptBlock],
) -> @vec.Vector[@markdown.MarkdownDiagram] {
  let diagrams : Array[@markdown.MarkdownDiagram] = []
  for block in blocks {
    for diagram in block.diagrams {
      diagrams.push(diagram)
    }
  }
  Vector(diagrams)
}

///|
/// Project the current transcript into stable, ordered render blocks. This is
/// pure data: callbacks and browser objects enter only inside each component.
fn TranscriptRenderer::blocks(
  self : TranscriptRenderer,
) -> @vec.Vector[TranscriptBlock] {
  let visible = self.input.items
  let scope = TranscriptSectionKey::stream(self.input).wire()
  let blocks : Array[TranscriptBlock] = []
  if visible.is_empty() {
    blocks.push(TranscriptBlock(scope, TranscriptRenderKey::empty(), Empty))
  } else {
    let mut index = 0
    let mut left_boundary : String? = None
    while index < visible.length() {
      guard visible[index].item.kind is (Tool(..) | Reasoning) else {
        let row = visible[index]
        let item = row.item
        let anchor = if item.kind is User {
          Some(@transcript_overview.TurnKey::of(item, index~).anchor())
        } else {
          None
        }
        blocks.push(
          TranscriptBlock(
            scope,
            TranscriptRenderKey::row(row.identity),
            Row(item~, anchor~),
          ),
        )
        if item.kind is User {
          blocks.push(
            TranscriptBlock(
              scope,
              TranscriptRenderKey::turn_rule(row.identity),
              TurnRule(item.ts),
            ),
          )
        }
        left_boundary = Some(row.identity)
        index = index + 1
        continue
      }
      let run : Array[@transcript.TranscriptItem] = []
      while index < visible.length() &&
            visible[index].item.kind is (Tool(..) | Reasoning) {
        run.push(visible[index].item)
        index = index + 1
      }
      blocks.push(
        TranscriptBlock(
          scope,
          TranscriptRenderKey::activity_after(left_boundary),
          Activity(run),
        ),
      )
    }
  }
  if !self.input.streaming_reasoning.is_empty() {
    blocks.push(
      TranscriptBlock(
        scope,
        TranscriptRenderKey::streaming_reasoning(self.input.streaming_identity),
        StreamingReasoning(
          content=self.input.streaming_reasoning,
          streaming=self.input.streaming_response.is_empty(),
        ),
      ),
    )
  }
  if !self.input.streaming_response.is_empty() {
    blocks.push(
      TranscriptBlock(
        scope,
        TranscriptRenderKey::streaming_response(self.input.streaming_identity),
        StreamingResponse(self.input.streaming_response),
      ),
    )
  }
  for lane in self.input.subruns {
    blocks.push(
      TranscriptBlock(scope, TranscriptRenderKey::subrun(lane), Subrun(lane)),
    )
  }
  Vector(blocks)
}

///|
/// Build the keyed direct children of `#stream` in display order. Map insertion
/// order determines visual order; the strings only determine node identity.
fn TranscriptRenderer::stream_children(
  self : TranscriptRenderer,
) -> Map[String, @html.Html] {
  let rendered : Array[RenderedTranscriptBlock] = []
  for block in self.blocks() {
    rendered.push(block.render(self.on_open, self.on_jump))
  }
  RenderedTranscriptBlock::stream_children(Vector(rendered))
}

///|
/// Build the keyed direct children of `#transcript`. The stream key includes
/// channel and session, so switching conversations replaces the entire stream
/// instead of reusing rows whose durable sequence numbers happen to match.
fn TranscriptRenderer::section_children(
  self : TranscriptRenderer,
  pinned : Bool,
  overview : @transcript_overview.State,
  overview_emit : @cmd.Emit[@transcript_overview.Msg],
  on_jump_latest : @cmd.Cmd,
  stream_children? : Map[String, @html.Html],
) -> Map[String, @html.Html] {
  let visible_items = self.input.items.map(row => row.item)
  let children : Map[String, @html.Html] = Map([])
  // The overview rail leads the scroller: sticky-top only works from the
  // content's head, and rendering it unconditionally gives it a stable key (it
  // hides itself below two turns).
  children.set(
    TranscriptSectionKey::overview().wire(),
    @transcript_overview.rail(
      @transcript_overview.entries(visible_items, display=text => {
        match @mention_context.parse(text) {
          Some(message) => message.display_text()
          None => text
        }
      }),
      overview,
      overview_emit,
      clock=ms => clock_label(ms),
    ),
  )
  children.set(
    TranscriptSectionKey::stream(self.input).wire(),
    @html.div(
      id="stream",
      class="stream",
      stream_children.unwrap_or_else(() => self.stream_children()),
    ),
  )
  // Reading history unpins auto-follow (see `watch_transcript_scroll`); the
  // floating button is the way back to the live tail. Sticky inside the
  // scroller with zero height, so it never adds scroll length.
  if !pinned {
    children.set(
      TranscriptSectionKey::jump_latest().wire(),
      @html.div(class="jump-latest-wrap", [
        @html.button(
          class="jump-latest",
          type_="button",
          title="Jump to latest",
          on_click=on_jump_latest,
          @icons.icon(@icons.icon_arrow_down),
        ),
      ]),
    )
  }
  children
}
