///|
async test "--continue resolves the most recently active session" {
  @vfs.with_tmpdir(prefix="openseek-tui-continue-", root => {
    @vfs.with_tmpdir(prefix="openseek-tui-continue-empty-", empty_root => {
      let store = @store.SessionStore(root)
      store.create(Session(SessionId("older"), system_prompt="system"))
      // Filesystem mtimes need a beat between writes to order reliably.
      @async.sleep(50)
      store.create(Session(SessionId("newer"), system_prompt="system"))
      let parsed = cli_command().parse(
        argv=["--continue", "--session-root", root],
        env={ "DEEPSEEK": "test-key" },
      )
      let config = with_latest_session(parse_config(parsed))
      assert_eq(config.session_id.value(), "newer")
      // An empty store keeps the generated fresh session: nothing to continue,
      // so the TUI starts a new conversation instead of refusing to launch.
      let parsed = cli_command().parse(
        argv=["--continue", "--session-root", empty_root],
        env={ "DEEPSEEK": "test-key" },
      )
      let fresh = with_latest_session(parse_config(parsed))
      assert_true(fresh.session_id.value().has_prefix("tui-"))
    })
  })
}

///|
async test "resume completion items list durable sessions" {
  @vfs.with_tmpdir(prefix="openseek-tui-resume-completion-", root => {
    let store = @store.SessionStore(root)
    store.create(Session(SessionId("demo"), system_prompt="system"))
    let parsed = cli_command().parse(argv=["--session-root", root], env={
      "DEEPSEEK": "test-key",
    })
    let items = resume_completion_items(parse_config(parsed))
    guard items is [item] else { fail("expected one resume completion") }
    assert_eq(item.label(), "demo")
    assert_eq(item.insert_text(), "demo")
    assert_eq(item.description(), "session")
  })
}
