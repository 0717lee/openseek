// Opening a transcript-referenced file in the user's system: the host makes
// the path absolute against the conversation's working directory and hands it
// to the platform's default "open" command, which routes the file to whatever
// app the user has associated with it. The agent surfaced the path and the
// user clicked it, so there is no workspace-containment check.

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
  let code = @platform.open_path(target.0) catch {
    error if @async.is_being_cancelled() => raise error
    error => raise HostError("Could not open \{target.0}: \{error}")
  }
  guard code == 0 else { raise HostError("Could not open \{target.0}") }
  PathOpened
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
