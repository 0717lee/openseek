// The file tree's visible hierarchy. Quick Open owns workspace-wide fuzzy
// matching; this package now renders only the expanded directory tree.

///|
/// Tree rows currently on screen, in depth-first render order with indentation
/// depth. Only listed, expanded directories contribute descendants.
fn visible_entries(state : State) -> Array[(FileEntry, Int)] {
  let rows : Array[(FileEntry, Int)] = []
  push_tree_entries(state, @pathx.Relative::root(), 0, rows)
  rows
}

///|
fn push_tree_entries(
  state : State,
  dir_path : @pathx.Relative,
  depth : Int,
  into : Array[(FileEntry, Int)],
) -> Unit {
  guard state.children.get(dir_path) is Some(entries) else { return }
  for entry in entries {
    into.push((entry, depth))
    if entry.is_dir && state.expanded.contains(entry.path) {
      push_tree_entries(state, entry.path, depth + 1, into)
    }
  }
}

///|
test "visible tree entries follow expanded directories depth first" {
  let state = {
    ..State::empty(),
    children: Map::from_array([
      (
        Relative(""),
        [
          { name: "src", path: Relative("src"), is_dir: true },
          { name: "main.mbt", path: Relative("main.mbt"), is_dir: false },
        ],
      ),
      (
        Relative("src"),
        [{ name: "lib.mbt", path: Relative("src/lib.mbt"), is_dir: false }],
      ),
    ]),
    expanded: [Relative("src")],
  }
  let rows = visible_entries(state)
  assert_eq(rows.map(pair => pair.0.path.0), ["src", "src/lib.mbt", "main.mbt"])
  assert_eq(rows.map(pair => pair.1), [0, 1, 0])
}

///|
test "Quick Open file index starts once and retries an initial failure" {
  let emit = test_emit()
  let ctx = test_ctx()
  let state = { ..State::empty(), owner: Some(ctx.owner) }
  let (_, loading) = update(emit, EnsureFileIndex, state, ctx)
  assert_true(loading.index is IndexLoading)
  let (_, still_loading) = update(emit, EnsureFileIndex, loading, ctx)
  assert_true(still_loading.index is IndexLoading)
  let (_, failed) = update(
    emit,
    FileIndexFailed(owner=ctx.owner, epoch=ctx.request_epoch),
    still_loading,
    ctx,
  )
  assert_true(failed.index is IndexFailed)
  let (_, retrying) = update(emit, EnsureFileIndex, failed, ctx)
  assert_true(retrying.index is IndexLoading)
}

///|
test "file index replies are owner fenced and refresh failure keeps ready data" {
  let emit = test_emit()
  let ctx = test_ctx()
  let loading = {
    ..State::empty(),
    owner: Some(ctx.owner),
    index: IndexLoading,
  }
  let stale_owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Remote("other"),
    session: ctx.owner.session,
  }
  let (_, stale) = update(
    emit,
    FilesIndexed(
      owner=stale_owner,
      epoch=ctx.request_epoch,
      files=[Relative("stale.mbt")],
      truncated=false,
    ),
    loading,
    ctx,
  )
  assert_true(stale.index is IndexLoading)
  let (_, ready) = update(
    emit,
    FilesIndexed(
      owner=ctx.owner,
      epoch=ctx.request_epoch,
      files=[Relative("src/main.mbt")],
      truncated=true,
    ),
    stale,
    ctx,
  )
  assert_true(ready.index is IndexReady(truncated=true, ..))
  let (_, kept) = update(
    emit,
    FileIndexFailed(owner=ctx.owner, epoch=ctx.request_epoch),
    ready,
    ctx,
  )
  assert_true(kept.index is IndexReady(files=[Relative("src/main.mbt")], ..))
}

///|
test "a live file index keeps the workspace root watcher while tree is closed" {
  let ctx = { ..test_ctx(), panel_open: false }
  let idle = { ..State::empty(), owner: Some(ctx.owner) }
  assert_true(idle.watched_paths(ctx) is None)
  let indexed = {
    ..idle,
    index: IndexReady(files=[Relative("main.mbt")], truncated=false),
  }
  guard indexed.watched_paths(ctx) is Some(watch) else {
    fail("ready Quick Open index should retain the workspace watcher")
  }
  assert_eq(watch.directories.map(path => path.0), [""])
}
