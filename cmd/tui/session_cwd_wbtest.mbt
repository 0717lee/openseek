///|
async test "resume re-roots the conversation in the session's recorded directory" {
  let root = @fs.tmpdir(prefix="openseek-tui-session-cwd-")
  let project = @fs.tmpdir(prefix="openseek-tui-project-")
  // The recorded directory refines the workspace: a subdirectory of it.
  let recorded = project + "/sub"
  @fs.mkdir(recorded)
  let store = @store.SessionStore(root)
  store.create(
    Session(SessionId("with-cwd"), system_prompt="system", cwd=recorded),
  )
  let parsed = cli_command().parse(
    argv=["--session", "with-cwd", "--session-root", root],
    env={ "DEEPSEEK": "test-key" },
  )
  let config = with_session_cwd(
    parse_config(parsed, cwd=project, session_root=root),
  )
  assert_eq(config.cwd, recorded)
  @fs.rmdir(root, recursive=true)
  @fs.rmdir(project, recursive=true)
}

///|
async test "a recorded directory outside the workspace is ignored" {
  let root = @fs.tmpdir(prefix="openseek-tui-session-cwd-outside-")
  let project = @fs.tmpdir(prefix="openseek-tui-project-")
  // Exists, but is not within the workspace being opened — e.g. the
  // original location of a project that was copied, sessions and all.
  let elsewhere = @fs.tmpdir(prefix="openseek-tui-elsewhere-")
  let store = @store.SessionStore(root)
  store.create(
    Session(SessionId("outside"), system_prompt="system", cwd=elsewhere),
  )
  let parsed = cli_command().parse(
    argv=["--session", "outside", "--session-root", root],
    env={ "DEEPSEEK": "test-key" },
  )
  let config = with_session_cwd(
    parse_config(parsed, cwd=project, session_root=root),
  )
  assert_eq(config.cwd, project)
  @fs.rmdir(root, recursive=true)
  @fs.rmdir(project, recursive=true)
  @fs.rmdir(elsewhere, recursive=true)
}

///|
async test "a session without a recorded directory keeps the configured one" {
  let root = @fs.tmpdir(prefix="openseek-tui-session-cwd-legacy-")
  let store = @store.SessionStore(root)
  store.create(Session(SessionId("legacy"), system_prompt="system"))
  let parsed = cli_command().parse(
    argv=["--session", "legacy", "--session-root", root],
    env={ "DEEPSEEK": "test-key" },
  )
  let config = with_session_cwd(
    parse_config(parsed, cwd="/configured", session_root=root),
  )
  assert_eq(config.cwd, "/configured")
  @fs.rmdir(root, recursive=true)
}

///|
async test "a vanished recorded directory keeps the configured one" {
  let root = @fs.tmpdir(prefix="openseek-tui-session-cwd-stale-")
  let gone = @fs.tmpdir(prefix="openseek-tui-gone-cwd-")
  @fs.rmdir(gone, recursive=true)
  let store = @store.SessionStore(root)
  store.create(Session(SessionId("stale"), system_prompt="system", cwd=gone))
  let parsed = cli_command().parse(
    argv=["--session", "stale", "--session-root", root],
    env={ "DEEPSEEK": "test-key" },
  )
  let config = with_session_cwd(
    parse_config(parsed, cwd="/configured", session_root=root),
  )
  assert_eq(config.cwd, "/configured")
  @fs.rmdir(root, recursive=true)
}

///|
async test "a fresh session keeps the configured directory" {
  let root = @fs.tmpdir(prefix="openseek-tui-session-cwd-fresh-")
  let parsed = cli_command().parse(
    argv=["--session", "brand-new", "--session-root", root],
    env={ "DEEPSEEK": "test-key" },
  )
  let before = parse_config(parsed, cwd=launch_cwd(), session_root=root)
  let config = with_session_cwd(before)
  assert_eq(config.cwd, before.cwd)
  @fs.rmdir(root, recursive=true)
}
