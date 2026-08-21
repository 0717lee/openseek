///|
priv struct MarkdownViewerWidgetDefinitionTarget {
  source_offset : Int
  range : @base_common.Range
  model_identity : Int
  model_version : Int
  attach_generation : Int
}

///|
fn MarkdownViewerWidgetDefinitionTarget::same(
  self : MarkdownViewerWidgetDefinitionTarget,
  other : MarkdownViewerWidgetDefinitionTarget,
) -> Bool {
  self.model_identity == other.model_identity &&
  self.model_version == other.model_version &&
  self.attach_generation == other.attach_generation &&
  self.range == other.range
}

///|
/// Attachment-scoped adapter from semantic Markdown DOM hits to the shared
/// language-definition registry and host location opener. It keeps no virtual
/// code model: every request is issued against the caller's original model.
priv struct MarkdownViewerWidgetDefinitionBridge {
  viewer : MarkdownViewerWidget
  view : @markdown_document.MarkdownDocumentView
  model : @model.TextModel
  attach_generation : Int
  listeners : Array[@base_common.Disposable]
  mut link_elements : Array[@rdom.Element]
  mut last_target : MarkdownViewerWidgetDefinitionTarget?
  mut mouse_down_target : MarkdownViewerWidgetDefinitionTarget?
  mut preview_source : @language.CancellationTokenSource?
  mut action_source : @language.CancellationTokenSource?
  mut request_generation : Int
  mut active : Bool
  mut disposed : Bool
}

///|
fn MarkdownViewerWidgetDefinitionBridge::MarkdownViewerWidgetDefinitionBridge(
  viewer : MarkdownViewerWidget,
  view : @markdown_document.MarkdownDocumentView,
  model : @model.TextModel,
  attach_generation : Int,
) -> MarkdownViewerWidgetDefinitionBridge {
  {
    viewer,
    view,
    model,
    attach_generation,
    listeners: [],
    link_elements: [],
    last_target: None,
    mouse_down_target: None,
    preview_source: None,
    action_source: None,
    request_generation: 0,
    active: false,
    disposed: false,
  }
}

///|
fn MarkdownViewerWidgetDefinitionBridge::is_current(
  self : MarkdownViewerWidgetDefinitionBridge,
) -> Bool {
  self.active &&
  !self.disposed &&
  !self.model.is_disposed() &&
  self.viewer.is_current_attachment(self.model, self.attach_generation) &&
  self.view.source_model_version() == self.model.get_version_id()
}

///|
fn MarkdownViewerWidgetDefinitionBridge::target_is_current(
  self : MarkdownViewerWidgetDefinitionBridge,
  target : MarkdownViewerWidgetDefinitionTarget,
) -> Bool {
  self.is_current() &&
  target.model_identity == self.model.identity() &&
  target.model_version == self.model.get_version_id() &&
  target.attach_generation == self.attach_generation
}

///|
fn MarkdownViewerWidgetDefinitionBridge::target_at(
  self : MarkdownViewerWidgetDefinitionBridge,
  client_x : Double,
  client_y : Double,
) -> MarkdownViewerWidgetDefinitionTarget? {
  guard self.is_current() &&
    self.view.semantic_pointer_hit(client_x, client_y) is Some(hit) else {
    return None
  }
  let position = self.model.get_position_at(hit.source_offset)
  guard self.model.get_word_at_position(position) is Some(word) else {
    return None
  }
  Some({
    source_offset: hit.source_offset,
    range: Range(
      position.line_number,
      word.start_column,
      position.line_number,
      word.end_column,
    ),
    model_identity: self.model.identity(),
    model_version: self.model.get_version_id(),
    attach_generation: self.attach_generation,
  })
}

///|
fn MarkdownViewerWidgetDefinitionBridge::listen(
  self : MarkdownViewerWidgetDefinitionBridge,
  element : @rdom.Element,
  event_name : String,
  listener : @rdom.Listener,
) -> Unit {
  element.add_event_listener(event_name, listener)
  self.listeners.push(
    @base_common.Disposable::from(() => {
      element.remove_event_listener(event_name, listener)
    }),
  )
}

///|
fn markdown_viewer_definition_modifier_is_active(
  ctrl : Bool,
  meta : Bool,
  alt : Bool,
  shift : Bool,
) -> Bool {
  guard !alt && !shift else { return false }
  if @base_common.is_macintosh {
    meta && !ctrl
  } else {
    ctrl && !meta
  }
}

///|
fn markdown_viewer_definition_modifier_key(key : String) -> Bool {
  if @base_common.is_macintosh {
    key == "Meta"
  } else {
    key == "Control"
  }
}

///|
fn MarkdownViewerWidgetDefinitionBridge::bind_semantic_dom(
  self : MarkdownViewerWidgetDefinitionBridge,
) -> Unit {
  guard self.is_current() else { return }
  self.view.listen_semantic_dom("mousemove", event => {
    guard self.is_current() && event.to_mouse_event() is Some(mouse) else {
      self.reset_link()
      return
    }
    let target = self.target_at(
      mouse.get_client_x().to_double(),
      mouse.get_client_y().to_double(),
    )
    self.last_target = target
    if mouse.get_buttons() == 0 &&
      markdown_viewer_definition_modifier_is_active(
        mouse.get_ctrl_key(),
        mouse.get_meta_key(),
        mouse.get_alt_key(),
        mouse.get_shift_key(),
      ) {
      match target {
        Some(target) => self.start_preview(target)
        None => self.cancel_preview()
      }
    } else {
      self.cancel_preview()
    }
  })
  self.view.listen_semantic_dom("mousedown", event => {
    guard self.is_current() && event.to_mouse_event() is Some(mouse) else {
      return
    }
    let standard = @base_browser.StandardMouseEvent(mouse)
    guard standard.left_button && standard.detail <= 1 else { return }
    self.viewer.focus()
    self.mouse_down_target = self.target_at(
      mouse.get_client_x().to_double(),
      mouse.get_client_y().to_double(),
    )
  })
  self.view.listen_semantic_dom("mouseup", event => {
    guard self.is_current() && event.to_mouse_event() is Some(mouse) else {
      return
    }
    let standard = @base_browser.StandardMouseEvent(mouse)
    let target = self.target_at(
      mouse.get_client_x().to_double(),
      mouse.get_client_y().to_double(),
    )
    let down = self.mouse_down_target
    self.mouse_down_target = None
    guard standard.left_button &&
      standard.detail <= 1 &&
      markdown_viewer_definition_modifier_is_active(
        standard.ctrl_key,
        standard.meta_key,
        standard.alt_key,
        standard.shift_key,
      ) &&
      down is Some(down) &&
      target is Some(target) &&
      down.same(target) &&
      self.target_is_current(target) else {
      return
    }
    self.start_action(target)
    event.prevent_default()
    event.stop_propagation()
  })
}

///|
fn MarkdownViewerWidgetDefinitionBridge::activate(
  self : MarkdownViewerWidgetDefinitionBridge,
) -> Unit {
  guard !self.disposed && !self.active else { return }
  self.active = true
  self.listen(self.view.root(), "keydown", event => {
    guard self.is_current() &&
      @base_browser.event_target_is(event, self.view.root()) &&
      event.to_keyboard_event() is Some(keyboard) else {
      return
    }
    if markdown_viewer_definition_modifier_key(keyboard.key()) {
      match self.last_target {
        Some(target) if markdown_viewer_definition_modifier_is_active(
            keyboard.ctrl_key(),
            keyboard.meta_key(),
            keyboard.alt_key(),
            keyboard.shift_key(),
          ) => self.start_preview(target)
        _ => self.cancel_preview()
      }
      return
    }
    if keyboard.key() == "F12" &&
      !keyboard.alt_key() &&
      !keyboard.shift_key() &&
      self.viewer.services.languages().has_definition_provider(self.model) {
      match self.last_target {
        Some(target) if self.target_is_current(target) => {
          self.start_action(target)
          event.prevent_default()
          event.stop_propagation()
        }
        _ => ()
      }
    }
  })
  self.listen(self.view.root(), "keyup", event => {
    guard event.to_keyboard_event() is Some(keyboard) else { return }
    if markdown_viewer_definition_modifier_key(keyboard.key()) {
      self.cancel_preview()
    }
  })
  self.listen(self.view.root(), "mouseleave", _ => self.reset_link())
  self.listen(self.view.root(), "blur", _ => self.reset_link())
  self.listen(self.view.viewport(), "scroll", _ => self.reset_link())
  self.bind_semantic_dom()
}

///|
fn MarkdownViewerWidgetDefinitionBridge::clear_link_elements(
  self : MarkdownViewerWidgetDefinitionBridge,
) -> Unit {
  for element in self.link_elements {
    @base_browser.remove_element(element)
  }
  self.link_elements.clear()
}

///|
fn MarkdownViewerWidgetDefinitionBridge::cancel_preview(
  self : MarkdownViewerWidgetDefinitionBridge,
) -> Unit {
  self.request_generation += 1
  match self.preview_source {
    Some(source) => source.dispose(cancel=true)
    None => ()
  }
  self.preview_source = None
  self.clear_link_elements()
}

///|
fn MarkdownViewerWidgetDefinitionBridge::cancel_action(
  self : MarkdownViewerWidgetDefinitionBridge,
) -> Unit {
  self.request_generation += 1
  match self.action_source {
    Some(source) => source.dispose(cancel=true)
    None => ()
  }
  self.action_source = None
}

///|
fn MarkdownViewerWidgetDefinitionBridge::reset_link(
  self : MarkdownViewerWidgetDefinitionBridge,
) -> Unit {
  self.cancel_preview()
  self.mouse_down_target = None
  self.last_target = None
}

///|
fn MarkdownViewerWidgetDefinitionBridge::start_preview(
  self : MarkdownViewerWidgetDefinitionBridge,
  target : MarkdownViewerWidgetDefinitionTarget,
) -> Unit {
  guard self.target_is_current(target) &&
    self.viewer.services.languages().has_definition_provider(self.model) else {
    self.cancel_preview()
    return
  }
  if self.last_target is Some(last) &&
    last.same(target) &&
    !self.link_elements.is_empty() {
    return
  }
  self.cancel_preview()
  self.last_target = Some(target)
  let generation = self.request_generation
  let source = @language.CancellationTokenSource()
  self.preview_source = Some(source)
  markdown_viewer_launch_async_task(async fn() noraise {
    let locations = self.viewer.services
      .languages()
      .definition_at(self.model, target.source_offset, token=source.token())
    guard !source.token().is_cancellation_requested() &&
      self.request_generation == generation &&
      self.preview_source is Some(current) &&
      physical_equal(current, source) &&
      self.target_is_current(target) else {
      source.dispose(cancel=true)
      return
    }
    source.dispose()
    self.preview_source = None
    if !locations.is_empty() {
      let source_range = self.model.snapshot.offset_range_of(target.range)
      self.link_elements = self.view.append_projected_range_spans(
        source_range, "moonbit-viewer-markdown-definition-link",
      )
    }
  })
}

///|
fn MarkdownViewerWidgetDefinitionBridge::start_action(
  self : MarkdownViewerWidgetDefinitionBridge,
  target : MarkdownViewerWidgetDefinitionTarget,
) -> Unit {
  guard self.target_is_current(target) &&
    self.viewer.services.languages().has_definition_provider(self.model) else {
    return
  }
  self.cancel_action()
  let generation = self.request_generation
  let source = @language.CancellationTokenSource()
  self.action_source = Some(source)
  markdown_viewer_launch_async_task(async fn() noraise {
    let locations = self.viewer.services
      .languages()
      .definition_at(self.model, target.source_offset, token=source.token())
    guard !source.token().is_cancellation_requested() &&
      self.request_generation == generation &&
      self.action_source is Some(current) &&
      physical_equal(current, source) &&
      self.target_is_current(target) else {
      source.dispose(cancel=true)
      return
    }
    source.dispose()
    self.action_source = None
    let locations = @definition.normalize_definition_locations(locations)
    guard locations is [location, ..] else { return }
    self.viewer.open_definition_location(location) |> ignore
  })
}

///|
async fn MarkdownViewerWidget::open_definition_location(
  self : MarkdownViewerWidget,
  location : @language.Location,
) -> Bool noraise {
  guard !self.disposed &&
    self.current is Some(current) &&
    current.view is Some(view) else {
    return false
  }
  if current.model.model.uri.to_string() == location.uri.to_string() {
    let range = current.model.model.validate_range(location.range)
    view.reveal_source_offset(
      current.model.model.get_offset_at(range.get_start_position()),
      "center",
    )
    current.layout_changed()
    return true
  }
  match self.services.location_opener() {
    Some(opener) =>
      opener.open({ source_viewer_id: self.get_id(), location, mode: Current })
    None => false
  }
}

///|
fn MarkdownViewerWidgetDefinitionBridge::before_projection_replaced(
  self : MarkdownViewerWidgetDefinitionBridge,
) -> Unit {
  guard !self.disposed else { return }
  self.cancel_action()
  self.reset_link()
}

///|
fn MarkdownViewerWidgetDefinitionBridge::after_projection_replaced(
  self : MarkdownViewerWidgetDefinitionBridge,
) -> Unit {
  guard !self.disposed else { return }
  self.bind_semantic_dom()
}

///|
fn MarkdownViewerWidgetDefinitionBridge::layout_changed(
  self : MarkdownViewerWidgetDefinitionBridge,
) -> Unit {
  guard !self.disposed else { return }
  self.reset_link()
}

///|
fn MarkdownViewerWidgetDefinitionBridge::dispose(
  self : MarkdownViewerWidgetDefinitionBridge,
) -> Unit {
  if self.disposed {
    return
  }
  self.disposed = true
  self.active = false
  self.cancel_action()
  self.reset_link()
  while self.listeners.length() > 0 {
    self.listeners.remove(self.listeners.length() - 1).dispose()
  }
}
