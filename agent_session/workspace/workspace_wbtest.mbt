///|
async test "colliding keys probe to the next slot" {
  let home_root = @fs.tmpdir(prefix="openseek-workspace-home-")
  let project = @fs.tmpdir(prefix="openseek-workspace-project-")
  let canonical = @fs.realpath(project)
  // Pre-claim the project's slot for a different path, simulating a key
  // collision.
  let taken = home_root +
    "/" +
    WorkspacesDirName +
    "/" +
    workspace_key(canonical)
  ensure_dir(taken)
  write_workspace_file(taken, "/somewhere/else", 50)
  let home = WorkspaceHome(home_root)
  let workspace = home.open(project, now_unix=100)
  assert_eq(workspace.path(), canonical)
  // The project landed in the probed slot, leaving the claimed one intact.
  guard read_workspace_text(taken + "-1") is Some(text) else {
    fail("expected the probed slot to be claimed")
  }
  assert_eq(decode_workspace_text(text).path, canonical)
  let listings = home.listings()
  assert_eq(listings.length(), 2)
  assert_eq(listings[0].path(), canonical)
  assert_eq(listings[1].path(), "/somewhere/else")
  // Reopening keeps landing on the probed slot.
  let _ = home.open(project, now_unix=200)
  guard read_workspace_text(taken + "-1") is Some(text) else {
    fail("expected the probed slot to be claimed")
  }
  assert_eq(decode_workspace_text(text).last_opened_unix, 200)
  @fs.rmdir(home_root, recursive=true)
  @fs.rmdir(project, recursive=true)
}

///|
async test "a corrupt workspace file fails open and is skipped by listings" {
  let home_root = @fs.tmpdir(prefix="openseek-workspace-home-")
  let project = @fs.tmpdir(prefix="openseek-workspace-project-")
  let home = WorkspaceHome(home_root)
  let _ = home.open(project, now_unix=100)
  let entry = home_root +
    "/" +
    WorkspacesDirName +
    "/" +
    workspace_key(@fs.realpath(project))
  @fs.write_file(
    entry + "/" + WorkspaceFileName,
    "not json",
    create_mode=CreateOrTruncate,
  )
  // Opening must not silently reclaim a slot it can no longer identify.
  let _ = home.open(project, now_unix=200) catch {
    _ => {
      // A listing has no path to show for the slot, so it is skipped.
      assert_true(home.listings().is_empty())
      @fs.rmdir(home_root, recursive=true)
      @fs.rmdir(project, recursive=true)
      return
    }
  }
  fail("a corrupt workspace file was silently reclaimed")
}
