///|
async test "opening a directory creates its workspace and reopening reuses it" {
  let home_root = @fs.tmpdir(prefix="openseek-workspace-home-")
  let project = @fs.tmpdir(prefix="openseek-workspace-project-")
  let home = @workspace.WorkspaceHome(home_root)
  let first = home.open(project, now_unix=100)
  assert_eq(first.path(), @fs.realpath(project))
  // Sessions stay with the project; the home only indexes the workspace.
  assert_eq(first.store_root(), first.path() + "/.openseek")
  let again = home.open(project, now_unix=200)
  assert_eq(again.store_root(), first.store_root())
  assert_eq(again.path(), first.path())
  let listings = home.listings()
  assert_eq(listings.length(), 1)
  assert_eq(listings[0].path(), first.path())
  assert_eq(listings[0].store_root(), first.store_root())
  // Reopening bumped the stamp.
  assert_eq(listings[0].last_opened_unix(), 200)
  @fs.rmdir(home_root, recursive=true)
  @fs.rmdir(project, recursive=true)
}

///|
async test "distinct directories get distinct stores, listed most recent first" {
  let home_root = @fs.tmpdir(prefix="openseek-workspace-home-")
  let older = @fs.tmpdir(prefix="openseek-workspace-older-")
  let newer = @fs.tmpdir(prefix="openseek-workspace-newer-")
  let home = @workspace.WorkspaceHome(home_root)
  let older_workspace = home.open(older, now_unix=100)
  let newer_workspace = home.open(newer, now_unix=200)
  assert_true(older_workspace.store_root() != newer_workspace.store_root())
  let listings = home.listings()
  assert_eq(listings.length(), 2)
  assert_eq(listings[0].path(), newer_workspace.path())
  assert_eq(listings[1].path(), older_workspace.path())
  @fs.rmdir(home_root, recursive=true)
  @fs.rmdir(older, recursive=true)
  @fs.rmdir(newer, recursive=true)
}

///|
async test "a home that was never opened lists no workspaces" {
  let home_root = @fs.tmpdir(prefix="openseek-workspace-home-")
  // The `workspaces/` tree does not exist yet; listing treats that as empty.
  assert_true(@workspace.WorkspaceHome(home_root).listings().is_empty())
  @fs.rmdir(home_root, recursive=true)
}

///|
async test "opening a missing directory raises" {
  let home_root = @fs.tmpdir(prefix="openseek-workspace-home-")
  let gone = @fs.tmpdir(prefix="openseek-workspace-gone-")
  @fs.rmdir(gone, recursive=true)
  let _ = @workspace.WorkspaceHome(home_root).open(gone, now_unix=100) catch {
    _ => {
      @fs.rmdir(home_root, recursive=true)
      return
    }
  }
  fail("opening a missing directory succeeded")
}
