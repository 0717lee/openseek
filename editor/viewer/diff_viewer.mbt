// The first production slice of Monaco's standalone diff editor: two normal
// Viewer instances coordinated by line-level diff state. The child Viewers
// deliberately remain ordinary editors so every model-scoped contribution
// (tokenization, hover, Definition/Peek, selection, feedback) follows the
// existing Viewer path. This owner adds only comparison state: whole-line
// decorations, alignment ViewZones, and vertical/horizontal scroll
// synchronization.
//
// Phase-one exclusions are explicit: no character-level inner changes, moved
// blocks, inline mode, revert actions, unchanged-region collapsing, or
// overview ruler. Soft wrapping and folding are disabled in the child panes
// because fixed-height logical lines are the invariant behind the current
// ViewZone alignment algorithm.

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
/// A side-by-side diff surface composed from two ordinary Viewer instances.
/// The caller owns `host` and must keep it stable and otherwise child-free.
struct DiffViewer {
  host : @rdom.Element
  root : @rdom.Element
  original_viewer : Viewer
  modified_viewer : Viewer
  owned_services : ViewerServices?
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
/// inert by giving that model a URI outside their live-document selectors.
pub fn DiffViewer::create(
  host : @rdom.Element,
  services? : ViewerServices,
  options? : ViewerOptions = ViewerOptions::default(),
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
    original_viewer,
    modified_viewer,
    owned_services,
    scroll_disposables: [],
    model_disposables: [],
    original_decoration_ids: [],
    modified_decoration_ids: [],
    original_zone_ids: [],
    modified_zone_ids: [],
    disposed: false,
  }
  diff_viewer.scroll_disposables.push(
    original_viewer.on_did_scroll_change(event => {
      if event.scroll_top_changed {
        diff_viewer.sync_scroll_top_to(modified_viewer, event.scroll_top)
      }
      if event.scroll_left_changed {
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
  })
  let presentation = diff_presentation(changes)
  self.original_decoration_ids = self.original_viewer.delta_decorations(
    [],
    line_decorations(
      diff_model.original,
      presentation.original_changed,
      "diff-editor-line-delete",
      "diff-editor-gutter-delete",
      "diff-editor-original-line",
    ),
  )
  self.modified_decoration_ids = self.modified_viewer.delta_decorations(
    [],
    line_decorations(
      diff_model.modified,
      presentation.modified_changed,
      "diff-editor-line-insert",
      "diff-editor-gutter-insert",
      "diff-editor-modified-line",
    ),
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
  remove_alignment_zones(self.original_viewer, self.original_zone_ids)
  remove_alignment_zones(self.modified_viewer, self.modified_zone_ids)
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
}

///|
priv struct DiffPresentation {
  original_changed : Array[@base_common.LineRange]
  modified_changed : Array[@base_common.LineRange]
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
  let original_spacers = []
  let modified_spacers = []
  for change in changes {
    if !change.original.is_empty() {
      original_changed.push(change.original)
    }
    if !change.modified.is_empty() {
      modified_changed.push(change.modified)
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
  { original_changed, modified_changed, original_spacers, modified_spacers }
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
fn remove_alignment_zones(viewer : Viewer, ids : Array[String]) -> Unit {
  if ids.is_empty() {
    return
  }
  viewer.change_view_zones(accessor => {
    for id in ids {
      accessor.remove_zone(id)
    }
  })
}
