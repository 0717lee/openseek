// Opening a transcript-referenced file: the host makes the path absolute
// against the conversation's working directory, then either hands an ordinary
// path to the platform opener or resolves a conservative `:line[:column]` or
// `#Lline` reference for the built-in editor. The agent surfaced the path and
// the user clicked it, so ordinary system-open paths have no containment.

///|
async fn open_path_op(payload : OpenPathPayload) -> OpenPathReply {
  // A live run hands us its cwd; a resumed conversation has none, so fall back
  // to the directory the session's engine runs in.
  let base = match payload.cwd {
    Some(cwd) => {
      guard @pathx.Absolute::from_uri_path(cwd) is Some(cwd) else {
        raise HostError("Invalid working directory")
      }
      Some(cwd)
    }
    None => @engine.session_cwd(payload.session)
  }
  let target = @engine.open_target(
    base,
    @pathx.Path(payload.path).expand_home(),
  )
  guard !target.0.is_empty() else { raise HostError("Empty path") }
  let resolution = @openpath.Reference(target.0).resolve()
  if resolution is EditorPath(path~, line~, column~) {
    // The built-in editor is checkout-rooted. Return the relative path we
    // already proved belongs to this exact cwd instead of making the frontend
    // rediscover the root from its cached conversation state. A resumed
    // frontend can know the project workspace while not retaining the last
    // run's cwd; returning the absolute path in that case would make it open
    // `.worktrees/<name>/...` relative to the worktree a second time.
    //
    // A suffix-free file outside the conversation cwd still opens through the
    // system, just without a line reveal that the platform opener cannot
    // express.
    if base is Some(root) &&
      @pathx.Path(path).to_absolute() is Some(absolute) &&
      absolute.relative_to(root~) is Some(relative) &&
      !relative.is_root() {
      return {
        opened: false,
        editor_target: Some({ path: relative.0, line, column }),
      }
    }
  }
  let system_path = match resolution {
    SystemPath(path) => path
    EditorPath(path~, ..) => path
  }
  let code = @platform.open_path(system_path) catch {
    error if @async.is_being_cancelled() => raise error
    error => raise HostError("Could not open \{system_path}: \{error}")
  }
  guard code == 0 else { raise HostError("Could not open \{system_path}") }
  { opened: true, editor_target: None }
}

///|
async test "open_path returns workspace editor positions without a system open" {
  let dir = "_build/host-open-path-editor-test"
  if @fs.exists(dir) {
    @fs.rmdir(dir, recursive=true)
  }
  @fs.mkdir(dir, recursive=true)
  let file = "\{dir}/source.mbt"
  @fs.write_file(file, "fn main {}", create_mode=CreateOrTruncate)
  let cwd = @pathx.Path(@fs.realpath(dir))
    .to_absolute()
    .unwrap()
    .to_uri_path()
    .unwrap()
  let reply = open_path_op({
    session: "unused-for-explicit-cwd",
    cwd: Some(cwd),
    path: "source.mbt:2738:17",
  })
  assert_eq(reply, {
    opened: false,
    editor_target: Some({ path: "source.mbt", line: 2738, column: Some(17) }),
  })
  let fragment_reply = open_path_op({
    session: "unused-for-explicit-cwd",
    cwd: Some(cwd),
    path: "source.mbt#L5",
  })
  assert_eq(fragment_reply, {
    opened: false,
    editor_target: Some({ path: "source.mbt", line: 5, column: None }),
  })
}

///|
/// Expand a leading `~` (the agent often writes paths home-relative) to the
/// user's home directory; other paths pass through for `open_target` to take
/// against the working directory. Keeping this on `Path` preserves the
/// unclassified input until `open_target` decides whether it is absolute.
fn @pathx.Path::expand_home(self : @pathx.Path) -> @pathx.Path {
  if self.0 == "~" && @home.dir() is Some(home) {
    home
  } else if self.0.strip_prefix("~/") is Some(rest) && @home.dir() is Some(home) {
    home.join(Relative(rest.to_owned()))
  } else {
    self
  }
}
