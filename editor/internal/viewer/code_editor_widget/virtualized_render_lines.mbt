// Viewport-driven detached-line rendering for tall editor-owned ViewZones.
// The retained handle owns its source projection and reacts synchronously to
// ViewZones' explicit visibility/top geometry callback. Higher layers never observe a
// browser View, configuration object, or scroll scheduler.

///|
priv struct VirtualizedRenderLinesWindow {
  start_offset : Int
  end_offset_exclusive : Int
  visible : Bool
}

///|
fn virtualized_render_lines_window(
  total_view_lines : Int,
  line_height : Double,
  viewport_height : Double,
  zone_viewport_top : Double,
  overscan_lines : Int,
  zone_visible? : Bool = true,
) -> VirtualizedRenderLinesWindow {
  if !zone_visible ||
    total_view_lines <= 0 ||
    line_height <= 0.0 ||
    viewport_height <= 0.0 {
    return { start_offset: 0, end_offset_exclusive: 0, visible: false }
  }
  let visible_start = ((-zone_viewport_top).max(0.0) / line_height)
    .floor()
    .to_int()
  let visible_end = ((viewport_height - zone_viewport_top).max(0.0) /
    line_height)
    .ceil()
    .to_int()
  let start_offset = (visible_start - overscan_lines).clamp(
    min=0,
    max=total_view_lines,
  )
  let end_offset_exclusive = (visible_end + overscan_lines).clamp(
    min=start_offset,
    max=total_view_lines,
  )
  {
    start_offset,
    end_offset_exclusive,
    visible: end_offset_exclusive > start_offset,
  }
}

///|
pub struct VirtualizedCodeEditorRenderLinesContext {
  editor : CodeEditorWidget
  source_model : @model.TextModel
  source_version : Int
  detached_view_model : @view_model.ViewModel
  configuration_options : CodeEditorOptions
  configuration_font_info : @config.FontInfo
  configuration_width : Double
  configuration_content_width : Double
  configuration_height : Double
  configuration_soft_wrap_column : Int
  owner_generation : Int
  handles : Array[VirtualizedCodeEditorRenderedLines]
  mut created_handle_count : Int
  mut live_handle_count : Int
  mut registered_zone_count : Int
  mut disposed : Bool
}

///|
pub struct VirtualizedCodeEditorRenderedLines {
  context : VirtualizedCodeEditorRenderLinesContext
  decorations : Array[CodeEditorRenderLinesDecoration]
  line_class_name : String
  margin_line_class_name : String
  dom_node : @rdom.Element
  margin_dom_node : @rdom.Element
  range_view_start : Int
  range_view_end_exclusive : Int
  line_height : Double
  height_in_px : Double
  mut discovered_min_width_in_px : Double
  mut zone_id : String?
  mut zone_delegate : @editor_browser.ViewZone?
  mut rendered_start_offset : Int
  mut rendered_end_offset_exclusive : Int
  mut rendered_visible : Bool
  mut disposed : Bool
}

///|
fn VirtualizedCodeEditorRenderedLines::configuration_snapshot(
  self : VirtualizedCodeEditorRenderedLines,
) -> EditorConfigurationSnapshot {
  {
    options: self.context.configuration_options,
    font_info: self.context.configuration_font_info,
    width: self.context.configuration_width,
    content_width: self.context.configuration_content_width,
    height: self.context.configuration_height,
    soft_wrap_column: self.context.configuration_soft_wrap_column,
  }
}

///|
pub fn VirtualizedCodeEditorRenderLinesContext::owner_generation(
  self : VirtualizedCodeEditorRenderLinesContext,
) -> Int {
  self.owner_generation
}

///|
pub fn VirtualizedCodeEditorRenderLinesContext::created_handle_count(
  self : VirtualizedCodeEditorRenderLinesContext,
) -> Int {
  self.created_handle_count
}

///|
pub fn VirtualizedCodeEditorRenderLinesContext::live_handle_count(
  self : VirtualizedCodeEditorRenderLinesContext,
) -> Int {
  self.live_handle_count
}

///|
pub fn VirtualizedCodeEditorRenderLinesContext::registered_zone_count(
  self : VirtualizedCodeEditorRenderLinesContext,
) -> Int {
  self.registered_zone_count
}

///|
pub fn VirtualizedCodeEditorRenderLinesContext::is_disposed(
  self : VirtualizedCodeEditorRenderLinesContext,
) -> Bool {
  self.disposed
}

///|
pub fn VirtualizedCodeEditorRenderedLines::dom_node(
  self : VirtualizedCodeEditorRenderedLines,
) -> @rdom.Element {
  self.dom_node
}

///|
pub fn VirtualizedCodeEditorRenderedLines::margin_dom_node(
  self : VirtualizedCodeEditorRenderedLines,
) -> @rdom.Element {
  self.margin_dom_node
}

///|
pub fn VirtualizedCodeEditorRenderedLines::height_in_px(
  self : VirtualizedCodeEditorRenderedLines,
) -> Double {
  self.height_in_px
}

///|
pub fn VirtualizedCodeEditorRenderedLines::min_width_in_px(
  self : VirtualizedCodeEditorRenderedLines,
) -> Double {
  self.discovered_min_width_in_px
}

///|
pub fn VirtualizedCodeEditorRenderedLines::view_line_count(
  self : VirtualizedCodeEditorRenderedLines,
) -> Int {
  self.range_view_end_exclusive - self.range_view_start
}

///|
pub fn VirtualizedCodeEditorRenderedLines::is_disposed(
  self : VirtualizedCodeEditorRenderedLines,
) -> Bool {
  self.disposed
}

///|
fn VirtualizedCodeEditorRenderedLines::clear_window(
  self : VirtualizedCodeEditorRenderedLines,
) -> Unit {
  if self.rendered_visible || self.rendered_end_offset_exclusive > 0 {
    self.dom_node.set_inner_html("")
    self.margin_dom_node.set_inner_html("")
  }
  self.rendered_start_offset = 0
  self.rendered_end_offset_exclusive = 0
  self.rendered_visible = false
  self.dom_node.set_attribute("data-rendered-view-line-count", "0")
}

///|
fn VirtualizedCodeEditorRenderedLines::update_zone_min_width(
  self : VirtualizedCodeEditorRenderedLines,
  min_width_in_px : Double,
) -> Unit {
  let next_width = min_width_in_px.max(0.0).min(1000000.0)
  if (next_width - self.discovered_min_width_in_px).abs() <= 0.5 {
    return
  }
  self.discovered_min_width_in_px = next_width
  self.dom_node.set_attribute(
    "data-discovered-min-width",
    next_width.to_string(),
  )
  guard !self.context.editor.disposed &&
    self.zone_id is Some(zone_id) &&
    self.zone_delegate is Some(zone_delegate) else {
    return
  }
  zone_delegate.min_width_in_px = Some(next_width)
  self.context.editor.change_view_zones(accessor => {
    accessor.layout_zone(zone_id)
  })
}

///|
fn VirtualizedCodeEditorRenderedLines::bind_zone(
  self : VirtualizedCodeEditorRenderedLines,
  zone_id : String,
  zone_delegate : @editor_browser.ViewZone,
) -> Unit {
  if self.disposed {
    return
  }
  if self.zone_id is None {
    self.context.registered_zone_count += 1
  }
  self.zone_id = Some(zone_id)
  self.zone_delegate = Some(zone_delegate)
  if self.discovered_min_width_in_px > 0.0 {
    zone_delegate.min_width_in_px = Some(self.discovered_min_width_in_px)
    self.context.editor.change_view_zones(accessor => {
      accessor.layout_zone(zone_id)
    })
  }
}

///|
fn VirtualizedCodeEditorRenderedLines::render_for_zone_layout(
  self : VirtualizedCodeEditorRenderedLines,
  visible : Bool,
  zone_viewport_top : Double,
) -> Unit {
  if self.disposed ||
    self.context.disposed ||
    self.context.editor.disposed ||
    self.context.source_model.is_disposed() ||
    self.context.source_model.get_version_id() != self.context.source_version {
    self.clear_window()
    return
  }
  let viewport_height = self.context.editor.configuration.snapshot().height.max(
    self.line_height * 20.0,
  )
  let window = virtualized_render_lines_window(
    self.view_line_count(),
    self.line_height,
    viewport_height,
    zone_viewport_top,
    8,
    zone_visible=visible,
  )
  if window.start_offset == self.rendered_start_offset &&
    window.end_offset_exclusive == self.rendered_end_offset_exclusive &&
    window.visible == self.rendered_visible {
    return
  }
  if !window.visible {
    self.clear_window()
    return
  }
  let window_view_start = self.range_view_start + window.start_offset
  let window_view_end_exclusive = self.range_view_start +
    window.end_offset_exclusive
  let converter = self.context.detached_view_model.coordinates_converter()
  let first_data = self.context.detached_view_model
    .lines()
    .view_line_rendering_data(window_view_start)
  let final_view_line = window_view_end_exclusive - 1
  let final_data = self.context.detached_view_model
    .lines()
    .view_line_rendering_data(final_view_line)
  let first_model_line = converter.view_position_to_model_position(
      Position(window_view_start, first_data.min_column),
    ).line_number
  let final_model_line = converter.view_position_to_model_position(
      Position(final_view_line, final_data.max_column),
    ).line_number
  stabilize_render_lines_tokens(
    self.context.source_model,
    first_model_line,
    final_model_line + 1,
  )
  let rendered = render_detached_view_line_window(
    self.context.detached_view_model,
    self.configuration_snapshot(),
    self.range_view_start,
    window_view_start,
    window_view_end_exclusive,
    self.decorations,
    self.line_class_name,
    self.margin_line_class_name,
  )
  self.dom_node.set_inner_html(rendered.content_html)
  self.margin_dom_node.set_inner_html(rendered.margin_html)
  self.dom_node.set_attribute(
    "data-render-window-start-view-line",
    window_view_start.to_string(),
  )
  self.dom_node.set_attribute(
    "data-render-window-end-exclusive-view-line",
    window_view_end_exclusive.to_string(),
  )
  self.dom_node.set_attribute(
    "data-rendered-view-line-count",
    (window_view_end_exclusive - window_view_start).to_string(),
  )
  self.dom_node.set_attribute(
    "data-render-window-start-model-line",
    first_model_line.to_string(),
  )
  self.dom_node.set_attribute(
    "data-render-window-end-model-line",
    final_model_line.to_string(),
  )
  self.rendered_start_offset = window.start_offset
  self.rendered_end_offset_exclusive = window.end_offset_exclusive
  self.rendered_visible = window.visible
  self.update_zone_min_width(
    self.discovered_min_width_in_px.max(rendered.max_content_width + 16.0),
  )
}

///|
pub fn VirtualizedCodeEditorRenderedLines::managed_view_zone_spec(
  self : VirtualizedCodeEditorRenderedLines,
  after_line_number : Int,
  ordinal? : Int,
  suppress_mouse_down? : Bool = false,
) -> ManagedCodeEditorViewZoneSpec {
  ManagedCodeEditorViewZoneSpec(
    after_line_number,
    self.height_in_px,
    self.dom_node,
    margin_dom_node=self.margin_dom_node,
    min_width_in_px=0.0,
    ordinal?,
    suppress_mouse_down~,
    on_dom_node_layout=(visible, top) => {
      self.render_for_zone_layout(visible, top)
    },
    on_zone_registered=(zone_id, zone_delegate) => {
      self.bind_zone(zone_id, zone_delegate)
    },
  )
}

///|
/// Reveals this handle's installed ViewZone at its exact content-space top.
/// Returns false before registration, after disposal, or after its editor/model
/// lifetime ended.
pub fn VirtualizedCodeEditorRenderedLines::reveal_zone_top(
  self : VirtualizedCodeEditorRenderedLines,
) -> Bool {
  if self.disposed || self.context.disposed {
    return false
  }
  guard self.zone_id is Some(zone_id) else { return false }
  self.context.editor.reveal_managed_view_zone_top(zone_id)
}

///|
fn VirtualizedCodeEditorRenderedLines::dispose_handle(
  self : VirtualizedCodeEditorRenderedLines,
  update_zone_min_width? : Bool = true,
) -> Unit {
  if self.disposed {
    return
  }
  if update_zone_min_width {
    self.update_zone_min_width(0.0)
  }
  self.disposed = true
  self.clear_window()
  if self.zone_id is Some(_) {
    self.context.registered_zone_count = (self.context.registered_zone_count - 1).max(
      0,
    )
  }
  self.zone_id = None
  self.zone_delegate = None
  self.context.live_handle_count = (self.context.live_handle_count - 1).max(0)
  self.dom_node.set_attribute("data-virtualized-render-lines-disposed", "true")
}

///|
pub fn VirtualizedCodeEditorRenderedLines::dispose(
  self : VirtualizedCodeEditorRenderedLines,
) -> Unit {
  self.dispose_handle()
}

///|
pub fn VirtualizedCodeEditorRenderLinesContext::dispose(
  self : VirtualizedCodeEditorRenderLinesContext,
) -> Unit {
  if self.disposed {
    return
  }
  // Mark the context first so an owning convenience handle cannot recurse
  // through `dispose` while the shared handle set is being drained.
  self.disposed = true
  for handle in self.handles {
    // The owning DiffEditor removes every old zone in one managed-zone
    // transaction. Per-handle width relayout here would turn a fragmented
    // generation teardown into O(hunks) layout transactions.
    handle.dispose_handle(update_zone_min_width=false)
  }
  self.handles.clear()
  self.detached_view_model.dispose()
  self.registered_zone_count = 0
}

///|
let virtualized_render_lines_context_view_model_creations : Ref[Int] = Ref(0)

///|
/// Creates one detached rendering context for a complete diff generation.
/// Every deleted-zone handle for that generation must come from this context,
/// so fragmented diffs retain one ViewModel/listener graph rather than one per
/// hunk.
pub fn CodeEditorWidget::create_render_lines_context(
  self : CodeEditorWidget,
  source_model : @model.TextModel,
  owner_generation? : Int = 0,
) -> VirtualizedCodeEditorRenderLinesContext? {
  if self.disposed || source_model.is_disposed() {
    return None
  }
  let configuration = self.configuration.snapshot()
  let detached_view_model = @view_model.ViewModel::with_options(
    source_model,
    configuration.view_model_options(0),
  )
  virtualized_render_lines_context_view_model_creations.val += 1
  Some({
    editor: self,
    source_model,
    source_version: source_model.get_version_id(),
    detached_view_model,
    configuration_options: configuration.options,
    configuration_font_info: configuration.font_info,
    configuration_width: configuration.width,
    configuration_content_width: configuration.content_width,
    configuration_height: configuration.height,
    configuration_soft_wrap_column: configuration.soft_wrap_column,
    owner_generation,
    handles: [],
    created_handle_count: 0,
    live_handle_count: 0,
    registered_zone_count: 0,
    disposed: false,
  })
}

///|
fn VirtualizedCodeEditorRenderLinesContext::render_lines_impl(
  self : VirtualizedCodeEditorRenderLinesContext,
  line_range : @base_common.LineRange,
  decorations : Array[CodeEditorRenderLinesDecoration],
  line_class_name : String,
  margin_line_class_name : String,
) -> VirtualizedCodeEditorRenderedLines? {
  if self.disposed ||
    self.editor.disposed ||
    self.source_model.is_disposed() ||
    self.source_model.get_version_id() != self.source_version {
    return None
  }
  let start_line_number = line_range.start_line_number.max(1)
  let end_line_number_exclusive = line_range.end_line_number_exclusive.min(
    self.source_model.get_line_count() + 1,
  )
  if start_line_number >= end_line_number_exclusive {
    return None
  }
  let converter = self.detached_view_model.coordinates_converter()
  let range_view_start = converter.model_position_to_view_position(
      Position(start_line_number, 1),
    ).line_number
  let final_model_line = end_line_number_exclusive - 1
  let range_view_end_exclusive = converter.model_position_to_view_position(
      Position(
        final_model_line,
        self.source_model.get_line_max_column(final_model_line),
      ),
    ).line_number +
    1
  let line_height = self.configuration_font_info.line_height.to_double()
  let view_line_count = range_view_end_exclusive - range_view_start
  let dom_node = @rdom.document().create_element("div")
  dom_node.set_attribute("class", "view-lines")
  dom_node.set_attribute("data-virtualized-render-lines", "true")
  dom_node.set_attribute(
    "data-render-lines-generation",
    self.owner_generation.to_string(),
  )
  let margin_dom_node = @rdom.document().create_element("div")
  margin_dom_node.set_attribute("data-virtualized-render-lines", "true")
  margin_dom_node.set_attribute(
    "data-render-lines-generation",
    self.owner_generation.to_string(),
  )
  let bare_font_info = self.configuration_font_info.bare()
  @browser_config.apply_font_info(dom_node, bare_font_info)
  @browser_config.apply_font_info(margin_dom_node, bare_font_info)
  let handle : VirtualizedCodeEditorRenderedLines = {
    context: self,
    decorations,
    line_class_name,
    margin_line_class_name,
    dom_node,
    margin_dom_node,
    range_view_start,
    range_view_end_exclusive,
    line_height,
    height_in_px: view_line_count.to_double() * line_height,
    discovered_min_width_in_px: 0.0,
    zone_id: None,
    zone_delegate: None,
    rendered_start_offset: 0,
    rendered_end_offset_exclusive: 0,
    rendered_visible: false,
    disposed: false,
  }
  self.handles.push(handle)
  self.created_handle_count += 1
  self.live_handle_count += 1
  Some(handle)
}

///|
pub fn VirtualizedCodeEditorRenderLinesContext::render_lines(
  self : VirtualizedCodeEditorRenderLinesContext,
  line_range : @base_common.LineRange,
  decorations? : Array[CodeEditorRenderLinesDecoration] = [],
  line_class_name? : String = "",
  margin_line_class_name? : String = "",
) -> VirtualizedCodeEditorRenderedLines? {
  self.render_lines_impl(
    line_range, decorations, line_class_name, margin_line_class_name,
  )
}
