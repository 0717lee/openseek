///|
async test "prepare output dir creates runner artifact directories" {
  let root = @fs.tmpdir(prefix="openseek-prompt-task-output")
  let out_dir = root + "/out"
  prepare_output_dir(out_dir)
  assert_true(@fs.exists(out_dir + "/workspaces"))
  assert_true(@fs.exists(out_dir + "/logs"))
  assert_true(@fs.exists(out_dir + "/session_store"))
  @fs.rmdir(root, recursive=true)
}

///|
async test "indexed runner honors concurrency and preserves order" {
  let mut active = 0
  let mut max_active = 0
  let results = run_indexed_with_concurrency(5, 2, index => {
    active += 1
    if active > max_active {
      max_active = active
    }
    @async.sleep(20)
    active -= 1
    index
  })
  json_inspect(results, content=[0, 1, 2, 3, 4])
  assert_eq(max_active, 2)
}
