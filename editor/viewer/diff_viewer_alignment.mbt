// Pixel alignment for the two ordinary Viewer children. This follows
// VS Code's `computeRangeAlignment`: foreign ViewZones participate in the
// coordinate system, detailed Standard-diff ranges add alignment points
// inside hunks, and only coordinator-owned zones are excluded.

///|
priv struct DiffAdditionalLineHeight {
  line_number : Int
  height_in_px : Double
}

///|
priv struct DiffViewZoneHeight {
  id : String
  after_line_number : Int
  height_in_px : Double
}

///|
priv struct DiffRangeAlignment {
  original : @base_common.LineRange
  modified : @base_common.LineRange
  original_height_in_px : Double
  modified_height_in_px : Double
}

///|
priv struct DiffPixelSpacer {
  after_line_number : Int
  height_in_px : Double
}

///|
priv struct DiffPixelSpacers {
  original : Array[DiffPixelSpacer]
  modified : Array[DiffPixelSpacer]
}

///|
fn normalized_additional_line_heights(
  heights : Array[DiffAdditionalLineHeight],
) -> Array[DiffAdditionalLineHeight] {
  let sorted = heights.copy()
  sorted.sort_by((left, right) => left.line_number - right.line_number)
  let result : Array[DiffAdditionalLineHeight] = []
  for height in sorted {
    if !result.is_empty() &&
      result[result.length() - 1].line_number == height.line_number {
      let previous = result[result.length() - 1]
      result[result.length() - 1] = {
        line_number: previous.line_number,
        height_in_px: previous.height_in_px + height.height_in_px,
      }
    } else {
      result.push(height)
    }
  }
  result
}

///|
fn additional_line_heights_from_view_zones(
  zones : Array[DiffViewZoneHeight],
  owned_zone_ids : Array[String],
) -> Array[DiffAdditionalLineHeight] {
  let heights : Array[DiffAdditionalLineHeight] = []
  for zone in zones {
    if !owned_zone_ids.contains(zone.id) {
      heights.push({
        line_number: zone.after_line_number,
        height_in_px: zone.height_in_px,
      })
    }
  }
  normalized_additional_line_heights(heights)
}

///|
/// ViewZones are extra pixels on the model axis, while hidden model lines
/// contribute zero pixels. VS Code's diff editor disables folding for this
/// calculation; OpenSeek additionally replaces Markdown comment source lines
/// with a ViewZone, so subtract those hidden line heights before running the
/// same range-alignment algorithm.
fn additional_line_heights_from_layout(
  zones : Array[DiffViewZoneHeight],
  owned_zone_ids : Array[String],
  hidden_areas : Array[@base_common.Range],
  line_height : Double,
) -> Array[DiffAdditionalLineHeight] {
  let heights = additional_line_heights_from_view_zones(zones, owned_zone_ids)
  for hidden in hidden_areas {
    let line_number = Ref(hidden.start_line_number)
    while line_number.val <= hidden.end_line_number {
      heights.push({ line_number: line_number.val, height_in_px: -line_height })
      line_number.val += 1
    }
  }
  normalized_additional_line_heights(heights)
}

///|
fn Viewer::diff_additional_line_heights(
  self : Viewer,
  owned_zone_ids : Array[String],
) -> Array[DiffAdditionalLineHeight] {
  guard self.get_view_model() is Some(view_model) else { return [] }
  guard self.current_code_browser_data() is Some(browser) else { return [] }
  let zones : Array[DiffViewZoneHeight] = []
  for info in browser.view.view_zone_layout_infos() {
    let (id, after_model_line_number, height_in_px) = info
    zones.push({ id, after_line_number: after_model_line_number, height_in_px })
  }
  additional_line_heights_from_layout(
    zones,
    owned_zone_ids,
    view_model.get_hidden_areas(),
    self.configuration.snapshot().font_info.line_height.to_double(),
  )
}

///|
fn compute_diff_range_alignments(
  changes : Array[DiffLineChange],
  original_additional : Array[DiffAdditionalLineHeight],
  modified_additional : Array[DiffAdditionalLineHeight],
  original_line_height : Double,
  modified_line_height : Double,
  original_max_column : (Int) -> Int,
  inner_hunk_alignment? : Bool = true,
) -> Array[DiffRangeAlignment] {
  let original_additional = normalized_additional_line_heights(
    original_additional,
  )
  let modified_additional = normalized_additional_line_heights(
    modified_additional,
  )
  let original_index = Ref(0)
  let modified_index = Ref(0)
  let last_original_line_number = Ref(0)
  let last_modified_line_number = Ref(0)
  let result : Array[DiffRangeAlignment] = []

  let handle_alignments_outside_diffs = fn(
    until_original_line_number_exclusive : Int,
    until_modified_line_number_exclusive : Int,
  ) {
    while true {
      let original_next = if original_index.val < original_additional.length() &&
        original_additional[original_index.val].line_number <
        until_original_line_number_exclusive {
        Some(original_additional[original_index.val])
      } else {
        None
      }
      let modified_next = if modified_index.val < modified_additional.length() &&
        modified_additional[modified_index.val].line_number <
        until_modified_line_number_exclusive {
        Some(modified_additional[modified_index.val])
      } else {
        None
      }
      if original_next is None && modified_next is None {
        break
      }
      let original_distance = match original_next {
        Some(next) => next.line_number - last_original_line_number.val
        None => 2147483647
      }
      let modified_distance = match modified_next {
        Some(next) => next.line_number - last_modified_line_number.val
        None => 2147483647
      }
      let (original, modified) = if original_distance < modified_distance {
        guard original_next is Some(original) else { break }
        original_index.val += 1
        (
          original,
          {
            line_number: original.line_number -
            last_original_line_number.val +
            last_modified_line_number.val,
            height_in_px: 0.0,
          },
        )
      } else if original_distance > modified_distance {
        guard modified_next is Some(modified) else { break }
        modified_index.val += 1
        (
          {
            line_number: modified.line_number -
            last_modified_line_number.val +
            last_original_line_number.val,
            height_in_px: 0.0,
          },
          modified,
        )
      } else {
        guard (original_next, modified_next) is (Some(original), Some(modified)) else {
          break
        }
        original_index.val += 1
        modified_index.val += 1
        (original, modified)
      }
      result.push({
        original: LineRange(original.line_number, original.line_number + 1),
        modified: LineRange(modified.line_number, modified.line_number + 1),
        original_height_in_px: original_line_height + original.height_in_px,
        modified_height_in_px: modified_line_height + modified.height_in_px,
      })
    }
  }

  for change in changes {
    handle_alignments_outside_diffs(
      change.original.start_line_number,
      change.modified.start_line_number,
    )
    let first = Ref(true)
    let last_original = Ref(change.original.start_line_number)
    let last_modified = Ref(change.modified.start_line_number)
    let emit_alignment = fn(
      original_line_number_exclusive : Int,
      modified_line_number_exclusive : Int,
      force_alignment : Bool,
    ) {
      if original_line_number_exclusive < last_original.val ||
        modified_line_number_exclusive < last_modified.val {
        return
      }
      if first.val {
        first.val = false
      } else if !force_alignment &&
        (
          original_line_number_exclusive == last_original.val ||
          modified_line_number_exclusive == last_modified.val
        ) {
        return
      }
      let original_range = @base_common.LineRange(
        last_original.val,
        original_line_number_exclusive,
      )
      let modified_range = @base_common.LineRange(
        last_modified.val,
        modified_line_number_exclusive,
      )
      if original_range.is_empty() && modified_range.is_empty() {
        return
      }
      let mut original_extra = 0.0
      while original_index.val < original_additional.length() &&
            original_additional[original_index.val].line_number <
            original_line_number_exclusive {
        original_extra += original_additional[original_index.val].height_in_px
        original_index.val += 1
      }
      let mut modified_extra = 0.0
      while modified_index.val < modified_additional.length() &&
            modified_additional[modified_index.val].line_number <
            modified_line_number_exclusive {
        modified_extra += modified_additional[modified_index.val].height_in_px
        modified_index.val += 1
      }
      result.push({
        original: original_range,
        modified: modified_range,
        original_height_in_px: original_range.length().to_double() *
        original_line_height +
        original_extra,
        modified_height_in_px: modified_range.length().to_double() *
        modified_line_height +
        modified_extra,
      })
      last_original.val = original_line_number_exclusive
      last_modified.val = modified_line_number_exclusive
    }
    if inner_hunk_alignment {
      for inner in change.paired_inner_changes {
        if inner.original.start_column > 1 && inner.modified.start_column > 1 {
          emit_alignment(
            inner.original.start_line_number,
            inner.modified.start_line_number,
            false,
          )
        }
        if inner.original.end_column <
          original_max_column(inner.original.end_line_number) {
          emit_alignment(
            inner.original.end_line_number,
            inner.modified.end_line_number,
            false,
          )
        }
      }
    }
    emit_alignment(
      change.original.end_line_number_exclusive,
      change.modified.end_line_number_exclusive,
      true,
    )
    last_original_line_number.val = change.original.end_line_number_exclusive
    last_modified_line_number.val = change.modified.end_line_number_exclusive
  }
  handle_alignments_outside_diffs(2147483647, 2147483647)
  result
}

///|
fn diff_pixel_spacers(
  alignments : Array[DiffRangeAlignment],
) -> DiffPixelSpacers {
  let original : Array[DiffPixelSpacer] = []
  let modified : Array[DiffPixelSpacer] = []
  for alignment in alignments {
    let delta = alignment.modified_height_in_px -
      alignment.original_height_in_px
    if delta > 0.0 {
      original.push({
        after_line_number: alignment.original.end_line_number_exclusive - 1,
        height_in_px: delta,
      })
    } else if delta < 0.0 {
      modified.push({
        after_line_number: alignment.modified.end_line_number_exclusive - 1,
        height_in_px: -delta,
      })
    }
  }
  { original, modified }
}

///|
fn diff_pixel_spacer_height(spacers : Array[DiffPixelSpacer]) -> Double {
  spacers.fold(init=0.0, (height, spacer) => height + spacer.height_in_px)
}

///|
/// `computeRangeAlignment` assumes its diff mappings cover every positional
/// source delta. Structural diff modes can deliberately omit a semantically
/// equivalent physical row, while foreign ViewZones and horizontal overflow
/// also live outside the diff result. Preserve all range-local spacers, then
/// close only the remaining document-tail pixel delta so both ordinary
/// ViewLayouts expose the same content and maximum scroll height.
fn balance_diff_pixel_spacers(
  spacers : DiffPixelSpacers,
  original_content_height_without_owned : Double,
  modified_content_height_without_owned : Double,
  original_last_line_number : Int,
  modified_last_line_number : Int,
) -> DiffPixelSpacers {
  let original = spacers.original.copy()
  let modified = spacers.modified.copy()
  let original_height = original_content_height_without_owned +
    diff_pixel_spacer_height(original)
  let modified_height = modified_content_height_without_owned +
    diff_pixel_spacer_height(modified)
  let delta = modified_height - original_height
  if delta > 0.5 {
    original.push({
      after_line_number: original_last_line_number,
      height_in_px: delta,
    })
  } else if delta < -0.5 {
    modified.push({
      after_line_number: modified_last_line_number,
      height_in_px: -delta,
    })
  }
  { original, modified }
}

///|
fn Viewer::diff_content_height_without_owned_zones(
  self : Viewer,
  owned_zone_ids : Array[String],
) -> Double {
  let mut owned_height = 0.0
  match self.current_code_browser_data() {
    Some(browser) =>
      for info in browser.view.view_zone_layout_infos() {
        let (id, _, height_in_px) = info
        if owned_zone_ids.contains(id) {
          owned_height += height_in_px
        }
      }
    None => ()
  }
  (self.active_content_height().unwrap_or(0.0) - owned_height).max(0.0)
}

///|
fn compute_diff_pixel_spacers(
  original_viewer : Viewer,
  modified_viewer : Viewer,
  changes : Array[DiffLineChange],
  original_owned_zone_ids : Array[String],
  modified_owned_zone_ids : Array[String],
  original_content_height_without_owned? : Double,
  modified_content_height_without_owned? : Double,
) -> DiffPixelSpacers {
  guard original_viewer.get_model() is Some(original_model) else {
    return { original: [], modified: [] }
  }
  guard modified_viewer.get_model() is Some(modified_model) else {
    return { original: [], modified: [] }
  }
  let original_line_height = original_viewer.configuration.snapshot().font_info.line_height.to_double()
  let modified_line_height = modified_viewer.configuration.snapshot().font_info.line_height.to_double()
  let spacers = diff_pixel_spacers(
    compute_diff_range_alignments(
      changes,
      original_viewer.diff_additional_line_heights(original_owned_zone_ids),
      modified_viewer.diff_additional_line_heights(modified_owned_zone_ids),
      original_line_height,
      modified_line_height,
      line_number => {
        if line_number <= original_model.get_line_count() {
          original_model.get_line_max_column(line_number)
        } else {
          2147483647
        }
      },
    ),
  )
  balance_diff_pixel_spacers(
    spacers,
    original_content_height_without_owned.unwrap_or_else(() => {
      original_viewer.diff_content_height_without_owned_zones(
        original_owned_zone_ids,
      )
    }),
    modified_content_height_without_owned.unwrap_or_else(() => {
      modified_viewer.diff_content_height_without_owned_zones(
        modified_owned_zone_ids,
      )
    }),
    original_model.get_line_count(),
    modified_model.get_line_count(),
  )
}

///|
fn replace_alignment_zones(
  viewer : Viewer,
  old_ids : Array[String],
  spacers : Array[DiffPixelSpacer],
) -> Array[String] {
  let ids : Array[String] = []
  viewer.change_view_zones(accessor => {
    for id in old_ids {
      accessor.remove_zone(id)
    }
    for spacer in spacers {
      let dom_node = @rdom.document().create_element("div")
      dom_node.set_attribute("class", "diff-editor-alignment-zone")
      dom_node.set_attribute(
        "data-after-line",
        spacer.after_line_number.to_string(),
      )
      dom_node.set_attribute(
        "data-height-in-px",
        spacer.height_in_px.to_string(),
      )
      ids.push(
        accessor.add_zone(
          view_zone(
            spacer.after_line_number,
            dom_node,
            show_in_hidden_areas=true,
            suppress_mouse_down=true,
            height_in_px=spacer.height_in_px,
          ),
        ),
      )
    }
  })
  ids
}
