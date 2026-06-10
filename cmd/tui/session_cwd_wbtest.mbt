///|
async test "resume re-roots the conversation in the session's recorded directory" {
  let root = @fs.tmpdir(prefix="openseek-tui-session-cwd-")
  let recorded = @fs.tmpdir(prefix="openseek-tui-recorded-cwd-")
  let store = @store.SessionStore(root)
  store.create(
    Session(SessionId("with-cwd"), system_prompt="system", cwd=recorded),
  )
  let parsed = cli_command().parse(
    argv=["--session", "with-cwd", "--session-root", root],
    env={ "DEEPSEEK": "test-key" },
  )
  let config = with_session_cwd(parse_config(parsed))
  assert_eq(config.cwd, recorded)
  @fs.rmdir(root, recursive=true)
  @fs.rmdir(recorded, recursive=true)
}

///|
async test "resume falls back to home for sessions without a recorded directory" {
  let root = @fs.tmpdir(prefix="openseek-tui-session-cwd-legacy-")
  let store = @store.SessionStore(root)
  store.create(Session(SessionId("legacy"), system_prompt="system"))
  let parsed = cli_command().parse(
    argv=["--session", "legacy", "--session-root", root],
    env={ "DEEPSEEK": "test-key" },
  )
  let config = with_session_cwd(parse_config(parsed))
  guard home_dir() is Some(home) else { fail("expected a home directory") }
  assert_eq(config.cwd, home)
  @fs.rmdir(root, recursive=true)
}

///|
async test "resume falls back to home when the recorded directory is gone" {
  let root = @fs.tmpdir(prefix="openseek-tui-session-cwd-stale-")
  let gone = @fs.tmpdir(prefix="openseek-tui-gone-cwd-")
  @fs.rmdir(gone, recursive=true)
  let store = @store.SessionStore(root)
  store.create(Session(SessionId("stale"), system_prompt="system", cwd=gone))
  let parsed = cli_command().parse(
    argv=["--session", "stale", "--session-root", root],
    env={ "DEEPSEEK": "test-key" },
  )
  let config = with_session_cwd(parse_config(parsed))
  guard home_dir() is Some(home) else { fail("expected a home directory") }
  assert_eq(config.cwd, home)
  @fs.rmdir(root, recursive=true)
}

///|
async test "a fresh session keeps the launch directory" {
  let root = @fs.tmpdir(prefix="openseek-tui-session-cwd-fresh-")
  let parsed = cli_command().parse(
    argv=["--session", "brand-new", "--session-root", root],
    env={ "DEEPSEEK": "test-key" },
  )
  let before = parse_config(parsed)
  let config = with_session_cwd(before)
  assert_eq(config.cwd, before.cwd)
  @fs.rmdir(root, recursive=true)
}
