// Where a conversation's durable record lives: the session store root shared
// with the CLI/TUI.

///|
/// Where durable sessions live when a run names a session: the payload's
/// explicit root, then the OPENSEEK_SESSION_ROOT environment, then a stable
/// absolute default under the user's home directory. The absolute fallback
/// matters because a packaged app can run with `/` as its working directory,
/// where the engine's relative `.openseek` default could never be created.
fn resolved_session_root(payload_root? : @pathx.Path) -> @pathx.Path? {
  if payload_root is Some(root) {
    return Some(root.resolve().to_path())
  }
  if @env.get("OPENSEEK_SESSION_ROOT") is Some(root) {
    return Some(@pathx.Path(root).resolve().to_path())
  }
  home_session_root()
}

///|
fn home_session_root() -> @pathx.Path? {
  guard @home.dir() is Some(home) else { return None }
  // The session subsystem's filesystem interfaces still accept `Path`, so
  // forget the classification only after resolving the home-derived root.
  Some(home.join(".openseek").resolve().to_path())
}

// Tests for resolving explicit durable-session roots before the host shares
// them with engine processes and one-shot session queries.

///|
test "explicit relative session roots resolve against the host cwd" {
  let root = @pathx.Path(".openseek-test-root")
  let expected = root.resolve()
  guard resolved_session_root(payload_root=root) is Some(actual) else {
    fail("expected session root")
  }
  assert_eq(actual, expected.to_path())
}

///|
test "explicit absolute session roots are normalized" {
  let root = @pathx.Path(".openseek-test-root").resolve().join("..")
  let expected = root.normalize()
  guard resolved_session_root(payload_root=root.to_path()) is Some(actual) else {
    fail("expected session root")
  }
  assert_eq(actual, expected.to_path())
}
