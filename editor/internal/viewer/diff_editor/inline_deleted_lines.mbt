// Inline deleted hunks are ordinary CodeEditorWidget-managed ViewZones whose
// content is rendered by the kernel's native detached-line pipeline. This
// layer only projects canonical DocumentDiff changes into zone placement and
// UTF-16 decoration inputs; it never tokenizes or measures text itself.

///|
fn inline_original_decorations(
  change : @diff.DetailedLineRangeMapping,
) -> Array[@code_widget.CodeEditorRenderLinesDecoration] {
  let decorations : Array[@code_widget.CodeEditorRenderLinesDecoration] = []
  match change.inner_changes {
    Some(inner_changes) =>
      for inner in inner_changes {
        if !inner.original.is_empty() {
          decorations.push({
            range: inner.original,
            class_name: "diff-editor-inline-char-delete",
          })
        }
      }
    None => ()
  }
  decorations
}

///|
fn inline_deleted_zone_anchor(change : @diff.DetailedLineRangeMapping) -> Int {
  (change.modified.start_line_number - 1).max(0)
}

///|
priv struct InlineDeletedViewZones {
  specs : Array[@code_widget.ManagedCodeEditorViewZoneSpec]
  render_context : @code_widget.VirtualizedCodeEditorRenderLinesContext?
  virtualized_renderers : Array[InlineDeletedRenderer]
}

///|
pub struct InlineDeletedRenderer {
  change_index : Int
  renderer : @code_widget.VirtualizedCodeEditorRenderedLines
}

///|
fn configure_inline_deleted_roots(
  dom_node : @rdom.Element,
  margin_dom_node : @rdom.Element,
  change : @diff.DetailedLineRangeMapping,
) -> Unit {
  dom_node.set_attribute("class", "view-lines diff-editor-inline-deleted-block")
  dom_node.set_attribute(
    "data-original-line-start",
    change.original.start_line_number.to_string(),
  )
  dom_node.set_attribute(
    "data-original-line-end-exclusive",
    change.original.end_line_number_exclusive.to_string(),
  )
  margin_dom_node.set_attribute("class", "diff-editor-inline-deleted-margin")
}

///|
fn inline_deleted_view_zone_specs(
  renderer : @code_widget.CodeEditorWidget,
  original_model : @model.TextModel,
  projection : DiffFeatureProjection,
  generation : Int,
) -> InlineDeletedViewZones {
  let specs : Array[@code_widget.ManagedCodeEditorViewZoneSpec] = []
  let virtualized_renderers : Array[InlineDeletedRenderer] = []
  let mut render_context : @code_widget.VirtualizedCodeEditorRenderLinesContext? = None
  for change_index in 0..<projection.change_count() {
    guard projection.change_at(change_index) is Some(change) else { continue }
    if change.original.is_empty() {
      continue
    }
    if render_context is None {
      render_context = renderer.create_render_lines_context(
        original_model,
        owner_generation=generation,
      )
    }
    guard render_context is Some(context) else { continue }
    match
      context.render_lines(
        change.original,
        decorations=inline_original_decorations(change),
        line_class_name="diff-editor-inline-deleted-line",
        margin_line_class_name="diff-editor-inline-deleted-line-number",
      ) {
      Some(rendered) => {
        configure_inline_deleted_roots(
          rendered.dom_node(),
          rendered.margin_dom_node(),
          change,
        )
        specs.push(
          rendered.managed_view_zone_spec(
            inline_deleted_zone_anchor(change),
            ordinal=change_index,
            suppress_mouse_down=false,
          ),
        )
        virtualized_renderers.push({ change_index, renderer: rendered })
      }
      None => ()
    }
  }
  { specs, render_context, virtualized_renderers }
}
