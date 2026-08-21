///|
test "inline deleted zones use the modified insertion anchor" {
  let leading = @diff.DetailedLineRangeMapping(
    @base_common.LineRange(1, 4),
    @base_common.LineRange(1, 1),
    None,
  )
  let middle = @diff.DetailedLineRangeMapping(
    @base_common.LineRange(80, 210),
    @base_common.LineRange(25, 25),
    None,
  )
  assert_eq(inline_deleted_zone_anchor(leading), 0)
  assert_eq(inline_deleted_zone_anchor(middle), 24)
}
