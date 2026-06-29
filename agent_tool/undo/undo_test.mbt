///|
test "push and pop are LIFO" {
  let store = @undo.UndoStore::new()
  store.push([{ path: "a.mbt", before: Some("old_a"), after: "new_a" }])
  store.push([{ path: "b.mbt", before: None, after: "new_b" }])
  assert_eq(store.depth(), 2)
  guard store.pop() is Some(second) else { fail("expected an entry") }
  assert_eq(second.files[0].path, "b.mbt")
  assert_true(second.files[0].before is None)
  assert_eq(second.files[0].after, "new_b")
  guard store.pop() is Some(first) else { fail("expected an entry") }
  assert_eq(first.files[0].path, "a.mbt")
  assert_true(first.files[0].before is Some("old_a"))
  assert_true(store.pop() is None)
  assert_eq(store.depth(), 0)
}

///|
test "depth is bounded, dropping the oldest editions" {
  let store = @undo.UndoStore::new(max_depth=2)
  store.push([{ path: "1", before: None, after: "x" }])
  store.push([{ path: "2", before: None, after: "x" }])
  store.push([{ path: "3", before: None, after: "x" }]) // drops "1"
  assert_eq(store.depth(), 2)
  guard store.pop() is Some(e3) else { fail("expected an entry") }
  assert_eq(e3.files[0].path, "3")
  guard store.pop() is Some(e2) else { fail("expected an entry") }
  assert_eq(e2.files[0].path, "2")
  // "1" was dropped when the cap was exceeded, so nothing is left.
  assert_true(store.pop() is None)
}

///|
test "max_depth is clamped to at least one" {
  let store = @undo.UndoStore::new(max_depth=0)
  store.push([{ path: "a", before: None, after: "x" }])
  store.push([{ path: "b", before: None, after: "y" }])
  assert_eq(store.depth(), 1)
  guard store.pop() is Some(e) else { fail("expected an entry") }
  assert_eq(e.files[0].path, "b")
}

///|
test "an edition can span multiple files" {
  let store = @undo.UndoStore::new()
  store.push([
    { path: "x.mbt", before: Some("ox"), after: "nx" },
    { path: "y.mbt", before: Some("oy"), after: "ny" },
  ])
  guard store.pop() is Some(e) else { fail("expected an entry") }
  assert_eq(e.files.length(), 2)
  assert_eq(e.files[1].path, "y.mbt")
}

///|
test "push_barrier records a non-undoable barrier" {
  let store = @undo.UndoStore::new()
  store.push_barrier("prior content was binary")
  assert_eq(store.depth(), 1)
  guard store.pop() is Some(entry) else { fail("expected an entry") }
  assert_eq(entry.files.length(), 0)
  assert_true(entry.reason is Some("prior content was binary"))
}
