///|
async fn run_edit_undo(store : @undo.UndoStore) -> @agent_tool.ToolAction {
  match @edit_undo.definition(undo=Some(store)).execute {
    Async(execute) => execute({})
    Sync(_) => fail("edit_undo should be async")
  }
}

///|
async test "edit_undo restores an edited file to its original content" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/a.mbt"
    @fs.write_file(path, "EDITED\n", create_mode=CreateOrTruncate)
    let store = @undo.UndoStore::new()
    store.push([{ path, before: Some("ORIGINAL\n"), after: "EDITED\n" }])
    let result = run_edit_undo(store)
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_true(output.content.contains("reverted 1 file(s)"))
    assert_eq(@fs.read_file(path).text(), "ORIGINAL\n")
    assert_eq(store.depth(), 0)
  })
}

///|
async test "edit_undo errors when nothing is left to undo" {
  let store = @undo.UndoStore::new()
  let result = run_edit_undo(store)
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("nothing to undo"))
}

///|
async test "edit_undo refuses to revert a file changed since the edit" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/a.mbt"
    // Current content differs from `after` — something edited it afterward.
    @fs.write_file(path, "EDITED_AGAIN\n", create_mode=CreateOrTruncate)
    let store = @undo.UndoStore::new()
    store.push([{ path, before: Some("ORIGINAL\n"), after: "EDITED\n" }])
    let result = run_edit_undo(store)
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("conflict"))
    // Not reverted, and the edition stays on the stack.
    assert_eq(@fs.read_file(path).text(), "EDITED_AGAIN\n")
    assert_eq(store.depth(), 1)
  })
}

///|
async test "edit_undo reverts every file in the edition atomically" {
  @vfs.with_tmpdir(dir => {
    let a = "\{dir}/a.mbt"
    let b = "\{dir}/b.mbt"
    @fs.write_file(a, "EA\n", create_mode=CreateOrTruncate)
    @fs.write_file(b, "EB\n", create_mode=CreateOrTruncate)
    let store = @undo.UndoStore::new()
    store.push([
      { path: a, before: Some("OA\n"), after: "EA\n" },
      { path: b, before: Some("OB\n"), after: "EB\n" },
    ])
    let result = run_edit_undo(store)
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_eq(@fs.read_file(a).text(), "OA\n")
    assert_eq(@fs.read_file(b).text(), "OB\n")
  })
}

///|
async test "edit_undo deletes a file the edition created" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/created.txt"
    @fs.write_file(path, "MADE\n", create_mode=CreateOrTruncate)
    let store = @undo.UndoStore::new()
    // before=None marks a file the edition created; undo deletes it.
    store.push([{ path, before: None, after: "MADE\n" }])
    let result = run_edit_undo(store)
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_false(@fs.exists(path))
  })
}
