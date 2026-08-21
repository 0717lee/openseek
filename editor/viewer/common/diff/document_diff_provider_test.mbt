///|
struct ExternalDocumentDiffProvider {}

///|
impl @diff.DocumentDiffProvider for ExternalDocumentDiffProvider with fn compute_diff(
  _self,
  _original,
  _modified,
  _options,
) {
  let original = @base_common.LineRange(1, 2)
  let modified = @base_common.LineRange(1, 2)
  let inner = @diff.RangeMapping(
    @base_common.Range(1, 1, 1, 2),
    @base_common.Range(1, 1, 1, 3),
  )
  {
    changes: [@diff.DetailedLineRangeMapping(original, modified, Some([inner]))],
    additional_alignments: [@diff.LineRangeMapping(original, modified)],
  }
}

///|
impl @diff.DocumentDiffProvider for ExternalDocumentDiffProvider with fn on_did_change(
  _self,
  _listener,
) {
  @base_common.Disposable::from(() => ())
}

///|
test "an external package can implement the provider and construct mappings" {
  let provider : &@diff.DocumentDiffProvider = ExternalDocumentDiffProvider::{

  }
  let result = try! provider.compute_diff(
    @model.TextSnapshot("a"),
    @model.TextSnapshot("bc"),
    { ignore_trim_whitespace: false },
  )
  assert_eq(result.changes.length(), 1)
  assert_eq(result.additional_alignments.length(), 1)
  assert_eq(result.changes[0].inner_changes.unwrap()[0].modified.end_column, 3)
}
