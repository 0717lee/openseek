///|
/// A command handler chooses its concrete failed reply before the transport
/// encodes it; Endpoint does not need to know that reply's error constructor.
async test "remote endpoint preserves handler-owned failed replies" {
  let endpoint = @endpoint.Endpoint::remote(@commands.settings_get, async fn(
    _,
  ) {
    @async.sleep(0)
    SettingsError("handler exploded")
  })
  let json = endpoint.invoke_remote({})
  let response : @protocol.SettingsStatusReply = @json.from_json(json)
  guard response is SettingsError(message) else {
    fail("expected an explicit failed reply")
  }
  assert_true(message.contains("handler exploded"))
}

///|
/// Successful replies keep using the command's concrete reply codec.
async test "remote endpoint preserves successful typed replies" {
  let endpoint = @endpoint.Endpoint::remote_sync(@commands.fs_unwatch, _ => {
    FileWatchStopped
  })
  let json = endpoint.invoke_remote({})
  let response : @protocol.UnwatchReply = @json.from_json(json)
  assert_eq(response, FileWatchStopped)
}

///|
/// A command reply names its outcome directly without a generic success
/// wrapper or a third type parameter on Command.
async test "remote endpoint preserves a semantic command reply" {
  let endpoint = @endpoint.Endpoint::remote_sync(@commands.app_info, _ => {
    AppInfo(version="test-version")
  })
  let json = endpoint.invoke_remote({})
  let response : @protocol.AppInfoReply = @json.from_json(json)
  let AppInfo(version~) = response
  assert_eq(version, "test-version")
}

///|
/// Commands that already had an error variant choose it in their own handler
/// instead of asking Endpoint to infer it.
async test "remote endpoint reuses an existing command error variant" {
  let endpoint = @endpoint.Endpoint::remote(@commands.workspace_list, async fn(
    _,
  ) -> @protocol.WorkspacesReply {
    @async.sleep(0)
    WorkspaceError("workspace registry unavailable")
  })
  let json = endpoint.invoke_remote({})
  let response : @protocol.WorkspacesReply = @json.from_json(json)
  guard response is WorkspaceError(message) else {
    fail("expected the existing workspace error variant")
  }
  assert_true(message.contains("workspace registry unavailable"))
}

///|
/// `update.check` already distinguishes an unreachable host, so its handler
/// returns that branch rather than adding `Failed`.
async test "remote endpoint reuses an existing update error variant" {
  let endpoint = @endpoint.Endpoint::remote(@commands.update_check, async fn(
    _,
  ) -> @protocol.CheckUpdateReply {
    @async.sleep(0)
    Unreachable(reason="update service unavailable")
  })
  let json = endpoint.invoke_remote({})
  let response : @protocol.CheckUpdateReply = @json.from_json(json)
  guard response is Unreachable(reason~) else {
    fail("expected the existing unreachable variant")
  }
  assert_true(reason.contains("update service unavailable"))
}
