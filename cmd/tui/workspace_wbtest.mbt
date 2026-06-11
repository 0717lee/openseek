///|
async test "by default the launch directory is the workspace" {
  let home = @fs.tmpdir(prefix="openseek-tui-home-")
  let parsed = cli_command().parse(argv=[], env={ "DEEPSEEK": "test-key" })
  let config = launch_config(parsed, home~)
  // The conversation runs in the (canonicalized) launch directory and its
  // sessions live inside it. Nothing touches that store at launch, so
  // asserting against the real cwd leaves no droppings behind.
  assert_eq(config.cwd, @fs.realpath(launch_cwd()))
  assert_eq(config.session_root, config.cwd + "/.openseek")
  // Opening indexed the workspace under the home for --workspace-list.
  let listings = @workspace.WorkspaceHome(home).listings()
  assert_eq(listings.length(), 1)
  assert_eq(listings[0].path(), config.cwd)
  assert_eq(listings[0].store_root(), config.session_root)
  @fs.rmdir(home, recursive=true)
}

///|
async test "an explicit --session-root bypasses the workspace layer" {
  let home = @fs.tmpdir(prefix="openseek-tui-home-")
  let root = @fs.tmpdir(prefix="openseek-tui-root-")
  let parsed = cli_command().parse(argv=["--session-root", root], env={
    "DEEPSEEK": "test-key",
  })
  let config = launch_config(parsed, home~)
  assert_eq(config.session_root, root)
  assert_eq(config.cwd, launch_cwd())
  // Nothing was indexed under the home: the workspace layer never ran.
  assert_true(@workspace.WorkspaceHome(home).listings().is_empty())
  @fs.rmdir(home, recursive=true)
  @fs.rmdir(root, recursive=true)
}
