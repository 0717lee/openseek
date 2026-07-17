///|
async test "prepare output dir creates runner artifact directories" {
  @vfs.with_tmpdir(prefix="openseek-eval-runner-output", root => {
    let out_dir = "\{root}/out"
    @runner.prepare_output_dir(out_dir)
    assert_true(@fs_test.exists("\{out_dir}/workspaces"))
    assert_true(@fs_test.exists("\{out_dir}/logs"))
  })
}

///|
async test "indexed runner honors concurrency and preserves order" {
  let mut active = 0
  let mut max_active = 0
  let results = @runner.run_indexed_with_concurrency(5, 2, index => {
    active += 1
    if active > max_active {
      max_active = active
    }
    @async_test.sleep(20)
    active -= 1
    index
  })
  json_inspect(results, content=[0, 1, 2, 3, 4])
  assert_eq(max_active, 2)
}

///|
test "padded index zero-pads to two digits" {
  assert_eq(@runner.padded_index(1), "01")
  assert_eq(@runner.padded_index(42), "42")
  assert_eq(@runner.padded_index(100), "100")
}
