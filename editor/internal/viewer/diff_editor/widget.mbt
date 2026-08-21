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
  live_region : @rdom.Element
  editors : DiffEditorEditors
  view_model : DiffEditorViewModel
  mut editor_options : @code_widget.CodeEditorOptions
  mut options : DiffEditorOptions
  layout_state : DiffEditorLayoutState
  pointer_monitor : @base_browser.GlobalPointerMoveMonitor
  lifetime : Array[@base_common.Disposable]
  mut resize_observer : @base_common.Disposable?
  mut overview_ruler : @code_widget.CodeEditorOverviewRuler?
  mut original_decoration_ids : Array[String]
  mut modified_decoration_ids : Array[String]
  mut original_alignment_zone_ids : Array[String]
  mut modified_alignment_zone_ids : Array[String]
  mut inline_deleted_render_context : @code_widget.VirtualizedCodeEditorRenderLinesContext?
  mut inline_deleted_renderers : Array[InlineDeletedRenderer]
  mut original_alignment_geometry : PaneGeometrySnapshot?
  mut modified_alignment_geometry : PaneGeometrySnapshot?
  mut projection : DiffFeatureProjection?
  mut navigation_index : Int?
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
  mut inline_render_context_disposed : Bool
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
fn diff_inner_decorations(
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
  let live_region = document.create_element("div")
  live_region.set_attribute("class", "moonbit-diff-editor-live-region")
  live_region.set_attribute("aria-live", "polite")
  live_region.set_attribute("aria-atomic", "true")
  root.append_child(panes.as_node())
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
    live_region,
    editors,
    view_model,
    editor_options,
    options,
    layout_state: DiffEditorLayoutState::new(options),
    pointer_monitor: GlobalPointerMoveMonitor(),
    lifetime: [],
    resize_observer: None,
    overview_ruler: None,
    original_decoration_ids: [],
    modified_decoration_ids: [],
    original_alignment_zone_ids: [],
    modified_alignment_zone_ids: [],
    inline_deleted_render_context: None,
    inline_deleted_renderers: [],
    original_alignment_geometry: None,
    modified_alignment_geometry: None,
    projection: None,
    navigation_index: None,
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
    inline_render_context_disposed: false,
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
fn DiffEditorWidget::dispose_inline_deleted_renderers(
  self : DiffEditorWidget,
) -> Unit {
  match self.inline_deleted_render_context {
    Some(context) => {
      context.dispose()
      self.inline_render_context_disposed = context.is_disposed()
    }
    None =>
      for entry in self.inline_deleted_renderers {
        entry.renderer.dispose()
      }
  }
  self.inline_deleted_renderers.clear()
  self.inline_deleted_render_context = None
}

///|
fn DiffEditorWidget::apply_projection_decorations(
  self : DiffEditorWidget,
  projection : DiffFeatureProjection,
) -> Unit {
  let original_projection = projection.original_decorations()
  let modified_projection = projection.modified_decorations()
  let original_decorations = diff_whole_line_decorations(
    original_projection.whole_line_ranges(),
    "diff-editor-line-delete",
    "diff-editor-gutter-delete",
    "diff-editor-original-line",
  )
  original_decorations.append(
    diff_inner_decorations(
      original_projection.inner_ranges(),
      "diff-editor-char-delete",
      "diff-editor-original-character",
    ),
  )
  let modified_decorations = diff_whole_line_decorations(
    modified_projection.whole_line_ranges(),
    "diff-editor-line-insert",
    "diff-editor-gutter-insert",
    "diff-editor-modified-line",
  )
  modified_decorations.append(
    diff_inner_decorations(
      modified_projection.inner_ranges(),
      "diff-editor-char-insert",
      "diff-editor-modified-character",
    ),
  )
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
  match self.overview_ruler {
    Some(ruler) => ruler.clear(generation)
    None => ()
  }
}

///|
fn DiffEditorWidget::apply_overview_projection(
  self : DiffEditorWidget,
  projection : DiffFeatureProjection,
  model : DiffEditorModelData,
  generation : Int,
) -> Unit {
  match self.overview_ruler {
    Some(ruler) =>
      ruler.set_entries(
        generation,
        diff_overview_ruler_entries(projection, model.modified.get_line_count()),
      )
    None => ()
  }
}

///|
fn DiffEditorWidget::sync_overview_ruler_option(
  self : DiffEditorWidget,
) -> Unit {
  if !self.options.overview_ruler {
    match self.overview_ruler {
      Some(ruler) => {
        ruler.dispose()
        self.overview_ruler_disposed = ruler.is_disposed()
      }
      None => ()
    }
    self.overview_ruler = None
    return
  }
  if self.overview_ruler is None {
    self.overview_ruler = Some(
      self.editors.modified.create_overview_ruler(on_select=change_index => {
        self.reveal_overview_change(change_index) |> ignore
      }),
    )
    self.overview_ruler_disposed = false
  }
  match (self.projection, self.view_model.get_model()) {
    (Some(projection), Some(model)) =>
      self.apply_overview_projection(
        projection,
        model,
        self.reconciling_generation,
      )
    _ => self.clear_overview_ruler(self.reconciling_generation)
  }
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
  commit_diff_reconcile_generation(
    generation,
    () => self.clear_decorations(),
    generation => {
      self.original_alignment_zone_ids = replace_alignment_zones(
        self.editors.original,
        self.original_alignment_zone_ids,
        [],
        generation,
      )
    },
    generation => {
      self.dispose_inline_deleted_renderers()
      self.modified_alignment_zone_ids = replace_alignment_zones(
        self.editors.modified,
        self.modified_alignment_zone_ids,
        [],
        generation,
      )
    },
    () => {
      self.restore_stable_viewports(
        original_viewport, modified_viewport, inline_modified_viewport,
      )
    },
    generation => self.clear_overview_ruler(generation),
  )
  self.original_alignment_geometry = None
  self.modified_alignment_geometry = None
  self.projection = None
  self.live_region.set_inner_html("")
}

///|
fn DiffEditorWidget::commit_projection(
  self : DiffEditorWidget,
  projection : DiffFeatureProjection,
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
  let (original_geometry, modified_geometry) = self.capture_alignment_geometry()
  let (
    original_specs,
    modified_specs,
    next_inline_deleted_render_context,
    next_inline_deleted_renderers,
  ) = match
    (self.layout_state.actual_layout, original_geometry, modified_geometry) {
    (SideBySide, Some(original_geometry), Some(modified_geometry)) => {
      let spacers = compute_managed_alignment_spacers(
        projection, original_geometry, modified_geometry,
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
        None,
        [],
      )
    }
    (Inline, _, _) => {
      let inline_zones = inline_deleted_view_zone_specs(
        self.editors.modified,
        model.original,
        projection,
        generation,
      )
      (
        [],
        inline_zones.specs,
        inline_zones.render_context,
        inline_zones.virtualized_renderers,
      )
    }
    _ => ([], [], None, [])
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
  commit_diff_reconcile_generation(
    generation,
    () => self.apply_projection_decorations(projection),
    generation => {
      self.original_alignment_zone_ids = replace_alignment_zones(
        self.editors.original,
        self.original_alignment_zone_ids,
        original_specs,
        generation,
      )
    },
    generation => {
      self.dispose_inline_deleted_renderers()
      self.modified_alignment_zone_ids = replace_alignment_zones(
        self.editors.modified,
        self.modified_alignment_zone_ids,
        modified_specs,
        generation,
      )
      self.inline_deleted_render_context = next_inline_deleted_render_context
      self.inline_deleted_renderers = next_inline_deleted_renderers
      if self.inline_deleted_render_context is Some(_) {
        self.inline_render_context_disposed = false
      }
    },
    () => {
      self.restore_stable_viewports(
        original_viewport, modified_viewport, inline_modified_viewport,
      )
    },
    generation => self.apply_overview_projection(projection, model, generation),
  )
  self.projection = Some(projection)
}

///|
fn DiffEditorWidget::reconcile_geometry_if_changed(
  self : DiffEditorWidget,
) -> Unit {
  if self.disposed ||
    self.editors.is_committing_model_pair() ||
    self.is_reconciling ||
    self.projection is None ||
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
  // Keep the pair commit as the outer boundary even if future projection
  // construction gains a synchronous callback seam.
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
  self.navigation_index = None
  guard self.view_model.get_diff() is Some(document_diff) &&
    self.view_model.get_model() is Some(model) else {
    self.commit_empty_diff_features(generation)
    return
  }
  let projection = DiffFeatureProjection(
    document_diff,
    model.original.snapshot(),
    model.modified.snapshot(),
  )
  self.commit_projection(
    projection,
    model,
    generation,
    preserve_inline_model_anchor=geometry_refresh &&
      self.inline_deleted_render_context is Some(_),
  )
}

///|
fn DiffEditorWidget::clear_diff_features_for_transition(
  self : DiffEditorWidget,
) -> Unit {
  if self.editors.is_committing_model_pair() ||
    self.is_reconciling ||
    (
      self.projection is None &&
      self.original_decoration_ids.is_empty() &&
      self.modified_decoration_ids.is_empty() &&
      self.original_alignment_zone_ids.is_empty() &&
      self.modified_alignment_zone_ids.is_empty() &&
      self.inline_deleted_renderers.is_empty()
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
  let layout_changed = self.layout_state.update_options(
    options,
    recompute_layout=valid_layout_box,
  )
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
  OriginalNavigationPane
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
  Range(range.start_line_number, 1, range.end_line_number_exclusive - 1, 1)
}

///|
fn diff_navigation_reveal_plan(
  layout : DiffEditorLayout,
  change : @diff.DetailedLineRangeMapping,
  original_line_count : Int,
  modified_line_count : Int,
) -> DiffNavigationRevealPlan? {
  match layout {
    Inline =>
      // Inline has only one interactive code surface. In particular, a
      // deletion-only hunk must reveal its empty modified-side anchor instead
      // of moving focus into the hidden original kernel.
      Some({
        pane: ModifiedNavigationPane,
        range: navigation_reveal_range(change.modified, modified_line_count),
      })
    SideBySide =>
      if !change.modified.is_empty() {
        Some({
          pane: ModifiedNavigationPane,
          range: navigation_reveal_range(change.modified, modified_line_count),
        })
      } else if !change.original.is_empty() {
        Some({
          pane: OriginalNavigationPane,
          range: navigation_reveal_range(change.original, original_line_count),
        })
      } else {
        None
      }
  }
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
fn DiffEditorWidget::reveal_inline_deleted_zone(
  self : DiffEditorWidget,
  change_index : Int,
) -> Bool {
  if self.layout_state.actual_layout != Inline {
    return false
  }
  for entry in self.inline_deleted_renderers {
    if entry.change_index == change_index && entry.renderer.reveal_zone_top() {
      self.editors.modified.focus()
      return true
    }
  }
  false
}

///|
fn DiffEditorWidget::reveal_navigation_target(
  self : DiffEditorWidget,
  target : DiffNavigationTarget,
) -> Bool {
  let change = target.change
  guard self.view_model.get_model() is Some(model) else { return false }
  self.navigation_index = Some(target.change_index)
  if change.modified.is_empty() &&
    !change.original.is_empty() &&
    self.reveal_inline_deleted_zone(target.change_index) {
    self.announce_navigation_target(target)
    return true
  }
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
    OriginalNavigationPane => {
      self.editors.original.reveal_range_in_center(plan.range)
      self.editors.original.focus()
    }
    ModifiedNavigationPane => {
      self.editors.modified.reveal_range_in_center(plan.range)
      self.editors.modified.focus()
    }
  }
  self.announce_navigation_target(target)
  true
}

///|
fn DiffEditorWidget::reveal_overview_change(
  self : DiffEditorWidget,
  change_index : Int,
) -> Bool {
  guard !self.disposed &&
    self.projection is Some(projection) &&
    projection.change_at(change_index) is Some(change) &&
    self.view_model.get_model() is Some(model) else {
    return false
  }
  self.navigation_index = Some(change_index)
  if change.modified.is_empty() &&
    !change.original.is_empty() &&
    self.reveal_inline_deleted_zone(change_index) {
    self.announce_navigation_target({
      change_index,
      change_count: projection.change_count(),
      change,
    })
    return true
  }
  if !change.modified.is_empty() {
    self.editors.modified.reveal_range_in_center(
      Range(
        change.modified.start_line_number,
        1,
        change.modified.end_line_number_exclusive - 1,
        1,
      ),
    )
  } else {
    let line_number = change.modified.start_line_number.clamp(
      min=1,
      max=model.modified.get_line_count().max(1),
    )
    self.editors.modified.reveal_line_in_center(line_number)
  }
  self.editors.modified.focus()
  self.announce_navigation_target({
    change_index,
    change_count: projection.change_count(),
    change,
  })
  true
}

///|
pub fn DiffEditorWidget::reveal_next_change(self : DiffEditorWidget) -> Bool {
  guard self.projection is Some(projection) &&
    projection.next_change(self.navigation_index) is Some(target) else {
    return false
  }
  self.reveal_navigation_target(target)
}

///|
pub fn DiffEditorWidget::reveal_previous_change(
  self : DiffEditorWidget,
) -> Bool {
  guard self.projection is Some(projection) &&
    projection.previous_change(self.navigation_index) is Some(target) else {
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
  let layout_changed = self.layout_state.layout(width)
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
  match self.overview_ruler {
    Some(ruler) => {
      ruler.dispose()
      self.overview_ruler_disposed = ruler.is_disposed()
    }
    None => ()
  }
  self.overview_ruler = None
  self.editors.dispose()
  self.original_decoration_ids.clear()
  self.modified_decoration_ids.clear()
  self.original_alignment_zone_ids.clear()
  self.modified_alignment_zone_ids.clear()
  self.dispose_inline_deleted_renderers()
  self.original_alignment_geometry = None
  self.modified_alignment_geometry = None
  self.projection = None
  self.navigation_index = None
  self.reconciling_generation = 0
  self.is_reconciling = false
  self.layout_render_generation = 0
  self.has_valid_layout_box = false
  self.host.remove_child(self.root.as_node())
}
