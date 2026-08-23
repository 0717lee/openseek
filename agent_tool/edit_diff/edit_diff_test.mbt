///|
test "a replacement includes its surrounding context" {
  assert_eq(
    @edit_diff.generate("first\nold\nlast", "first\nnew\nlast"),
    "  first\n- old\n+ new\n  last",
  )
}

///|
test "an empty side is an insertion or deletion" {
  assert_eq(@edit_diff.generate("", "one\ntwo"), "+ one\n+ two")
  assert_eq(@edit_diff.generate("one\ntwo", ""), "- one\n- two")
}

///|
/// The line unique to both sides is Patience's anchor. Myers chooses a
/// different valid shortest script for this repeated-line input.
test "patience diff keeps a unique line anchored" {
  assert_eq(
    @edit_diff.generate("unique\ndup\ndup", "dup\nunique\ndup"),
    "+ dup\n  unique\n  dup\n- dup",
  )
}
