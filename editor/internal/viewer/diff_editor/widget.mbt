///|
/// A first-class diff widget that owns two code-editor kernels and one shared
/// diff ViewModel. Product-specific algorithm controls and document
/// presentation routing are intentionally outside this package.
pub struct DiffEditorWidget {
  host : @rdom.Element
  root : @rdom.Element
  panes : @rdom.Element
  original_host : @rdom.Element
  modified_host : @rdom.Element
  sash : @rdom.Element
  overview_root : @rdom.Element
  overview_viewport : @rdom.Element
  status : @rdom.Element
  live_region : @rdom.Element
  editors : DiffEditorEditors
  view_model : DiffEditorViewModel
  mut editor_options : @code_widget.CodeEditorOptions
  mut options : DiffEditorOptions
  layout_state : DiffEditorLayoutState
  pointer_monitor : @base_browser.GlobalPointerMoveMonitor
  lifetime : Array[@base_common.Disposable]
  mut resize_observer : @base_common.Disposable?
  mut original_overview_ruler : @code_widget.CodeEditorOverviewRuler?
  mut modified_overview_ruler : @code_widget.CodeEditorOverviewRuler?
  mut original_decoration_ids : Array[String]
  mut modified_decoration_ids : Array[String]
  mut original_alignment_zone_ids : Array[String]
  mut modified_alignment_zone_ids : Array[String]
  mut inline_deleted_zones : Array[InlineDeletedZone]
  mut original_alignment_geometry : PaneGeometrySnapshot?
  mut modified_alignment_geometry : PaneGeometrySnapshot?
  mut diff_state : DiffState?
  mut reconciling_generation : Int
  mut is_reconciling : Bool
  /// Cancellable paint barrier for the latest outer layout transaction.
  /// Side-by-side waits for both kernels; Inline waits only for its visible
  /// modified kernel and never measures the hidden original.
  layout_render_waiters : Array[@base_common.Disposable]
  mut layout_render_generation : Int
  mut layout_render_remaining : Int
  mut has_valid_layout_box : Bool
  mut is_syncing_scroll : Bool
  /// Internal, component-local lifecycle trace. It is exposed only through
  /// the internal package diagnostic snapshot and never through a public
  /// editor facade.
  mut dispose_pass_count : Int
  mut resize_observer_disposed : Bool
  mut overview_ruler_disposed : Bool
  mut disposed : Bool
}

///|
fn diff_whole_line_decorations(
  ranges : Array[@base_common.Range],
  line_class : String,
  gutter_class : String,
  description : String,
) -> Array[@model.ModelDeltaDecoration] {
  ranges.map(range => {
    range,
    options: ModelDecorationOptions(
      line_class,
      is_whole_line=true,
      lines_decorations_class_name=gutter_class,
      description~,
    ),
  })
}

///|
pub fn DiffEditorWidget::create(
  host : @rdom.Element,
  services? : @code_widget.CodeEditorServices,
  editor_options? : @code_widget.CodeEditorOptions = @code_widget.CodeEditorOptions::default(),
  options? : DiffEditorOptions = DiffEditorOptions::default(),
  provider : &@diff.DocumentDiffProvider,
) -> DiffEditorWidget {
  let document = @rdom.document()
  let root = document.create_element("section")
  root.set_attribute("class", "moonbit-diff-editor")
  root.set_attribute("role", "region")
  root.set_attribute("aria-label", "File comparison")
  let panes = document.create_element("div")
  panes.set_attribute("class", "moonbit-diff-editor-panes")
  let original_host = document.create_element("div")
  original_host.set_attribute(
    "class", "moonbit-diff-editor-pane moonbit-diff-editor-original",
  )
  original_host.set_attribute("role", "group")
  original_host.set_attribute("aria-label", "Original file")
  let sash = document.create_element("div")
  sash.set_attribute("class", "moonbit-diff-editor-sash")
  sash.set_attribute("role", "separator")
  sash.set_attribute("aria-label", "Resize diff panes")
  sash.set_attribute("aria-orientation", "vertical")
  sash.set_attribute("aria-valuemin", "10")
  sash.set_attribute("aria-valuemax", "90")
  sash.set_attribute("tabindex", "0")
  let modified_host = document.create_element("div")
  modified_host.set_attribute(
    "class", "moonbit-diff-editor-pane moonbit-diff-editor-modified",
  )
  modified_host.set_attribute("role", "group")
  modified_host.set_attribute("aria-label", "Modified file")
  panes.append_child(original_host.as_node())
  panes.append_child(sash.as_node())
  panes.append_child(modified_host.as_node())
  let overview_root = document.create_element("div")
  overview_root.set_attribute("class", "moonbit-diff-overview diffOverview")
  overview_root.set_attribute("aria-hidden", "true")
  overview_root.set_attribute("hidden", "")
  let overview_viewport = document.create_element("div")
  overview_viewport.set_attribute(
    "class", "moonbit-diff-overview-viewport diffViewport",
  )
  overview_root.append_child(overview_viewport.as_node())
  let status = document.create_element("div")
  status.set_attribute("class", "moonbit-diff-editor-status")
  status.set_attribute("hidden", "")
  let live_region = document.create_element("div")
  live_region.set_attribute("class", "moonbit-diff-editor-live-region")
  live_region.set_attribute("aria-live", "polite")
  live_region.set_attribute("aria-atomic", "true")
  root.append_child(panes.as_node())
  root.append_child(overview_root.as_node())
  root.append_child(status.as_node())
  root.append_child(live_region.as_node())
  host.append_child(root.as_node())

  let editors = DiffEditorEditors::create(
    original_host,
    modified_host,
    services?,
    editor_options,
    options.diff_word_wrap,
  )
  let view_model = DiffEditorViewModel(provider, options={
    ignore_trim_whitespace: options.ignore_trim_whitespace,
  })
  let widget : DiffEditorWidget = {
    host,
    root,
    panes,
    original_host,
    modified_host,
    sash,
    overview_root,
    overview_viewport,
    status,
    live_region,
    editors,
    view_model,
    editor_options,
    options,
    layout_state: DiffEditorLayoutState::new(options),
    pointer_monitor: GlobalPointerMoveMonitor(),
    lifetime: [],
    resize_observer: None,
    original_overview_ruler: None,
    modified_overview_ruler: None,
    original_decoration_ids: [],
    modified_decoration_ids: [],
    original_alignment_zone_ids: [],
    modified_alignment_zone_ids: [],
    inline_deleted_zones: [],
    original_alignment_geometry: None,
    modified_alignment_geometry: None,
    diff_state: None,
    reconciling_generation: 0,
    is_reconciling: false,
    layout_render_waiters: [],
    layout_render_generation: 0,
    layout_render_remaining: 0,
    has_valid_layout_box: false,
    is_syncing_scroll: false,
    dispose_pass_count: 0,
    resize_observer_disposed: false,
    overview_ruler_disposed: false,
    disposed: false,
  }
  widget.install_event_bridges()
  // Establish accessibility/visibility attributes even when the initial host
  // is display:none and therefore has no valid layout transaction yet.
  widget.apply_layout_dom()
  widget.sync_overview_ruler_option()
  widget.resize_observer = @base_browser.observe_element_resize(host, () => {
    widget.layout()
  })
  widget.layout()
  widget
}

///|
fn DiffEditorWidget::listen(
  self : DiffEditorWidget,
  target : @rdom.EventTarget,
  event_name : String,
  listener : (@rdom.Event) -> Unit,
) -> Unit {
  target.add_event_listener(event_name, listener)
  self.lifetime.push(
    @base_common.Disposable::from(() => {
      target.remove_event_listener(event_name, listener)
    }),
  )
}

///|
fn DiffEditorWidget::host_has_positive_layout_box(
  self : DiffEditorWidget,
) -> Bool {
  let rect = self.host.get_bounding_client_rect()
  rect.get_width() > 0.0 && rect.get_height() > 0.0
}

///|
fn DiffEditorWidget::cancel_layout_render_barrier(
  self : DiffEditorWidget,
) -> Unit {
  for waiter in self.layout_render_waiters {
    waiter.dispose()
  }
  self.layout_render_waiters.clear()
  self.layout_render_remaining = 0
}

///|
fn DiffEditorWidget::complete_layout_pane_render(
  self : DiffEditorWidget,
  generation : Int,
) -> Unit {
  if self.disposed ||
    generation != self.layout_render_generation ||
    self.layout_render_remaining <= 0 {
    return
  }
  self.layout_render_remaining -= 1
  if self.layout_render_remaining > 0 {
    return
  }
  self.cancel_layout_render_barrier()
  if !self.host_has_positive_layout_box() {
    self.has_valid_layout_box = false
    return
  }
  self.has_valid_layout_box = true
  // Every outer layout, including height-only resizes, gets exactly one
  // reconcile using geometry from the completed pane render(s).
  self.reconcile_view_model(geometry_refresh=true)
  self.refresh_overview_viewport()
}

///|
fn DiffEditorWidget::layout_editors_after_render(
  self : DiffEditorWidget,
) -> Unit {
  self.cancel_layout_render_barrier()
  if !self.has_valid_layout_box || !self.host_has_positive_layout_box() {
    self.has_valid_layout_box = false
    return
  }
  self.layout_render_generation += 1
  let generation = self.layout_render_generation
  self.layout_render_remaining = if self.layout_state.actual_layout ==
    SideBySide {
    2
  } else {
    1
  }
  if self.layout_state.actual_layout == SideBySide {
    self.layout_render_waiters.push(
      self.editors.original.after_next_render(() => {
        self.complete_layout_pane_render(generation)
      }),
    )
  }
  self.layout_render_waiters.push(
    self.editors.modified.after_next_render(() => {
      self.complete_layout_pane_render(generation)
    }),
  )
  self.editors.layout(self.layout_state.actual_layout)
}

///|
fn DiffEditorWidget::install_event_bridges(self : DiffEditorWidget) -> Unit {
  self.lifetime.push(
    self.view_model.on_did_change_model(() => {
      self.editors.set_model(self.view_model.get_model())
    }),
  )
  self.lifetime.push(
    self.view_model.on_did_update_diff(() => self.reconcile_view_model()),
  )
  self.lifetime.push(
    self.editors.original.on_did_scroll_change(event => {
      if self.layout_state.actual_layout == SideBySide &&
        event.scroll_top_changed {
        self.sync_scroll_top_to(self.editors.modified, event.scroll_top)
      }
      if self.layout_state.actual_layout == SideBySide &&
        event.scroll_left_changed {
        self.sync_scroll_left_to(self.editors.modified, event.scroll_left)
      }
    }),
  )
  self.lifetime.push(
    self.editors.modified.on_did_scroll_change(event => {
      self.refresh_overview_viewport()
      if self.layout_state.actual_layout == SideBySide &&
        event.scroll_top_changed {
        self.sync_scroll_top_to(self.editors.original, event.scroll_top)
      }
      if self.layout_state.actual_layout == SideBySide &&
        event.scroll_left_changed {
        self.sync_scroll_left_to(self.editors.original, event.scroll_left)
      }
    }),
  )
  self.lifetime.push(
    self.editors.original.on_did_change_view_zones(() => {
      self.reconcile_geometry_if_changed()
    }),
  )
  self.lifetime.push(
    self.editors.modified.on_did_change_view_zones(() => {
      self.reconcile_geometry_if_changed()
    }),
  )
  self.lifetime.push(
    self.editors.original.on_did_change_hidden_areas(() => {
      self.reconcile_geometry_if_changed()
    }),
  )
  self.lifetime.push(
    self.editors.modified.on_did_change_hidden_areas(() => {
      self.reconcile_geometry_if_changed()
    }),
  )
  self.listen(self.root.as_event_target(), "keydown", event => {
    guard event.to_keyboard_event() is Some(keyboard) else { return }
    if keyboard.key() == "F7" {
      event.prevent_default()
      event.stop_propagation()
      if keyboard.shift_key() {
        self.reveal_previous_change() |> ignore
      } else {
        self.reveal_next_change() |> ignore
      }
    }
  })
  self.listen(self.overview_root.as_event_target(), "pointerdown", event => {
    if self.options.overview_ruler {
      self.editors.modified.delegate_vertical_scrollbar_pointer_down(event)
    }
  })
  self.listen(self.overview_root.as_event_target(), "wheel", event => {
    if self.options.overview_ruler {
      self.editors.modified.delegate_scroll_from_mouse_wheel_event(event)
      |> ignore
    }
  })
  self.listen(self.sash.as_event_target(), "pointerdown", event => {
    guard event.to_mouse_event() is Some(mouse) && mouse.get_button() == 0 else {
      return
    }
    if !self.options.sash_enabled ||
      self.layout_state.actual_layout != SideBySide {
      return
    }
    event.prevent_default()
    event.stop_propagation()
    let root_left = self.panes.get_bounding_client_rect().get_left()
    self.pointer_monitor.start_monitoring(
      self.sash,
      @base_browser.mouse_event_pointer_id(mouse),
      mouse.get_buttons(),
      pointer_event => {
        if self.layout_state.set_split_from_pointer(
            Double::from_int(pointer_event.get_client_x()) - root_left,
          ) {
          self.apply_layout_dom()
          self.layout_editors_after_render()
        }
      },
      _ => (),
    )
  })
  self.listen(self.sash.as_event_target(), "keydown", event => {
    guard event.to_keyboard_event() is Some(keyboard) else { return }
    let direction = match keyboard.key() {
      "ArrowLeft" => -1.0
      "ArrowRight" => 1.0
      _ => return
    }
    if !self.options.sash_enabled ||
      self.layout_state.actual_layout != SideBySide {
      return
    }
    event.prevent_default()
    event.stop_propagation()
    let next_offset = self.layout_state.width *
      (self.layout_state.split_ratio + direction * 0.02)
    if self.layout_state.set_split_from_pointer(next_offset) {
      self.apply_layout_dom()
      self.layout_editors_after_render()
    }
  })
}

///|
fn DiffEditorWidget::sync_scroll_top_to(
  self : DiffEditorWidget,
  target : @code_widget.CodeEditorWidget,
  scroll_top : Double,
) -> Unit {
  if self.disposed ||
    self.is_syncing_scroll ||
    (target.get_scroll_top() - scroll_top).abs() <= 0.5 {
    return
  }
  self.is_syncing_scroll = true
  target.set_scroll_top(scroll_top)
  self.is_syncing_scroll = false
}

///|
fn DiffEditorWidget::sync_scroll_left_to(
  self : DiffEditorWidget,
  target : @code_widget.CodeEditorWidget,
  scroll_left : Double,
) -> Unit {
  if self.disposed ||
    self.is_syncing_scroll ||
    (target.get_scroll_left() - scroll_left).abs() <= 0.5 {
    return
  }
  self.is_syncing_scroll = true
  target.set_scroll_left(scroll_left)
  self.is_syncing_scroll = false
}

///|
fn DiffEditorWidget::clear_decorations(self : DiffEditorWidget) -> Unit {
  self.original_decoration_ids = self.editors.original.delta_decorations(
    self.original_decoration_ids,
    [],
  )
  self.modified_decoration_ids = self.editors.modified.delta_decorations(
    self.modified_decoration_ids,
    [],
  )
}

///|
fn changed_line_range(
  line_range : @base_common.LineRange,
  snapshot : @model.TextSnapshot,
) -> @base_common.Range? {
  if line_range.is_empty() {
    return None
  }
  let end_line_number = line_range.end_line_number_exclusive - 1
  Some(
    Range(
      line_range.start_line_number,
      1,
      end_line_number,
      snapshot.get_line_max_column(end_line_number),
    ),
  )
}

///|
fn whole_line_character_decoration(
  range : @base_common.Range,
  class_name : String,
  description : String,
) -> @model.ModelDeltaDecoration {
  {
    range,
    options: ModelDecorationOptions(
      class_name,
      is_whole_line=true,
      description~,
    ),
  }
}

///|
fn inner_character_decoration(
  range : @base_common.Range,
  class_name : String,
  description : String,
) -> @model.ModelDeltaDecoration {
  let is_empty = range.is_empty()
  {
    range,
    options: ModelDecorationOptions(
      if is_empty {
        class_name + " diff-range-empty"
      } else {
        class_name
      },
      should_fill_line_on_line_break=!is_empty,
      description~,
    ),
  }
}

///|
// Direct port of the non-move branches in DiffEditorDecorations. The renderer
// iterates DiffState mappings themselves; no second feature-projection model
// can reorder or reinterpret a change.
fn DiffEditorWidget::apply_diff_state_decorations(
  self : DiffEditorWidget,
  diff_state : DiffState,
  model : DiffEditorModelData,
) -> Unit {
  let original_snapshot = model.original.snapshot()
  let modified_snapshot = model.modified.snapshot()
  let original_decorations : Array[@model.ModelDeltaDecoration] = []
  let modified_decorations : Array[@model.ModelDeltaDecoration] = []
  for mapping in diff_state.mappings {
    let change = mapping.line_range_mapping
    let original_range = changed_line_range(change.original, original_snapshot)
    let modified_range = changed_line_range(change.modified, modified_snapshot)
    match original_range {
      Some(range) =>
        original_decorations.append(
          diff_whole_line_decorations(
            [range],
            "diff-editor-line-delete",
            "diff-editor-gutter-delete",
            "diff-editor-original-line",
          ),
        )
      None => ()
    }
    match modified_range {
      Some(range) =>
        modified_decorations.append(
          diff_whole_line_decorations(
            [range],
            "diff-editor-line-insert",
            "diff-editor-gutter-insert",
            "diff-editor-modified-line",
          ),
        )
      None => ()
    }
    if change.modified.is_empty() || change.original.is_empty() {
      match original_range {
        Some(range) =>
          original_decorations.push(
            whole_line_character_decoration(
              range, "diff-editor-char-delete", "diff-editor-original-character",
            ),
          )
        None => ()
      }
      match modified_range {
        Some(range) =>
          modified_decorations.push(
            whole_line_character_decoration(
              range, "diff-editor-char-insert", "diff-editor-modified-character",
            ),
          )
        None => ()
      }
    } else {
      match change.inner_changes {
        Some(inner_changes) =>
          for inner in inner_changes {
            if change.original.contains(inner.original.start_line_number) {
              original_decorations.push(
                inner_character_decoration(
                  inner.original,
                  "diff-editor-char-delete",
                  "diff-editor-original-character",
                ),
              )
            }
            if change.modified.contains(inner.modified.start_line_number) {
              modified_decorations.push(
                inner_character_decoration(
                  inner.modified,
                  "diff-editor-char-insert",
                  "diff-editor-modified-character",
                ),
              )
            }
          }
        None => ()
      }
    }
  }
  self.original_decoration_ids = self.editors.original.delta_decorations(
    self.original_decoration_ids,
    original_decorations,
  )
  self.modified_decoration_ids = self.editors.modified.delta_decorations(
    self.modified_decoration_ids,
    modified_decorations,
  )
}

///|
fn alignment_view_zone_specs(
  spacers : Array[ManagedAlignmentSpacer],
  pane_class : String,
) -> Array[@code_widget.ManagedCodeEditorViewZoneSpec] {
  spacers.map(spacer => {
    let node = @rdom.document().create_element("div")
    node.set_attribute(
      "class",
      "moonbit-diff-editor-alignment-spacer \{pane_class}",
    )
    node.set_attribute("aria-hidden", "true")
    ManagedCodeEditorViewZoneSpec(
      spacer.after_line_number,
      spacer.height_in_px,
      node,
    )
  })
}

///|
fn replace_alignment_zones(
  editor : @code_widget.CodeEditorWidget,
  previous_ids : Array[String],
  specs : Array[@code_widget.ManagedCodeEditorViewZoneSpec],
  generation : Int,
) -> Array[String] {
  if previous_ids.is_empty() && specs.is_empty() {
    []
  } else {
    editor.apply_managed_view_zones(previous_ids, specs, generation)
  }
}

///|
fn DiffEditorWidget::capture_alignment_geometry(
  self : DiffEditorWidget,
) -> (PaneGeometrySnapshot?, PaneGeometrySnapshot?) {
  (
    self.editors.original
    .geometry_snapshot(self.original_alignment_zone_ids)
    .map(pane_geometry_from_code_editor),
    self.editors.modified
    .geometry_snapshot(self.modified_alignment_zone_ids)
    .map(pane_geometry_from_code_editor),
  )
}

///|
fn DiffEditorWidget::restore_stable_viewports(
  self : DiffEditorWidget,
  original : @code_widget.StableCodeEditorViewportState?,
  modified : @code_widget.StableCodeEditorViewportState?,
  inline_modified : @code_widget.CodeEditorViewState?,
) -> Unit {
  match original {
    Some(state) =>
      self.editors.original.restore_stable_viewport_state(state) |> ignore
    None => ()
  }
  match modified {
    Some(state) =>
      self.editors.modified.restore_stable_viewport_state(state) |> ignore
    None => ()
  }
  match inline_modified {
    Some(state) => self.editors.modified.restore_view_state(Some(state))
    None => ()
  }
}

///|
fn DiffEditorWidget::clear_overview_ruler(
  self : DiffEditorWidget,
  generation : Int,
) -> Unit {
  match self.original_overview_ruler {
    Some(ruler) => ruler.clear(generation)
    None => ()
  }
  match self.modified_overview_ruler {
    Some(ruler) => ruler.clear(generation)
    None => ()
  }
}

///|
fn DiffEditorWidget::apply_overview_diff_state(
  self : DiffEditorWidget,
  diff_state : DiffState,
  generation : Int,
) -> Unit {
  match self.original_overview_ruler {
    Some(ruler) =>
      ruler.set_entries(
        generation,
        original_diff_overview_ruler_entries(diff_state),
      )
    None => ()
  }
  match self.modified_overview_ruler {
    Some(ruler) =>
      ruler.set_entries(
        generation,
        modified_diff_overview_ruler_entries(diff_state),
      )
    None => ()
  }
}

///|
fn DiffEditorWidget::refresh_overview_viewport(self : DiffEditorWidget) -> Unit {
  if self.disposed || !self.options.overview_ruler {
    return
  }
  let viewport_height = self.overview_root
    .get_bounding_client_rect()
    .get_height()
    .max(0.0)
  let layout_info = self.editors.modified.get_layout_info()
  let geometry = diff_overview_viewport_geometry(
    viewport_height,
    self.editors.modified.get_scroll_height().max(viewport_height),
    self.editors.modified.get_scroll_top().max(0.0),
    layout_info.vertical_scrollbar_width,
  )
  @base_browser.set_style_property(
    self.overview_viewport,
    "top",
    "\{geometry.top}px",
  )
  @base_browser.set_style_property(
    self.overview_viewport,
    "height",
    "\{geometry.height}px",
  )
  self.overview_viewport.set_attribute(
    "data-diff-viewport-top",
    geometry.top.to_string(),
  )
  self.overview_viewport.set_attribute(
    "data-diff-viewport-height",
    geometry.height.to_string(),
  )
}

///|
fn DiffEditorWidget::sync_overview_ruler_option(
  self : DiffEditorWidget,
) -> Unit {
  if !self.options.overview_ruler {
    self.root.remove_attribute("data-overview-ruler")
    self.overview_root.set_attribute("hidden", "")
    match self.original_overview_ruler {
      Some(ruler) => {
        ruler.dispose()
        self.overview_ruler_disposed = ruler.is_disposed()
      }
      None => ()
    }
    match self.modified_overview_ruler {
      Some(ruler) => {
        ruler.dispose()
        self.overview_ruler_disposed = self.overview_ruler_disposed &&
          ruler.is_disposed()
      }
      None => ()
    }
    self.original_overview_ruler = None
    self.modified_overview_ruler = None
    return
  }
  self.root.set_attribute("data-overview-ruler", "true")
  self.overview_root.remove_attribute("hidden")
  if self.original_overview_ruler is None {
    let ruler = self.editors.original.create_overview_ruler(
      external_host=self.overview_root,
    )
    ruler
    .get_dom_node()
    .set_attribute(
      "class", "decorationsOverviewRuler moonbit-code-overview-ruler original diffOverviewRuler",
    )
    ruler.get_dom_node().set_attribute("data-diff-overview-side", "original")
    self.original_overview_ruler = Some(ruler)
  }
  if self.modified_overview_ruler is None {
    let ruler = self.editors.modified.create_overview_ruler(
      external_host=self.overview_root,
    )
    ruler
    .get_dom_node()
    .set_attribute(
      "class", "decorationsOverviewRuler moonbit-code-overview-ruler modified diffOverviewRuler",
    )
    ruler.get_dom_node().set_attribute("data-diff-overview-side", "modified")
    self.modified_overview_ruler = Some(ruler)
  }
  self.overview_ruler_disposed = false
  match self.diff_state {
    Some(diff_state) =>
      self.apply_overview_diff_state(diff_state, self.reconciling_generation)
    _ => self.clear_overview_ruler(self.reconciling_generation)
  }
  self.refresh_overview_viewport()
}

///|
fn DiffEditorWidget::sync_failure_diagnostic(self : DiffEditorWidget) -> Unit {
  match self.view_model.get_failure_diagnostic() {
    Some(diagnostic) => {
      let message = if diagnostic == "provider error" {
        "Unable to compute this diff."
      } else {
        "The diff provider returned an invalid result."
      }
      self.root.set_attribute("data-diff-failure", diagnostic)
      self.status.remove_attribute("hidden")
      self.status.set_inner_html(message)
      self.live_region.set_inner_html(message)
    }
    None => {
      self.root.remove_attribute("data-diff-failure")
      self.status.set_attribute("hidden", "")
      self.status.set_inner_html("")
      self.live_region.set_inner_html("")
    }
  }
}

///|
let diff_unchanged_hidden_area_source : String = "diff-editor-unchanged"

///|
fn hidden_area_ranges(
  regions : Array[@diff.LineRangeMapping],
  original : Bool,
) -> Array[@base_common.Range] {
  regions.map(region => {
    let lines = if original { region.original } else { region.modified }
    Range(lines.start_line_number, 1, lines.end_line_number_exclusive - 1, 1)
  })
}

///|
fn DiffEditorWidget::apply_hidden_unchanged_regions(
  self : DiffEditorWidget,
  diff_state : DiffState?,
  model : DiffEditorModelData?,
) -> Unit {
  let regions = match (diff_state, model) {
    (Some(diff_state), Some(model)) if self.options.hide_unchanged_regions => {
      let changes = diff_state.mappings.map(mapping => {
        mapping.line_range_mapping
      })
      project_hidden_unchanged_regions(
        changes,
        model.original.get_line_count(),
        model.modified.get_line_count(),
        self.options.hide_unchanged_regions_minimum_line_count,
        self.options.hide_unchanged_regions_context_line_count,
      )
    }
    _ => []
  }
  self.editors.original.set_hidden_areas(
    hidden_area_ranges(regions, true),
    source=diff_unchanged_hidden_area_source,
  )
  self.editors.modified.set_hidden_areas(
    hidden_area_ranges(regions, false),
    source=diff_unchanged_hidden_area_source,
  )
}

///|
fn DiffEditorWidget::commit_empty_diff_features(
  self : DiffEditorWidget,
  generation : Int,
) -> Unit {
  let original_viewport = self.editors.original.capture_stable_viewport_state()
  let modified_viewport = if self.layout_state.actual_layout == Inline {
    None
  } else {
    self.editors.modified.capture_stable_viewport_state()
  }
  let inline_modified_viewport = if self.layout_state.actual_layout == Inline {
    self.editors.modified.save_view_state()
  } else {
    None
  }
  self.apply_hidden_unchanged_regions(None, None)
  self.clear_decorations()
  self.original_alignment_zone_ids = replace_alignment_zones(
    self.editors.original,
    self.original_alignment_zone_ids,
    [],
    generation,
  )
  self.inline_deleted_zones.clear()
  self.modified_alignment_zone_ids = replace_alignment_zones(
    self.editors.modified,
    self.modified_alignment_zone_ids,
    [],
    generation,
  )
  self.restore_stable_viewports(
    original_viewport, modified_viewport, inline_modified_viewport,
  )
  self.clear_overview_ruler(generation)
  self.original_alignment_geometry = None
  self.modified_alignment_geometry = None
  self.diff_state = None
  self.sync_failure_diagnostic()
}

///|
fn DiffEditorWidget::commit_diff_state(
  self : DiffEditorWidget,
  diff_state : DiffState,
  model : DiffEditorModelData,
  generation : Int,
  preserve_inline_model_anchor? : Bool = false,
) -> Unit {
  let original_viewport = self.editors.original.capture_stable_viewport_state()
  let preserve_inline_model_anchor = preserve_inline_model_anchor &&
    self.layout_state.actual_layout == Inline
  let modified_viewport = if self.layout_state.actual_layout == Inline &&
    !preserve_inline_model_anchor {
    None
  } else {
    self.editors.modified.capture_stable_viewport_state()
  }
  let inline_modified_viewport = if self.layout_state.actual_layout == Inline &&
    !preserve_inline_model_anchor {
    self.editors.modified.save_view_state()
  } else {
    None
  }
  self.apply_hidden_unchanged_regions(Some(diff_state), Some(model))
  let (original_geometry, modified_geometry) = self.capture_alignment_geometry()
  let (original_specs, modified_specs, next_inline_deleted_zones) = match
    (self.layout_state.actual_layout, original_geometry, modified_geometry) {
    (SideBySide, Some(original_geometry), Some(modified_geometry)) => {
      let spacers = compute_managed_alignment_spacers(
        diff_state, original_geometry, modified_geometry,
      )
      (
        alignment_view_zone_specs(
          spacers.original(),
          "moonbit-diff-editor-original-alignment-spacer",
        ),
        alignment_view_zone_specs(
          spacers.modified(),
          "moonbit-diff-editor-modified-alignment-spacer",
        ),
        [],
      )
    }
    (Inline, _, _) => {
      let inline_zones = inline_deleted_view_zone_specs(
        self.editors.modified,
        model.original,
        diff_state,
      )
      ([], inline_zones.specs, inline_zones.zones)
    }
    _ => ([], [], [])
  }
  self.original_alignment_geometry = if self.layout_state.actual_layout ==
    SideBySide {
    original_geometry
  } else {
    None
  }
  self.modified_alignment_geometry = if self.layout_state.actual_layout ==
    SideBySide {
    modified_geometry
  } else {
    modified_geometry
  }
  self.apply_diff_state_decorations(diff_state, model)
  self.original_alignment_zone_ids = replace_alignment_zones(
    self.editors.original,
    self.original_alignment_zone_ids,
    original_specs,
    generation,
  )
  self.inline_deleted_zones.clear()
  self.modified_alignment_zone_ids = replace_alignment_zones(
    self.editors.modified,
    self.modified_alignment_zone_ids,
    modified_specs,
    generation,
  )
  self.inline_deleted_zones = next_inline_deleted_zones
  self.restore_stable_viewports(
    original_viewport, modified_viewport, inline_modified_viewport,
  )
  self.apply_overview_diff_state(diff_state, generation)
  self.diff_state = Some(diff_state)
  self.sync_failure_diagnostic()
  self.refresh_overview_viewport()
}

///|
fn DiffEditorWidget::reconcile_geometry_if_changed(
  self : DiffEditorWidget,
) -> Unit {
  if self.disposed ||
    self.editors.is_committing_model_pair() ||
    self.is_reconciling ||
    self.diff_state is None ||
    self.view_model.get_diff() is None {
    return
  }
  let (original, modified) = self.capture_alignment_geometry()
  let geometry_changed = match self.layout_state.actual_layout {
    SideBySide =>
      alignment_geometry_pair_changed(
        original,
        modified,
        self.original_alignment_geometry,
        self.modified_alignment_geometry,
      )
    Inline =>
      !same_optional_alignment_geometry(
        modified,
        self.modified_alignment_geometry,
      )
  }
  if !geometry_changed {
    return
  }
  self.reconcile_view_model(geometry_refresh=true)
}

///|
fn DiffEditorWidget::reconcile_view_model(
  self : DiffEditorWidget,
  geometry_refresh? : Bool = false,
) -> Unit {
  if self.disposed ||
    self.editors.is_committing_model_pair() ||
    self.is_reconciling {
    return
  }
  if self.layout_render_remaining > 0 {
    return
  }
  if !self.has_valid_layout_box || !self.host_has_positive_layout_box() {
    self.has_valid_layout_box = false
    return
  }
  let committed_model_generation = self.editors.committed_model_generation()
  if !self.editors.same_model(self.view_model.get_model()) {
    return
  }
  // Keep the pair commit as the outer boundary while constructing DiffState.
  if self.editors.is_committing_model_pair() ||
    self.editors.committed_model_generation() != committed_model_generation {
    return
  }
  self.is_reconciling = true
  defer {
    self.is_reconciling = false
  }
  self.reconciling_generation += 1
  let generation = self.reconciling_generation
  guard self.view_model.get_diff() is Some(document_diff) &&
    self.view_model.get_model() is Some(model) else {
    self.commit_empty_diff_features(generation)
    return
  }
  let diff_state = DiffState::from_diff_result(document_diff)
  self.commit_diff_state(
    diff_state,
    model,
    generation,
    preserve_inline_model_anchor=geometry_refresh &&
      !self.inline_deleted_zones.is_empty(),
  )
}

///|
fn DiffEditorWidget::clear_diff_features_for_transition(
  self : DiffEditorWidget,
) -> Unit {
  if self.editors.is_committing_model_pair() ||
    self.is_reconciling ||
    (
      self.diff_state is None &&
      self.original_decoration_ids.is_empty() &&
      self.modified_decoration_ids.is_empty() &&
      self.original_alignment_zone_ids.is_empty() &&
      self.modified_alignment_zone_ids.is_empty() &&
      self.inline_deleted_zones.is_empty()
    ) {
    return
  }
  self.is_reconciling = true
  defer {
    self.is_reconciling = false
  }
  self.reconciling_generation += 1
  self.commit_empty_diff_features(self.reconciling_generation)
}

///|
pub fn DiffEditorWidget::set_model(
  self : DiffEditorWidget,
  model : DiffEditorModelData?,
) -> DiffEditorModelData? {
  if self.disposed || same_model_pair(self.view_model.get_model(), model) {
    return None
  }
  self.clear_diff_features_for_transition()
  self.layout_editors_after_render()
  // DiffEditorViewModel is the sole pair/ownership authority. Its synchronous
  // model event mirrors the committed pair into both kernels before the diff
  // update event clears or rebuilds feature artifacts.
  let previous = self.view_model.set_model(model)
  // A model transaction clears a previous provider/validator failure
  // synchronously. Reconciliation can be held behind the render barrier, so
  // do not leave the old diagnostic painted until the next pane render.
  self.sync_failure_diagnostic()
  match model {
    Some(_) if !self.editors.is_committing_model_pair() => {
      self.editors.original.handle_initialized()
      self.editors.modified.handle_initialized()
    }
    _ => ()
  }
  previous
}

///|
pub fn DiffEditorWidget::get_model(
  self : DiffEditorWidget,
) -> DiffEditorModelData? {
  self.view_model.get_model()
}

///|
pub fn DiffEditorWidget::set_diff_provider(
  self : DiffEditorWidget,
  provider : &@diff.DocumentDiffProvider,
) -> Unit {
  self.view_model.set_provider(provider)
  self.sync_failure_diagnostic()
}

///|
pub fn DiffEditorWidget::update_options(
  self : DiffEditorWidget,
  editor_options : @code_widget.CodeEditorOptions,
  options : DiffEditorOptions,
) -> Unit {
  if self.disposed {
    return
  }
  self.editor_options = editor_options
  self.options = options
  self.sync_overview_ruler_option()
  let valid_layout_box = self.host_has_positive_layout_box()
  if !valid_layout_box {
    self.has_valid_layout_box = false
    self.cancel_layout_render_barrier()
  }
  let original_had_focus = self.editors.original.has_text_focus()
  let layout_changed_from_options = self.layout_state.update_options(
    options,
    recompute_layout=false,
  )
  let available_width = if options.overview_ruler {
    (self.host.get_bounding_client_rect().get_width() - 30.0).max(0.0)
  } else {
    self.host.get_bounding_client_rect().get_width().max(0.0)
  }
  let layout_changed = if valid_layout_box {
    self.layout_state.layout(available_width) || layout_changed_from_options
  } else {
    layout_changed_from_options
  }
  if valid_layout_box {
    self.has_valid_layout_box = true
    self.apply_layout_dom()
    if layout_changed &&
      self.layout_state.actual_layout == Inline &&
      original_had_focus {
      self.editors.modified.focus()
    }
    self.editors.update_options(
      editor_options,
      options.diff_word_wrap,
      self.layout_state.actual_layout,
    )
    self.layout_editors_after_render()
  }
  self.view_model.update_options({
    ignore_trim_whitespace: options.ignore_trim_whitespace,
  })
}

///|
pub fn DiffEditorWidget::get_layout(
  self : DiffEditorWidget,
) -> DiffEditorLayout {
  self.layout_state.actual_layout
}

///|
pub fn DiffEditorWidget::get_diff(
  self : DiffEditorWidget,
) -> @diff.DocumentDiff? {
  self.view_model.get_diff()
}

///|
pub fn DiffEditorWidget::is_diff_up_to_date(self : DiffEditorWidget) -> Bool {
  self.view_model.is_diff_up_to_date()
}

///|
pub fn DiffEditorWidget::on_did_update_diff(
  self : DiffEditorWidget,
  listener : () -> Unit,
) -> @base_common.Disposable {
  self.view_model.on_did_update_diff(() => {
    if !self.disposed &&
      !self.editors.is_committing_model_pair() &&
      self.editors.same_model(self.view_model.get_model()) {
      listener()
    }
  })
}

///|
priv enum DiffNavigationPane {
  ModifiedNavigationPane
}

///|
priv struct DiffNavigationRevealPlan {
  pane : DiffNavigationPane
  range : @base_common.Range
}

///|
fn navigation_reveal_range(
  range : @base_common.LineRange,
  line_count : Int,
) -> @base_common.Range {
  if range.is_empty() {
    // Empty sides are positions between physical lines. A code editor still
    // needs a valid model coordinate, so represent the position as a
    // collapsed range on the nearest modified/original line.
    let anchor = range.start_line_number.clamp(min=1, max=line_count.max(1))
    return Range(anchor, 1, anchor, 1)
  }
  // Match `LineRange.toExclusiveRange()`: the end line stays exclusive. The
  // reveal path validates the resulting EOF position against the model.
  Range(range.start_line_number, 1, range.end_line_number_exclusive, 1)
}

///|
fn diff_navigation_reveal_plan(
  _layout : DiffEditorLayout,
  change : @diff.DetailedLineRangeMapping,
  _original_line_count : Int,
  modified_line_count : Int,
) -> DiffNavigationRevealPlan? {
  if change.modified.is_empty() && change.original.is_empty() {
    return None
  }
  // F7 is bound through pinned `commands.ts` to the Accessible Diff Viewer.
  // This editor-return adaptation always stays in the modified pane, using a
  // valid collapsed modified coordinate for a deletion-only group.
  Some({
    pane: ModifiedNavigationPane,
    range: navigation_reveal_range(change.modified, modified_line_count),
  })
}

///|
fn navigation_range_announcement(
  side : String,
  empty_kind : String,
  range : @base_common.LineRange,
) -> String {
  if range.is_empty() {
    "\{side} \{empty_kind} anchor at line \{range.start_line_number}"
  } else {
    "\{side} lines \{range.start_line_number} through " +
    "\{range.end_line_number_exclusive - 1}"
  }
}

///|
fn diff_navigation_announcement(target : DiffNavigationTarget) -> String {
  let change = target.change
  "Change \{target.change_index + 1} of \{target.change_count}; " +
  navigation_range_announcement("original", "insertion", change.original) +
  "; " +
  navigation_range_announcement("modified", "deletion", change.modified)
}

///|
fn DiffEditorWidget::announce_navigation_target(
  self : DiffEditorWidget,
  target : DiffNavigationTarget,
) -> Unit {
  self.live_region.set_inner_html(diff_navigation_announcement(target))
}

///|
fn DiffEditorWidget::reveal_navigation_target(
  self : DiffEditorWidget,
  target : DiffNavigationTarget,
) -> Bool {
  let change = target.change
  guard self.view_model.get_model() is Some(model) else { return false }
  let modified_anchor = change.modified.start_line_number.clamp(
    min=1,
    max=model.modified.get_line_count().max(1),
  )
  self.editors.modified.set_position(
    Position(modified_anchor, 1),
    source="diffEditor.accessibleDiffViewer",
  )
  guard diff_navigation_reveal_plan(
      self.layout_state.actual_layout,
      change,
      model.original.get_line_count(),
      model.modified.get_line_count(),
    )
    is Some(plan) else {
    return false
  }
  match plan.pane {
    ModifiedNavigationPane =>
      self.editors.modified.reveal_range_in_center(plan.range)
  }
  self.announce_navigation_target(target)
  true
}

///|
pub fn DiffEditorWidget::reveal_next_change(self : DiffEditorWidget) -> Bool {
  guard self.view_model.get_model() is Some(model) else { return false }
  let current_line = self.editors.modified
    .get_position()
    .map_or(1, position => position.line_number)
  guard self.diff_state is Some(diff_state) &&
    diff_state.next_change_from_modified_line(
      current_line,
      model.modified.get_line_count(),
    )
    is Some(target) else {
    return false
  }
  self.reveal_navigation_target(target)
}

///|
pub fn DiffEditorWidget::reveal_previous_change(
  self : DiffEditorWidget,
) -> Bool {
  let current_line = self.editors.modified
    .get_position()
    .map_or(1, position => position.line_number)
  guard self.diff_state is Some(diff_state) &&
    diff_state.previous_change_from_modified_line(current_line) is Some(target) else {
    return false
  }
  self.reveal_navigation_target(target)
}

///|
fn DiffEditorWidget::apply_layout_dom(self : DiffEditorWidget) -> Unit {
  let ratio = self.layout_state.split_ratio
  self.sash.set_attribute("aria-valuenow", (ratio * 100.0).round().to_string())
  match self.layout_state.actual_layout {
    SideBySide => {
      self.root.set_attribute(
        "class", "moonbit-diff-editor moonbit-diff-editor-side-by-side",
      )
      self.root.set_attribute("data-render-mode", "side-by-side")
      self.original_host.remove_attribute("hidden")
      self.original_host.remove_attribute("aria-hidden")
      if self.options.sash_enabled {
        self.sash.remove_attribute("hidden")
        self.sash.remove_attribute("aria-hidden")
        self.sash.set_attribute("tabindex", "0")
      } else {
        self.sash.set_attribute("hidden", "")
        self.sash.set_attribute("aria-hidden", "true")
        self.sash.remove_attribute("tabindex")
      }
      self.modified_host.set_attribute("aria-label", "Modified file")
      self.original_host.set_attribute(
        "style",
        "flex-basis: \{ratio * 100.0}%;",
      )
      self.modified_host.set_attribute(
        "style",
        "flex-basis: \{(1.0 - ratio) * 100.0}%;",
      )
    }
    Inline => {
      self.root.set_attribute(
        "class", "moonbit-diff-editor moonbit-diff-editor-inline",
      )
      self.root.set_attribute("data-render-mode", "inline")
      self.original_host.set_attribute("hidden", "")
      self.original_host.set_attribute("aria-hidden", "true")
      self.sash.set_attribute("hidden", "")
      self.sash.set_attribute("aria-hidden", "true")
      self.sash.remove_attribute("tabindex")
      self.modified_host.set_attribute("aria-label", "Inline diff")
      self.original_host.remove_attribute("style")
      self.modified_host.remove_attribute("style")
    }
  }
}

///|
pub fn DiffEditorWidget::layout(self : DiffEditorWidget) -> Unit {
  if self.disposed {
    return
  }
  let rect = self.host.get_bounding_client_rect()
  let width = rect.get_width()
  let height = rect.get_height()
  if width <= 0.0 || height <= 0.0 {
    self.has_valid_layout_box = false
    self.cancel_layout_render_barrier()
    return
  }
  self.has_valid_layout_box = true
  let original_had_focus = self.editors.original.has_text_focus()
  let layout_width = if self.options.overview_ruler {
    (width - 30.0).max(0.0)
  } else {
    width
  }
  let layout_changed = self.layout_state.layout(layout_width)
  self.apply_layout_dom()
  if layout_changed &&
    self.layout_state.actual_layout == Inline &&
    original_had_focus {
    self.editors.modified.focus()
  }
  self.editors.update_options(
    self.editor_options,
    self.options.diff_word_wrap,
    self.layout_state.actual_layout,
  )
  self.layout_editors_after_render()
}

///|
pub fn DiffEditorWidget::focus(self : DiffEditorWidget) -> Unit {
  self.editors.focus()
}

///|
pub fn DiffEditorWidget::dispose(self : DiffEditorWidget) -> Unit {
  if self.disposed {
    return
  }
  self.dispose_pass_count += 1
  self.clear_diff_features_for_transition()
  self.disposed = true
  match self.resize_observer {
    Some(observer) => {
      observer.dispose()
      self.resize_observer_disposed = true
    }
    None => ()
  }
  self.resize_observer = None
  self.pointer_monitor.dispose()
  self.cancel_layout_render_barrier()
  for disposable in self.lifetime {
    disposable.dispose()
  }
  self.lifetime.clear()
  self.view_model.dispose()
  match self.original_overview_ruler {
    Some(ruler) => {
      ruler.dispose()
      self.overview_ruler_disposed = ruler.is_disposed()
    }
    None => ()
  }
  match self.modified_overview_ruler {
    Some(ruler) => {
      ruler.dispose()
      self.overview_ruler_disposed = self.overview_ruler_disposed &&
        ruler.is_disposed()
    }
    None => ()
  }
  self.original_overview_ruler = None
  self.modified_overview_ruler = None
  self.editors.dispose()
  self.original_decoration_ids.clear()
  self.modified_decoration_ids.clear()
  self.original_alignment_zone_ids.clear()
  self.modified_alignment_zone_ids.clear()
  self.inline_deleted_zones.clear()
  self.original_alignment_geometry = None
  self.modified_alignment_geometry = None
  self.diff_state = None
  self.reconciling_generation = 0
  self.is_reconciling = false
  self.layout_render_generation = 0
  self.has_valid_layout_box = false
  self.host.remove_child(self.root.as_node())
}
