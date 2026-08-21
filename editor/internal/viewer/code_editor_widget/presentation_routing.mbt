///|
/// A `CodeEditorWidget` has exactly one presentation family: the native code
/// editor. Keeping this predicate central lets code contributions retain their
/// no-model guard without depending on a product-level presentation router.
fn CodeEditorWidget::is_code_presentation(self : CodeEditorWidget) -> Bool {
  self.model_slot.current is Some(_)
}

///|
fn CodeEditorWidget::active_scroll_position(
  self : CodeEditorWidget,
) -> @view_layout.ScrollPosition? {
  guard self.model_slot.current is Some(model_data) else { return None }
  Some(model_data.view_model.view_layout.position())
}

///|
fn CodeEditorWidget::active_content_width(self : CodeEditorWidget) -> Double? {
  guard self.model_slot.current is Some(model_data) else { return None }
  Some(model_data.view_model.view_layout.get_content_width())
}

///|
fn CodeEditorWidget::active_scroll_width(self : CodeEditorWidget) -> Double? {
  guard self.model_slot.current is Some(model_data) else { return None }
  Some(model_data.view_model.view_layout.get_scroll_width())
}

///|
fn CodeEditorWidget::active_content_height(self : CodeEditorWidget) -> Double? {
  guard self.model_slot.current is Some(model_data) else { return None }
  Some(model_data.view_model.view_layout.get_content_height())
}

///|
fn CodeEditorWidget::active_scroll_height(self : CodeEditorWidget) -> Double? {
  guard self.model_slot.current is Some(model_data) else { return None }
  Some(model_data.view_model.view_layout.get_scroll_height())
}

///|
fn CodeEditorWidget::set_active_scroll_position(
  self : CodeEditorWidget,
  scroll_top? : Double,
  scroll_left? : Double,
) -> Unit {
  guard self.model_slot.current is Some(model_data) else { return }
  let layout = model_data.view_model.view_layout
  let position = layout.position()
  layout.scroll_to(
    scroll_top=scroll_top.unwrap_or(position.scroll_top),
    scroll_left=scroll_left.unwrap_or(position.scroll_left),
  )
  |> ignore
}

///|
fn CodeEditorWidget::stabilize_active_scroll(self : CodeEditorWidget) -> Unit {
  guard self.model_slot.current is Some(model_data) else { return }
  model_data.view_model.visible_lines_stabilized()
}

///|
/// `ViewLayout` already owns the code editor's measured dimensions; this hook
/// closes the outer widget's layout transaction without a second renderer.
fn CodeEditorWidget::layout_active_presentation(
  self : CodeEditorWidget,
  _width : Double,
  _height : Double,
) -> Unit {
  ignore(self)
}
