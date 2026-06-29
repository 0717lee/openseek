///|
async fn run_write_with_undo(
  store : @undo.UndoStore,
  arguments : Json,
) -> @agent_tool.ToolAction {
  match @write.definition(undo=Some(store)).execute {
    Async(execute) => execute(arguments)
    Sync(_) => fail("write tool should be async")
  }
}

///|
async test "write records a created file with before=None (undo deletes it)" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/new.txt"
    let store = @undo.UndoStore::new()
    let result = run_write_with_undo(store, {
      "path": path,
      "content": "MADE\n",
    })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_eq(store.depth(), 1)
    guard store.pop() is Some(entry) else { fail("expected a snapshot") }
    assert_eq(entry.files[0].path, path)
    assert_true(entry.files[0].before is None)
    assert_eq(entry.files[0].after, "MADE\n")
  })
}

///|
async test "write records the prior content when overwriting a non-source file" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/data.txt"
    @fs.write_file(path, "OLD\n", create_mode=CreateOrTruncate)
    let store = @undo.UndoStore::new()
    let result = run_write_with_undo(store, { "path": path, "content": "NEW\n" })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    guard store.pop() is Some(entry) else { fail("expected a snapshot") }
    assert_true(entry.files[0].before is Some("OLD\n"))
    assert_eq(entry.files[0].after, "NEW\n")
  })
}
