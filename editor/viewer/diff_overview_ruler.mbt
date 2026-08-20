// Diff-only overview ruler. Two 15px canvas lanes mirror VS Code's
// OverviewRulerFeature while the shared viewport delegates all input to the
// modified ordinary Viewer.

///|
let diff_overview_lane_width = 15.0

///|
let diff_overview_width = 30.0

///|
let diff_overview_minimum_marker_height = 4.0

///|
priv struct DiffOverviewMarker {
  start_line_number : Int
  height_in_lines : Int
}

///|
priv struct DiffOverviewBand {
  from : Int
  to : Int
}

///|
priv struct DiffOverviewThumb {
  top : Double
  height : Double
  max_scroll_top : Double
}

///|
fn diff_overview_thumb(
  viewport_height : Double,
  scroll_height : Double,
  scroll_top : Double,
) -> DiffOverviewThumb {
  if viewport_height <= 0.0 {
    return { top: 0.0, height: 0.0, max_scroll_top: 0.0 }
  }
  let scroll_height = scroll_height.max(viewport_height)
  let state = @view_layout.ScrollbarState(
    scrollbar_size=@core.editor_vertical_scrollbar_size,
  )
  state.set_visible_size(viewport_height) |> ignore
  state.set_scroll_size(scroll_height) |> ignore
  state.set_scroll_position(scroll_top.max(0.0)) |> ignore
  {
    top: state.slider_position(),
    height: state.slider_size(),
    max_scroll_top: (scroll_height - viewport_height).max(0.0),
  }
}

///|
fn resolve_diff_overview_bands(
  markers : Array[DiffOverviewMarker],
  line_height : Double,
  dom_height : Double,
  outer_height : Double,
  pixel_ratio : Double,
  vertical_offset_for_line : (Int) -> Double,
) -> Array[DiffOverviewBand] {
  let total_height = (dom_height * pixel_ratio).floor().to_int()
  let outer_height = outer_height.floor().to_int()
  if total_height <= 0 || outer_height <= 0 {
    return []
  }
  let height_ratio = total_height.to_double() / outer_height.to_double()
  let half_minimum_height = (diff_overview_minimum_marker_height *
    pixel_ratio /
    2.0)
    .floor()
    .to_int()
  let bands : Array[DiffOverviewBand] = []
  for marker in markers {
    let offset1 = vertical_offset_for_line(marker.start_line_number)
    let offset2 = offset1 + marker.height_in_lines.to_double() * line_height
    let y1 = (height_ratio * offset1).floor().to_int()
    let y2 = (height_ratio * offset2).floor().to_int()
    let mut center = (y1 + y2) / 2
    let mut half_height = y2 - center
    if half_height < half_minimum_height {
      half_height = half_minimum_height
    }
    if center - half_height < 0 {
      center = half_height
    }
    if center + half_height > total_height {
      center = total_height - half_height
    }
    bands.push({
      from: (center - half_height).max(0),
      to: (center + half_height).min(total_height),
    })
  }
  bands.sort_by((left, right) => {
    if left.from != right.from {
      left.from - right.from
    } else {
      left.to - right.to
    }
  })
  let merged : Array[DiffOverviewBand] = []
  for band in bands {
    if merged.is_empty() || merged[merged.length() - 1].to < band.from {
      merged.push(band)
    } else {
      let previous = merged[merged.length() - 1]
      merged[merged.length() - 1] = {
        from: previous.from,
        to: previous.to.max(band.to),
      }
    }
  }
  merged
}

///|
priv struct DiffOverviewRuler {
  parent : @rdom.Element
  root : @rdom.Element
  original_canvas : @rdom.Element
  modified_canvas : @rdom.Element
  viewport : @rdom.Element
  listeners : Array[@base_common.Disposable]
  mut theme_observer : @base_common.Disposable?
  mut disposed : Bool
}

///|
fn DiffOverviewRuler::create(
  parent : @rdom.Element,
  modified_viewer : Viewer,
) -> DiffOverviewRuler {
  let document = @rdom.document()
  let root = document.create_element("div")
  root.set_attribute("class", "diffOverview moonbit-diff-overview")
  root.set_attribute("role", "scrollbar")
  root.set_attribute("aria-label", "Diff overview")
  root.set_attribute("aria-orientation", "vertical")
  root.set_attribute("aria-valuemin", "0")
  let original_canvas = document.create_element("canvas")
  original_canvas.set_attribute(
    "class", "diffOverviewRuler original moonbit-diff-overview-original",
  )
  original_canvas.set_attribute("aria-hidden", "true")
  let modified_canvas = document.create_element("canvas")
  modified_canvas.set_attribute(
    "class", "diffOverviewRuler modified moonbit-diff-overview-modified",
  )
  modified_canvas.set_attribute("aria-hidden", "true")
  let viewport = document.create_element("div")
  viewport.set_attribute("class", "diffViewport moonbit-diff-overview-viewport")
  viewport.set_attribute("aria-hidden", "true")
  root.append_child(original_canvas.as_node())
  root.append_child(modified_canvas.as_node())
  root.append_child(viewport.as_node())
  parent.append_child(root.as_node())
  let listeners : Array[@base_common.Disposable] = []
  let pointer_down = event => {
    modified_viewer.delegate_vertical_scrollbar_pointer_down(event)
  }
  root.add_event_listener("pointerdown", pointer_down)
  listeners.push(
    @base_common.Disposable::from(() => {
      root.remove_event_listener("pointerdown", pointer_down)
    }),
  )
  let wheel = event => {
    if modified_viewer.delegate_scroll_from_mouse_wheel_event(event) {
      event.prevent_default()
      event.stop_propagation()
    }
  }
  root.add_event_listener("wheel", wheel)
  listeners.push(
    @base_common.Disposable::from(() => {
      root.remove_event_listener("wheel", wheel)
    }),
  )
  {
    parent,
    root,
    original_canvas,
    modified_canvas,
    viewport,
    listeners,
    theme_observer: None,
    disposed: false,
  }
}

///|
fn DiffOverviewRuler::observe_theme(
  self : DiffOverviewRuler,
  callback : () -> Unit,
) -> Unit {
  match self.theme_observer {
    Some(observer) => observer.dispose()
    None => ()
  }
  self.theme_observer = Some(
    @base_common.Disposable::from(
      observe_diff_overview_theme_ancestors(self.root, callback),
    ),
  )
}

///|
fn diff_overview_markers(
  changes : Array[DiffLineChange],
  original : Bool,
) -> Array[DiffOverviewMarker] {
  let markers : Array[DiffOverviewMarker] = []
  for change in changes {
    if !change.render_change {
      continue
    }
    let range = if original { change.original } else { change.modified }
    if !range.is_empty() {
      markers.push({
        start_line_number: range.start_line_number,
        height_in_lines: range.length(),
      })
    }
  }
  markers
}

///|
fn render_diff_overview_lane(
  canvas : @rdom.Element,
  viewer : Viewer,
  markers : Array[DiffOverviewMarker],
  dom_height : Double,
  color : String,
) -> Int {
  let pixel_ratio = @base_browser.device_pixel_ratio()
  prepare_diff_overview_canvas(
    canvas, diff_overview_lane_width, dom_height, pixel_ratio,
  )
  let line_height = viewer.configuration.snapshot().font_info.line_height.to_double()
  let bands = resolve_diff_overview_bands(
    markers,
    line_height,
    dom_height,
    viewer.get_scroll_height().max(dom_height),
    pixel_ratio,
    line_number => viewer.get_top_for_line_number(line_number),
  )
  for band in bands {
    fill_diff_overview_canvas_band(canvas, band.from, band.to, color)
  }
  bands.length()
}

///|
fn DiffOverviewRuler::render(
  self : DiffOverviewRuler,
  original_viewer : Viewer,
  modified_viewer : Viewer,
  changes : Array[DiffLineChange],
) -> Unit {
  if self.disposed {
    return
  }
  let height = self.root.get_bounding_client_rect().get_height().max(0.0)
  let removed_color = computed_diff_overview_color(
    self.root,
    "--vscode-diffEditorOverview-removedForeground",
    "--vscode-diffEditor-removedLineBackground",
    "rgba(255, 0, 0, 0.2)",
  )
  let inserted_color = computed_diff_overview_color(
    self.root,
    "--vscode-diffEditorOverview-insertedForeground",
    "--vscode-diffEditor-insertedLineBackground",
    "rgba(155, 185, 85, 0.2)",
  )
  self.root.set_attribute("data-original-marker-color", removed_color)
  self.root.set_attribute("data-modified-marker-color", inserted_color)
  let original_markers = diff_overview_markers(changes, true)
  let modified_markers = diff_overview_markers(changes, false)
  let original_marker_count = render_diff_overview_lane(
    self.original_canvas,
    original_viewer,
    original_markers,
    height,
    removed_color,
  )
  let modified_marker_count = render_diff_overview_lane(
    self.modified_canvas,
    modified_viewer,
    modified_markers,
    height,
    inserted_color,
  )
  let scroll_height = modified_viewer.get_scroll_height().max(height)
  let scroll_top = modified_viewer.get_scroll_top().max(0.0)
  let thumb = diff_overview_thumb(height, scroll_height, scroll_top)
  let slider_top = thumb.top
  let slider_height = thumb.height
  self.viewport.set_attribute(
    "style",
    "top:\{slider_top.to_string()}px;height:\{slider_height.to_string()}px;width:\{diff_overview_width.to_string()}px",
  )
  self.root.set_attribute("data-scroll-top", scroll_top.to_string())
  self.root.set_attribute("data-scroll-height", scroll_height.to_string())
  self.root.set_attribute(
    "data-original-scroll-top",
    original_viewer.get_scroll_top().max(0.0).to_string(),
  )
  self.root.set_attribute(
    "data-original-scroll-height",
    original_viewer.get_scroll_height().max(height).to_string(),
  )
  self.root.set_attribute(
    "data-modified-scroll-top",
    modified_viewer.get_scroll_top().max(0.0).to_string(),
  )
  self.root.set_attribute(
    "data-modified-scroll-height",
    modified_viewer.get_scroll_height().max(height).to_string(),
  )
  self.root.set_attribute(
    "data-original-scroll-left",
    original_viewer.get_scroll_left().max(0.0).to_string(),
  )
  self.root.set_attribute(
    "data-modified-scroll-left",
    modified_viewer.get_scroll_left().max(0.0).to_string(),
  )
  self.root.set_attribute("data-slider-top", slider_top.to_string())
  self.root.set_attribute("data-slider-height", slider_height.to_string())
  self.root.set_attribute(
    "data-original-marker-count",
    original_marker_count.to_string(),
  )
  self.root.set_attribute(
    "data-modified-marker-count",
    modified_marker_count.to_string(),
  )
  self.root.set_attribute(
    "data-original-change-count",
    original_markers.length().to_string(),
  )
  self.root.set_attribute(
    "data-modified-change-count",
    modified_markers.length().to_string(),
  )
  self.root.set_attribute(
    "aria-valuenow",
    scroll_top.round().to_int().to_string(),
  )
  self.root.set_attribute(
    "aria-valuemax",
    thumb.max_scroll_top.round().to_int().to_string(),
  )
}

///|
fn DiffOverviewRuler::dispose(self : DiffOverviewRuler) -> Unit {
  if self.disposed {
    return
  }
  self.disposed = true
  match self.theme_observer {
    Some(observer) => observer.dispose()
    None => ()
  }
  self.theme_observer = None
  for listener in self.listeners {
    listener.dispose()
  }
  self.listeners.clear()
  clear_diff_overview_canvas(self.original_canvas)
  clear_diff_overview_canvas(self.modified_canvas)
  self.parent.remove_child(self.root.as_node())
}

///|
extern "js" fn prepare_diff_overview_canvas(
  canvas : @rdom.Element,
  css_width : Double,
  css_height : Double,
  pixel_ratio : Double,
) -> Unit =
  #| (canvas, cssWidth, cssHeight, pixelRatio) => {
  #|   const width = Math.max(0, Math.floor(cssWidth * pixelRatio));
  #|   const height = Math.max(0, Math.floor(cssHeight * pixelRatio));
  #|   canvas.style.width = `${cssWidth}px`;
  #|   canvas.style.height = `${cssHeight}px`;
  #|   if (canvas.width !== width) canvas.width = width;
  #|   if (canvas.height !== height) canvas.height = height;
  #|   const context = canvas.getContext('2d');
  #|   context?.clearRect(0, 0, width, height);
  #| }

///|
extern "js" fn fill_diff_overview_canvas_band(
  canvas : @rdom.Element,
  from : Int,
  to : Int,
  color : String,
) -> Unit =
  #| (canvas, from, to, color) => {
  #|   const context = canvas.getContext('2d');
  #|   if (!context || to <= from) return;
  #|   context.fillStyle = color;
  #|   context.fillRect(0, from, canvas.width, to - from);
  #| }

///|
extern "js" fn clear_diff_overview_canvas(canvas : @rdom.Element) -> Unit =
  #| (canvas) => {
  #|   const context = canvas.getContext('2d');
  #|   context?.clearRect(0, 0, canvas.width, canvas.height);
  #|   canvas.width = 0;
  #|   canvas.height = 0;
  #| }

///|
extern "js" fn computed_diff_overview_color(
  element : @rdom.Element,
  primary : String,
  secondary : String,
  fallback : String,
) -> String =
  #| (element, primary, secondary, fallback) => {
  #|   const style = getComputedStyle(element);
  #|   return style.getPropertyValue(primary).trim()
  #|     || style.getPropertyValue(secondary).trim()
  #|     || fallback;
  #| }

///|
extern "js" fn observe_diff_overview_theme_ancestors(
  element : @rdom.Element,
  callback : () -> Unit,
) -> () -> Unit =
  #| (element, callback) => {
  #|   if (typeof MutationObserver === 'undefined') return () => {};
  #|   const observer = new MutationObserver(() => callback());
  #|   let current = element.parentElement;
  #|   while (current) {
  #|     observer.observe(current, {
  #|       attributes: true,
  #|       attributeFilter: ['class', 'style', 'data-theme'],
  #|     });
  #|     current = current.parentElement;
  #|   }
  #|   return () => observer.disconnect();
  #| }
