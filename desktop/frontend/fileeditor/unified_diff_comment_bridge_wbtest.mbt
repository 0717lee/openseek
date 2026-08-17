///|
test "full-diff comments cross the Desktop boundary without losing line identity" {
  let file = @pathx.Relative("src/main.mbt")
  let deletion = unified_diff_comment_message(file, {
    line: {
      kind: @unified_diff.Deletion,
      original_line_number: Some(4),
      modified_line_number: None,
      text: "obsolete()",
    },
    comment: "good removal",
  })
  assert_true(
    deletion
    is UnifiedDiffCommentAdded(
      file=@pathx.Relative("src/main.mbt"),
      original_line_number=Some(4),
      modified_line_number=None,
      quote="obsolete()",
      comment="good removal",
      resource=None,
      feedback_id=None
    ),
  )
  let context = unified_diff_comment_message(file, {
    line: {
      kind: @unified_diff.Context,
      original_line_number: Some(8),
      modified_line_number: Some(9),
      text: "shared()",
    },
    comment: "keep this",
  })
  assert_true(
    context
    is UnifiedDiffCommentAdded(
      original_line_number=Some(8),
      modified_line_number=Some(9),
      quote="shared()",
      comment="keep this",
      ..
    ),
  )
  let original_viewer = unified_diff_comment_message(
    file,
    {
      line: {
        kind: @unified_diff.Deletion,
        original_line_number: Some(12),
        modified_line_number: None,
        text: "removed()",
      },
      comment: "restore this",
    },
    resource=ModelUri("openseek-review-original://workspace/src/main.mbt"),
    feedback_id="feedback-12",
  )
  assert_true(
    original_viewer
    is UnifiedDiffCommentAdded(
      original_line_number=Some(12),
      modified_line_number=None,
      resource=Some(
        ModelUri("openseek-review-original://workspace/src/main.mbt")
      ),
      feedback_id=Some("feedback-12"),
      ..
    ),
  )
}
