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
  zones : Array[InlineDeletedZone]
}

///|
struct InlineDeletedZone {
  change_index : Int
  zone_id : Ref[String?]
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
  diff_state : DiffState,
) -> InlineDeletedViewZones {
  let specs : Array[@code_widget.ManagedCodeEditorViewZoneSpec] = []
  let zones : Array[InlineDeletedZone] = []
  for change_index in 0..<diff_state.mapping_count() {
    guard diff_state.mapping_at(change_index) is Some(change) else { continue }
    if change.original.is_empty() {
      continue
    }
    match
      renderer.render_lines(
        original_model,
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
        let zone_id : Ref[String?] = Ref(None)
        specs.push(
          ManagedCodeEditorViewZoneSpec(
            inline_deleted_zone_anchor(change),
            rendered.height_in_px(),
            rendered.dom_node(),
            margin_dom_node=rendered.margin_dom_node(),
            min_width_in_px=rendered.min_width_in_px(),
            ordinal=change_index,
            suppress_mouse_down=false,
            on_zone_registered=(id, _zone) => zone_id.val = Some(id),
          ),
        )
        zones.push({ change_index, zone_id })
      }
      None => ()
    }
  }
  { specs, zones }
}
