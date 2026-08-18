// Monaco's standalone diff-editor composition: two normal Viewer instances
// coordinated by line-level diff state. Side-by-side mode shows both children;
// unified mode keeps the modified child as the interactive editor and projects
// deleted original lines into it as tokenized ViewZones. The child Viewers
// deliberately remain ordinary editors so every model-scoped contribution
// (tokenization, hover, Definition/Peek, selection, feedback) follows the
// existing Viewer path.
//
// Remaining exclusions are explicit: no moved blocks, true-inline single-line
// rendering, revert actions, unchanged-region collapsing, or overview ruler.
// Soft wrapping and folding are disabled in the child panes because
// fixed-height logical lines are the invariant behind both ViewZone layouts.

///|
/// The presentation selected for one DiffViewer. Both modes retain the same
/// two models and ordinary child Viewers; changing this value is a rendering
/// operation, not a model swap.
pub(all) enum DiffEditorRenderMode {
  SideBySide
  Unified
} derive(Eq, Debug)

///|
/// The two caller-owned text models displayed by a DiffViewer. Like Monaco's
/// `IDiffEditorModel`, the comparison owns neither model and never disposes
/// them.
pub(all) struct DiffEditorModel {
  original : @model.TextModel
  modified : @model.TextModel
}

///|
pub fn DiffEditorModel::DiffEditorModel(
  original : @model.TextModel,
  modified : @model.TextModel,
) -> DiffEditorModel {
  { original, modified }
}

///|
/// A switchable diff surface composed from two ordinary Viewer instances.
/// The caller owns `host` and must keep it stable and otherwise child-free.
struct DiffViewer {
  host : @rdom.Element
  root : @rdom.Element
  original_host : @rdom.Element
  modified_host : @rdom.Element
  original_viewer : Viewer
  modified_viewer : Viewer
  owned_services : ViewerServices?
  mut render_mode : DiffEditorRenderMode
  mut resize_observer : @base_common.Disposable?
  scroll_disposables : Array[@base_common.Disposable]
  model_disposables : Array[@base_common.Disposable]
  mut original_decoration_ids : Array[String]
  mut modified_decoration_ids : Array[String]
  mut original_zone_ids : Array[String]
  mut modified_zone_ids : Array[String]
  mut disposed : Bool
}

///|
/// Create an empty comparison in a stable host. An explicit service bundle is
/// borrowed and shared by both panes; when omitted, one bundle is created and
/// owned by the DiffViewer. Hosts can keep original-revision semantic requests
/// inert by giving that model a URI outside their live-document selectors. The
/// comparison observes its outer host because either child may be constructed
/// while the caller keeps that host at `display: none`; revealing or resizing
/// the host then remeasures both ordinary Viewer panes automatically.
pub fn DiffViewer::create(
  host : @rdom.Element,
  services? : ViewerServices,
  options? : ViewerOptions = ViewerOptions::default(),
  render_mode? : DiffEditorRenderMode = SideBySide,
) -> DiffViewer {
  let document = @rdom.document()
  let root = document.create_element("section")
  root.set_attribute("class", "moonbit-diff-editor")
  root.set_attribute("role", "region")
  root.set_attribute("aria-label", "File comparison")
  let original_host = document.create_element("div")
  original_host.set_attribute(
    "class", "moonbit-diff-editor-pane moonbit-diff-editor-original",
  )
  original_host.set_attribute("role", "group")
  original_host.set_attribute("aria-label", "Original file")
  let modified_host = document.create_element("div")
  modified_host.set_attribute(
    "class", "moonbit-diff-editor-pane moonbit-diff-editor-modified",
  )
  modified_host.set_attribute("role", "group")
  modified_host.set_attribute("aria-label", "Modified file")
  root.append_child(original_host.as_node())
  root.append_child(modified_host.as_node())
  host.append_child(root.as_node())

  let (shared_services, owned_services) = match services {
    Some(services) => (services, None)
    None => {
      let services = ViewerServices()
      (services, Some(services))
    }
  }
  // Logical-line alignment currently relies on one fixed line height. Keep
  // the rest of the host's visual/runtime policy intact.
  let pane_options = { ..options, soft_wrap: false, folding: false }
  let original_viewer = create_diff_pane(
    original_host, shared_services, pane_options,
  )
  let modified_viewer = create_diff_pane(
    modified_host, shared_services, pane_options,
  )
  let diff_viewer : DiffViewer = {
    host,
    root,
    original_host,
    modified_host,
    original_viewer,
    modified_viewer,
    owned_services,
    render_mode,
    resize_observer: None,
    scroll_disposables: [],
    model_disposables: [],
    original_decoration_ids: [],
    modified_decoration_ids: [],
    original_zone_ids: [],
    modified_zone_ids: [],
    disposed: false,
  }
  diff_viewer.apply_render_mode_dom()
  diff_viewer.scroll_disposables.push(
    original_viewer.on_did_scroll_change(event => {
      if diff_viewer.render_mode == SideBySide && event.scroll_top_changed {
        diff_viewer.sync_scroll_top_to(modified_viewer, event.scroll_top)
      }
      if diff_viewer.render_mode == SideBySide && event.scroll_left_changed {
        diff_viewer.sync_scroll_left_to(modified_viewer, event.scroll_left)
      }
    }),
  )
  diff_viewer.scroll_disposables.push(
    modified_viewer.on_did_scroll_change(event => {
      if event.scroll_top_changed {
        diff_viewer.sync_scroll_top_to(original_viewer, event.scroll_top)
      }
      if event.scroll_left_changed {
        diff_viewer.sync_scroll_left_to(original_viewer, event.scroll_left)
      }
    }),
  )
  diff_viewer.resize_observer = @base_browser.observe_element_resize(host, () => {
    diff_viewer.layout()
  })
  diff_viewer
}

///|
fn create_diff_pane(
  host : @rdom.Element,
  services : ViewerServices,
  options : ViewerOptions,
) -> Viewer {
  let viewer = Viewer(
    services~,
    options~,
    initial_container=host,
    force_code_presentation=true,
  )
  viewer.attach(host)
  viewer
}

///|
/// Replace or clear the comparison. Reapplying the same models is cheap but
/// still recomputes presentation so callers can explicitly refresh diff state.
pub fn DiffViewer::set_model(
  self : DiffViewer,
  diff_model : DiffEditorModel?,
) -> Unit {
  if self.disposed {
    return
  }
  self.dispose_model_disposables()
  self.clear_diff_artifacts()
  match diff_model {
    None => {
      self.original_viewer.set_model(None)
      self.modified_viewer.set_model(None)
    }
    Some(diff_model) => {
      self.original_viewer.set_model(Some(diff_model.original))
      self.modified_viewer.set_model(Some(diff_model.modified))
      self.model_disposables.push(
        diff_model.original.on_did_change_content(_ => self.refresh_diff()),
      )
      self.model_disposables.push(
        diff_model.original.on_did_change_tokens(_ => {
          if self.render_mode == Unified {
            self.refresh_diff()
          }
        }),
      )
      self.model_disposables.push(
        diff_model.modified.on_did_change_content(_ => self.refresh_diff()),
      )
      self.refresh_diff()
      self.original_viewer.handle_initialized()
      self.modified_viewer.handle_initialized()
    }
  }
}

///|
/// The currently installed pair, or `None` while either pane is empty.
pub fn DiffViewer::get_model(self : DiffViewer) -> DiffEditorModel? {
  match (self.original_viewer.get_model(), self.modified_viewer.get_model()) {
    (Some(original), Some(modified)) => Some({ original, modified })
    _ => None
  }
}

///|
/// The current comparison presentation.
pub fn DiffViewer::get_render_mode(self : DiffViewer) -> DiffEditorRenderMode {
  self.render_mode
}

///|
/// Switch the existing comparison between two panes and one interleaved pane.
/// Models, services, selections, and the modified Viewer's scroll state stay
/// installed. Rebuilding only coordinator-owned decorations and ViewZones also
/// makes repeated calls idempotent.
pub fn DiffViewer::set_render_mode(
  self : DiffViewer,
  render_mode : DiffEditorRenderMode,
) -> Unit {
  if self.disposed || self.render_mode == render_mode {
    return
  }
  self.render_mode = render_mode
  self.apply_render_mode_dom()
  self.layout()
  self.refresh_diff()
  if render_mode == SideBySide {
    self.sync_scroll_top_to(
      self.original_viewer,
      self.modified_viewer.get_scroll_top(),
    )
    self.sync_scroll_left_to(
      self.original_viewer,
      self.modified_viewer.get_scroll_left(),
    )
  }
}

///|
/// Clear the comparison while retaining the reusable two-pane surface.
pub fn DiffViewer::clear(self : DiffViewer) -> Unit {
  self.set_model(None)
}

///|
/// Re-measure both child hosts after their caller-controlled layout changes.
pub fn DiffViewer::layout(self : DiffViewer) -> Unit {
  if !self.disposed {
    self.original_viewer.layout()
    self.modified_viewer.layout()
  }
}

///|
/// Release both Viewers and all coordinator-owned state. Caller models and an
/// explicitly supplied ViewerServices bundle remain caller-owned.
pub fn DiffViewer::dispose(self : DiffViewer) -> Unit {
  if self.disposed {
    return
  }
  match self.resize_observer {
    Some(observer) => observer.dispose()
    None => ()
  }
  self.resize_observer = None
  self.dispose_model_disposables()
  for disposable in self.scroll_disposables {
    disposable.dispose()
  }
  self.scroll_disposables.clear()
  self.clear_diff_artifacts()
  self.original_viewer.dispose()
  self.modified_viewer.dispose()
  self.host.remove_child(self.root.as_node())
  match self.owned_services {
    Some(services) => services.dispose()
    None => ()
  }
  self.disposed = true
}

///|
fn DiffViewer::dispose_model_disposables(self : DiffViewer) -> Unit {
  for disposable in self.model_disposables {
    disposable.dispose()
  }
  self.model_disposables.clear()
}

///|
fn DiffViewer::apply_render_mode_dom(self : DiffViewer) -> Unit {
  match self.render_mode {
    SideBySide => {
      self.root.set_attribute(
        "class", "moonbit-diff-editor moonbit-diff-editor-side-by-side",
      )
      self.root.set_attribute("data-render-mode", "side-by-side")
      self.original_host.remove_attribute("aria-hidden")
      self.modified_host.set_attribute("aria-label", "Modified file")
    }
    Unified => {
      self.root.set_attribute(
        "class", "moonbit-diff-editor moonbit-diff-editor-unified",
      )
      self.root.set_attribute("data-render-mode", "unified")
      self.original_host.set_attribute("aria-hidden", "true")
      self.modified_host.set_attribute("aria-label", "Unified diff")
    }
  }
}

///|
fn DiffViewer::sync_scroll_top_to(
  self : DiffViewer,
  target : Viewer,
  scroll_top : Double,
) -> Unit {
  if !self.disposed && (target.get_scroll_top() - scroll_top).abs() > 0.5 {
    target.set_scroll_top(scroll_top)
  }
}

///|
fn DiffViewer::sync_scroll_left_to(
  self : DiffViewer,
  target : Viewer,
  scroll_left : Double,
) -> Unit {
  if !self.disposed && (target.get_scroll_left() - scroll_left).abs() > 0.5 {
    target.set_scroll_left(scroll_left)
  }
}

///|
fn DiffViewer::refresh_diff(self : DiffViewer) -> Unit {
  if self.disposed {
    return
  }
  guard self.get_model() is Some(diff_model) else { return }
  self.clear_diff_artifacts()
  let diff = @diff.get_default().compute_diff(
    diff_model.original.get_lines_content(),
    diff_model.modified.get_lines_content(),
    {
      ignore_trim_whitespace: false,
      max_computation_time_ms: 5000,
      compute_moves: false,
    },
  )
  let changes : Array[DiffLineChange] = diff.changes.map(change => {
    original: change.original,
    modified: change.modified,
    inner_changes: change.get_inner_changes(),
  })
  let presentation = diff_presentation(changes)
  let modified_decorations = line_decorations(
    diff_model.modified,
    presentation.modified_changed,
    "diff-editor-line-insert",
    "diff-editor-gutter-insert",
    "diff-editor-modified-line",
  )
  modified_decorations.append(
    inline_decorations(
      presentation.modified_inner_changed,
      "diff-editor-char-insert",
      "diff-editor-modified-character",
    ),
  )
  self.modified_decoration_ids = self.modified_viewer.delta_decorations(
    [],
    modified_decorations,
  )
  match self.render_mode {
    SideBySide => {
      let original_decorations = line_decorations(
        diff_model.original,
        presentation.original_changed,
        "diff-editor-line-delete",
        "diff-editor-gutter-delete",
        "diff-editor-original-line",
      )
      original_decorations.append(
        inline_decorations(
          presentation.original_inner_changed,
          "diff-editor-char-delete",
          "diff-editor-original-character",
        ),
      )
      self.original_decoration_ids = self.original_viewer.delta_decorations(
        [],
        original_decorations,
      )
      self.original_zone_ids = install_alignment_zones(
        self.original_viewer,
        presentation.original_spacers,
      )
      self.modified_zone_ids = install_alignment_zones(
        self.modified_viewer,
        presentation.modified_spacers,
      )
    }
    Unified =>
      self.modified_zone_ids = install_unified_deleted_zones(
        self.modified_viewer,
        diff_model.original,
        changes,
      )
  }
}

///|
fn DiffViewer::clear_diff_artifacts(self : DiffViewer) -> Unit {
  self.original_decoration_ids = self.original_viewer.delta_decorations(
    self.original_decoration_ids,
    [],
  )
  self.modified_decoration_ids = self.modified_viewer.delta_decorations(
    self.modified_decoration_ids,
    [],
  )
  remove_diff_zones(self.original_viewer, self.original_zone_ids)
  remove_diff_zones(self.modified_viewer, self.modified_zone_ids)
  self.original_zone_ids = []
  self.modified_zone_ids = []
}

///|
priv struct DiffSpacer {
  after_line_number : Int
  height_in_lines : Int
}

///|
priv struct DiffLineChange {
  original : @base_common.LineRange
  modified : @base_common.LineRange
  inner_changes : Array[(@base_common.Range, @base_common.Range)]?
}

///|
priv struct DiffPresentation {
  original_changed : Array[@base_common.LineRange]
  modified_changed : Array[@base_common.LineRange]
  original_inner_changed : Array[@base_common.Range]
  modified_inner_changed : Array[@base_common.Range]
  original_spacers : Array[DiffSpacer]
  modified_spacers : Array[DiffSpacer]
}

///|
/// Convert line mappings once into the four independent rendering inputs.
/// Unequal replacement ranges align from their starts and put the remaining
/// height after the shorter block; insertions/deletions therefore use the
/// preceding logical line (including Monaco's valid line-zero anchor).
fn diff_presentation(changes : Array[DiffLineChange]) -> DiffPresentation {
  let original_changed = []
  let modified_changed = []
  let original_inner_changed = []
  let modified_inner_changed = []
  let original_spacers = []
  let modified_spacers = []
  for change in changes {
    if !change.original.is_empty() {
      original_changed.push(change.original)
    }
    if !change.modified.is_empty() {
      modified_changed.push(change.modified)
    }
    match change.inner_changes {
      Some(inner_changes) =>
        for inner_change in inner_changes {
          let (original, modified) = inner_change
          if !original.is_empty() {
            original_inner_changed.push(original)
          }
          if !modified.is_empty() {
            modified_inner_changed.push(modified)
          }
        }
      None => ()
    }
    let original_length = change.original.length()
    let modified_length = change.modified.length()
    if original_length < modified_length {
      original_spacers.push({
        after_line_number: change.original.end_line_number_exclusive - 1,
        height_in_lines: modified_length - original_length,
      })
    } else if modified_length < original_length {
      modified_spacers.push({
        after_line_number: change.modified.end_line_number_exclusive - 1,
        height_in_lines: original_length - modified_length,
      })
    }
  }
  {
    original_changed,
    modified_changed,
    original_inner_changed,
    modified_inner_changed,
    original_spacers,
    modified_spacers,
  }
}

///|
fn line_decorations(
  model : @model.TextModel,
  ranges : Array[@base_common.LineRange],
  line_class : String,
  gutter_class : String,
  description : String,
) -> Array[@model.ModelDeltaDecoration] {
  // An empty document has one model line for cursor geometry, but it is not a
  // deleted/inserted source line. Its physical line still contributes to
  // spacer height, so only the decoration is suppressed.
  if model.get_value().is_empty() {
    return []
  }
  let decorations : Array[@model.ModelDeltaDecoration] = []
  for range in ranges {
    guard !range.is_empty() else { continue }
    let end_line = range.end_line_number_exclusive - 1
    decorations.push({
      range: Range(
        range.start_line_number,
        1,
        end_line,
        model.get_line_max_column(end_line),
      ),
      options: ModelDecorationOptions(
        line_class,
        is_whole_line=true,
        lines_decorations_class_name=gutter_class,
        description~,
      ),
    })
  }
  decorations
}

///|
fn inline_decorations(
  ranges : Array[@base_common.Range],
  inline_class : String,
  description : String,
) -> Array[@model.ModelDeltaDecoration] {
  ranges.map(range => {
    range,
    options: ModelDecorationOptions(
      "",
      inline_class_name=inline_class,
      description~,
    ),
  })
}

///|
fn install_alignment_zones(
  viewer : Viewer,
  spacers : Array[DiffSpacer],
) -> Array[String] {
  let ids : Array[String] = []
  if spacers.is_empty() {
    return ids
  }
  viewer.change_view_zones(accessor => {
    for spacer in spacers {
      let dom_node = @rdom.document().create_element("div")
      dom_node.set_attribute("class", "diff-editor-alignment-zone")
      ids.push(
        accessor.add_zone(
          view_zone(
            spacer.after_line_number,
            dom_node,
            suppress_mouse_down=true,
            height_in_lines=spacer.height_in_lines.to_double(),
          ),
        ),
      )
    }
  })
  ids
}

///|
priv struct DiffInlineInterval {
  start_offset : Int
  end_offset : Int
}

///|
fn deleted_inline_intervals_for_line(
  ranges : Array[@base_common.Range],
  line_number : Int,
  line_length : Int,
) -> Array[DiffInlineInterval] {
  let intervals = []
  for range in ranges {
    if line_number < range.start_line_number ||
      line_number > range.end_line_number {
      continue
    }
    let start_offset = (if line_number == range.start_line_number {
        range.start_column - 1
      } else {
        0
      })
      .max(0)
      .min(line_length)
    let end_offset = (if line_number == range.end_line_number {
        range.end_column - 1
      } else {
        line_length
      })
      .max(0)
      .min(line_length)
    if start_offset < end_offset {
      intervals.push({ start_offset, end_offset })
    }
  }
  intervals
}

///|
fn append_deleted_line_tokens(
  row : @rdom.Element,
  model : @model.TextModel,
  line_number : Int,
  inner_ranges : Array[@base_common.Range],
) -> Unit {
  let document = @rdom.document()
  let text = model.get_line_content(line_number)
  if text.is_empty() {
    row.set_attribute("data-empty-line", "true")
    return
  }
  let intervals = deleted_inline_intervals_for_line(
    inner_ranges,
    line_number,
    text.length(),
  )
  let tokens = model.tokenization.get_line_tokens(line_number).inflate()
  let token_count = tokens.get_count()
  let mut token_index = 0
  let mut offset = 0
  while offset < text.length() {
    while token_index + 1 < token_count &&
          tokens.get_end_offset(token_index) <= offset {
      token_index += 1
    }
    let mut next_offset = if token_count > 0 &&
      tokens.get_end_offset(token_index) > offset {
      tokens.get_end_offset(token_index).min(text.length())
    } else {
      text.length()
    }
    let mut changed = false
    for interval in intervals {
      if interval.start_offset <= offset && offset < interval.end_offset {
        changed = true
      }
      if interval.start_offset > offset {
        next_offset = next_offset.min(interval.start_offset)
      }
      if interval.end_offset > offset {
        next_offset = next_offset.min(interval.end_offset)
      }
    }
    let span = document.create_element("span")
    let token_class = if token_count > 0 {
      tokens.get_class_name(token_index)
    } else {
      "mtk1"
    }
    span.set_attribute(
      "class",
      if changed {
        token_class + " diff-editor-char-delete"
      } else {
        token_class
      },
    )
    span.append_child(
      document
      .create_text_node(text.unsafe_substring(start=offset, end=next_offset))
      .as_node(),
    )
    row.append_child(span.as_node())
    offset = next_offset
  }
}

///|
fn original_inner_ranges(change : DiffLineChange) -> Array[@base_common.Range] {
  let ranges = []
  match change.inner_changes {
    Some(inner_changes) =>
      for inner_change in inner_changes {
        let (original, _modified) = inner_change
        if !original.is_empty() {
          ranges.push(original)
        }
      }
    None => ()
  }
  ranges
}

///|
fn unified_deleted_zone_anchor(change : DiffLineChange) -> Int {
  change.modified.start_line_number - 1
}

///|
fn deleted_block_min_width(
  model : @model.TextModel,
  range : @base_common.LineRange,
  font_size : Double,
) -> Double {
  let mut longest = 0
  for line_number in range.start_line_number..<range.end_line_number_exclusive {
    longest = longest.max(model.get_line_content(line_number).length())
  }
  (longest.to_double() * font_size * 0.62 + 24.0).min(1000000.0)
}

///|
fn install_unified_deleted_zones(
  viewer : Viewer,
  original_model : @model.TextModel,
  changes : Array[DiffLineChange],
) -> Array[String] {
  let ids : Array[String] = []
  let options = viewer.get_options()
  viewer.change_view_zones(accessor => {
    for ordinal, change in changes {
      guard !change.original.is_empty() else { continue }
      let document = @rdom.document()
      let content = document.create_element("div")
      content.set_attribute("class", "diff-editor-unified-deleted-block")
      content.set_attribute("role", "group")
      content.set_attribute(
        "aria-label",
        "Deleted lines \{change.original.start_line_number} through \{change.original.end_line_number_exclusive - 1}",
      )
      content.set_attribute(
        "data-original-start-line",
        change.original.start_line_number.to_string(),
      )
      content.set_attribute(
        "data-original-end-line",
        (change.original.end_line_number_exclusive - 1).to_string(),
      )
      @base_browser.set_style_property(
        content,
        "tab-size",
        options.tab_size.to_string(),
      )
      let margin = document.create_element("div")
      margin.set_attribute("class", "diff-editor-unified-deleted-margin")
      let inner_ranges = original_inner_ranges(change)
      for
        line_number in change.original.start_line_number..<change.original.end_line_number_exclusive {
        let row = document.create_element("div")
        row.set_attribute("class", "diff-editor-unified-deleted-line")
        row.set_attribute("data-original-line", line_number.to_string())
        append_deleted_line_tokens(
          row, original_model, line_number, inner_ranges,
        )
        content.append_child(row.as_node())

        let line_number_node = document.create_element("div")
        line_number_node.set_attribute(
          "class", "diff-editor-unified-deleted-line-number",
        )
        line_number_node.append_child(
          document.create_text_node(line_number.to_string()).as_node(),
        )
        margin.append_child(line_number_node.as_node())
      }
      ids.push(
        accessor.add_zone(
          view_zone(
            unified_deleted_zone_anchor(change),
            content,
            ordinal~,
            suppress_mouse_down=false,
            height_in_lines=change.original.length().to_double(),
            min_width_in_px=deleted_block_min_width(
              original_model,
              change.original,
              options.font_size,
            ),
            margin_dom_node=margin,
          ),
        ),
      )
      // ViewZones defaults caller content to presentation-only. Deleted source
      // is meaningful comparison text, so expose this non-interactive block.
      content.remove_attribute("aria-hidden")
    }
  })
  ids
}

///|
fn remove_diff_zones(viewer : Viewer, ids : Array[String]) -> Unit {
  if ids.is_empty() {
    return
  }
  viewer.change_view_zones(accessor => {
    for id in ids {
      accessor.remove_zone(id)
    }
  })
}
