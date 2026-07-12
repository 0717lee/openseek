///|
/// Tool definition for `remove`: delete a `.mbt`/`.mbt.md` source file that the
/// agent created earlier this session.
///
/// This fills the one gap in the tool-mediated file API — `read`/`write`/`edit`
/// exist, but there was no in-workflow way to delete a source file, because the
/// shell sandbox blocks `rm` on source paths. `remove` is intentionally narrow:
/// it deletes ONLY a source file the session's `FileStateMap` records as
/// `Created`, i.e. one the agent itself created this session, so removing it
/// merely undoes the agent's own work. A pre-existing source file (one the agent
/// did not create this session) is refused — change it with `edit`, or delete it
/// outside the agent.
///
/// `Created` is advisory, not a bare delete capability (see `FileStateMap`).
/// Three things keep the gate honest: this tool drops the provenance when it
/// removes a file (`forget`), so a path recreated after a removal is no longer
/// seen as agent-created; the kind check does not follow symlinks, so a source
/// path replaced by a link is refused rather than followed; and the shell
/// sandbox blocks writing or moving onto a source path, so an un-removed
/// `Created` source file cannot be rebound through the shell. The narrow
/// residual — an external process replacing an un-removed `Created` file in
/// place — is left to a later hardening (stored file identity, or soft-delete).
/// The map is keyed by the same resolved path `write` used, so an unrecognized
/// spelling reads as unknown and is conservatively refused.
///
/// ## Result
/// - `Respond(ToolOutput("ok: removed <path>"))` when the file is deleted.
/// - `Respond(ToolOutput("error removing <path>: <reason>", is_error=true))` for
///   a non-source path, a missing file, a directory, a file the agent did not
///   create this session, or a filesystem failure.
/// - `Respond(ToolOutput("error: remove requires ...", is_error=true))` for
///   invalid arguments.
pub fn definition(
  workspace_root? : String = ".",
  file_state? : @agent_tool.FileStateMap = @agent_tool.FileStateMap::new(),
) -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="remove",
    description="Delete a .mbt or .mbt.md source file that the agent created earlier THIS session (tracked in the session's file-state record). Only a source file the agent itself created this session can be removed — a pre-existing one is refused, since deleting it could lose work the agent never made; change existing source with edit/multi_edit, and delete non-source files with shell. The path must name an existing regular .mbt/.mbt.md file. This is the only in-workflow way to delete a source file: the shell sandbox blocks rm on source paths.",
    schema=JsonSchema({
      "type": "object",
      "properties": { "path": { "type": "string" } },
      "required": ["path"],
    }),
    execute=Async(arguments => {
      execute_with_workspace(workspace_root, file_state, arguments)
    }),
  )
}

///|
async fn execute_with_workspace(
  workspace_root : String,
  file_state : @agent_tool.FileStateMap,
  arguments : Json,
) -> @agent_tool.ToolAction {
  let requested = decode_path(arguments) catch {
    error => {
      let message = @tool_error.failure_message("\{error}")
      return @agent_tool.ToolAction::respond(
        "error: remove requires \{message}",
        is_error=true,
      )
    }
  }
  let path = @workspace_path.resolve(workspace_root, requested)
  remove_file(path, requested, file_state)
}

///|
/// Decode the `remove` arguments: a single required `path` string. Names the
/// offending field (`arguments.path` / `object arguments`) so the model is told
/// exactly what to fix.
fn decode_path(arguments : Json) -> String raise {
  match arguments {
    Object(fields) =>
      match fields.get("path") {
        Some(String(path)) => path
        _ => fail("arguments.path")
      }
    _ => fail("object arguments")
  }
}

///|
async fn remove_file(
  path : String,
  requested : String,
  file_state : @agent_tool.FileStateMap,
) -> @agent_tool.ToolAction {
  let fail_brief = "remove \{@agent_tool.brief_basename(path)}"
  fn err(message : String) -> @agent_tool.ToolAction {
    @agent_tool.ToolAction::respond(
      "error removing \{path}: \{message}",
      is_error=true,
      brief=fail_brief,
    )
  }

  // Scope: source files only. The shell sandbox does not block `rm` on
  // non-source files, so those are deleted with shell; this tool exists for the
  // source gap alone.
  if !is_mbt_source(path) {
    return err(
      "remove handles .mbt/.mbt.md source files; delete other files with shell",
    )
  }
  let exists = @fs.exists(path) catch {
    error if @async.is_being_cancelled() => raise error
    error => return err("\{error}")
  }
  if !exists {
    return err("no such file")
  }
  // Classify the final component WITHOUT following a symlink: a path that was a
  // source file when `write` recorded it but has since been replaced by a
  // symlink must be refused, not followed to whatever it now points at.
  let kind = @fs.kind(path, follow_symlink=false) catch {
    error if @async.is_being_cancelled() => raise error
    error => return err("\{error}")
  }
  guard kind is Regular else {
    return err("not a regular file; remove deletes regular files")
  }
  // The gate: only a source file the agent CREATED this session may be removed.
  // `record_modified` never downgrades `Created`, so a file the agent created
  // and then edited still qualifies; a file it only modified, or never touched,
  // does not.
  guard file_state.get(path) is Some(Created) else {
    return err(
      "not created by the agent this session — only a .mbt/.mbt.md file the agent itself created this session can be removed; change existing source with edit/multi_edit, or delete it outside the agent",
    )
  }
  @fs.remove(path) catch {
    error if @async.is_being_cancelled() => raise error
    error => return err("\{error}")
  }
  // Drop the provenance so a path recreated after this removal is not treated
  // as still agent-created — otherwise a later remove could delete a different
  // file that happens to land at the same path.
  file_state.forget(path)
  @agent_tool.ToolAction::respond(
    "ok: removed \{path}",
    brief=@agent_tool.brief_line("removed \{requested}"),
  )
}

///|
/// Whether `path` is a hand-written MoonBit source file (`.mbt` or `.mbt.md`) —
/// the same set `write` refuses to overwrite and the shell sandbox blocks `rm`
/// on. `.mbti` and manifests are intentionally out of scope for now.
fn is_mbt_source(path : String) -> Bool {
  path.has_suffix(".mbt") || path.has_suffix(".mbt.md")
}

///|
/// Run the `remove` tool bound to a shared file-state map — the shape every test
/// drives.
async fn run_remove(
  file_state : @agent_tool.FileStateMap,
  arguments : Json,
) -> @agent_tool.ToolAction {
  match definition(file_state~).execute {
    Async(run) => run(arguments)
    Sync(_) => fail("remove tool should be async")
  }
}

///|
async test "remove deletes a source file the agent created this session" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/scratch.mbt"
    @fs.write_file(
      path,
      "pub fn f() -> Int { 1 }\n",
      create_mode=CreateOrTruncate,
    )
    // The map records the create, as `write` would have.
    let state = @agent_tool.FileStateMap::new()
    state.record_created(path)
    let result = run_remove(state, { "path": path })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_eq(output.content, "ok: removed \{path}")
    assert_false(@fs.exists(path))
  })
}

///|
async test "remove keeps deleting a created file it later edited" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/grown.mbt"
    @fs.write_file(
      path,
      "pub fn f() -> Int { 1 }\n",
      create_mode=CreateOrTruncate,
    )
    let state = @agent_tool.FileStateMap::new()
    // Created then modified this session: record_modified must not downgrade it.
    state.record_created(path)
    state.record_modified(path)
    let result = run_remove(state, { "path": path })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_false(@fs.exists(path))
  })
}

///|
async test "remove refuses a pre-existing source file it did not create" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/lib.mbt"
    @fs.write_file(
      path,
      "pub fn g() -> Int { 0 }\n",
      create_mode=CreateOrTruncate,
    )
    // Empty state: the agent did not create this file this session.
    let state = @agent_tool.FileStateMap::new()
    let result = run_remove(state, { "path": path })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(
      output.content.contains("not created by the agent this session"),
    )
    // The file is untouched.
    assert_true(@fs.exists(path))
  })
}

///|
async test "remove refuses a source file the agent only modified" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/edited.mbt"
    @fs.write_file(
      path,
      "pub fn h() -> Int { 2 }\n",
      create_mode=CreateOrTruncate,
    )
    let state = @agent_tool.FileStateMap::new()
    state.record_modified(path)
    let result = run_remove(state, { "path": path })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(
      output.content.contains("not created by the agent this session"),
    )
    assert_true(@fs.exists(path))
  })
}

///|
async test "remove rejects a non-source path" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/notes.txt"
    @fs.write_file(path, "scratch", create_mode=CreateOrTruncate)
    // Even a Created non-source file is out of scope: shell can rm those.
    let state = @agent_tool.FileStateMap::new()
    state.record_created(path)
    let result = run_remove(state, { "path": path })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("delete other files with shell"))
    assert_true(@fs.exists(path))
  })
}

///|
async test "remove reports a missing file" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/ghost.mbt"
    let state = @agent_tool.FileStateMap::new()
    state.record_created(path)
    let result = run_remove(state, { "path": path })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("no such file"))
  })
}

///|
async test "remove refuses a directory" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/pkg.mbt"
    @fs.mkdir(path, recursive=true)
    let state = @agent_tool.FileStateMap::new()
    state.record_created(path)
    let result = run_remove(state, { "path": path })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("not a regular file"))
    assert_true(@fs.exists(path))
  })
}

///|
async test "remove refuses a path recreated after an earlier removal" {
  @vfs.with_tmpdir(dir => {
    let path = "\{dir}/redo.mbt"
    @fs.write_file(
      path,
      "pub fn a() -> Int { 1 }\n",
      create_mode=CreateOrTruncate,
    )
    let state = @agent_tool.FileStateMap::new()
    state.record_created(path)
    // The first removal succeeds and drops the provenance.
    let first = run_remove(state, { "path": path })
    guard first is Respond(ok) else { fail("expected Respond") }
    assert_false(ok.is_error)
    assert_false(@fs.exists(path))
    // Something OTHER than the agent's tools recreates the same path.
    @fs.write_file(
      path,
      "pub fn b() -> Int { 2 }\n",
      create_mode=CreateOrTruncate,
    )
    // The stale Created must not authorize deleting this different file.
    let second = run_remove(state, { "path": path })
    guard second is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(
      output.content.contains("not created by the agent this session"),
    )
    assert_true(@fs.exists(path))
  })
}

///|
async test "remove refuses a source path replaced by a symlink" {
  @vfs.with_tmpdir(dir => {
    let target = "\{dir}/target.mbt"
    @fs.write_file(
      target,
      "pub fn t() -> Int { 0 }\n",
      create_mode=CreateOrTruncate,
    )
    // The .mbt path the agent created is now a symlink to another file.
    let link = "\{dir}/alias.mbt"
    @fs.symlink(target~, link)
    let state = @agent_tool.FileStateMap::new()
    state.record_created(link)
    let result = run_remove(state, { "path": link })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("not a regular file"))
    // The kind check does not follow the link, so neither it nor its target is
    // removed.
    assert_true(@fs.exists(link))
    assert_true(@fs.exists(target))
  })
}

///|
async test "remove rejects missing path" {
  let state = @agent_tool.FileStateMap::new()
  let result = run_remove(state, { "note": "no path here" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_eq(output.content, "error: remove requires arguments.path")
  assert_true(output.is_error)
}
