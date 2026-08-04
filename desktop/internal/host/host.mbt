// The package's public face: the transport-agnostic host ops — everything
// the desktop host offers a client beyond the engine itself (file browsing,
// language services, skills, self-update, app launching) — dispatched by
// method name. The method names and payload shapes are the wire catalog of
// docs/remote-protocol.md, shared verbatim by the proton bridge and the
// remote WebSocket.

///|
/// A host-side failure with a user-facing message. Ops raise it; the
/// transport boundary stringifies it into the error the client displays.
pub(all) suberror HostError {
  HostError(String)
}

///|
impl Show for HostError with fn output(self, logger) {
  match self {
    HostError(message) => logger.write_string(message)
  }
}

///|
/// A request payload that failed to decode — the client sent a shape the
/// method does not accept. Kept apart from `HostError` so transports can
/// report it as a malformed request (JSON-RPC -32602) rather than a failed
/// operation.
pub(all) suberror PayloadError {
  PayloadError(String)
}

///|
impl Show for PayloadError with fn output(self, logger) {
  match self {
    PayloadError(message) => logger.write_string(message)
  }
}

///|
/// The host ops' process-wide state: the language-server pool and the
/// self-update staging state. Filesystem watches are connection-owned below,
/// because two clients may watch different workspaces at the same time.
struct HostState {
  engine : String
  runtime_dir : @path.Path?
  lsp : LspPoolActor
  updates : SelfUpdate
}

///|
/// State owned by one client connection. A desktop page and each remote
/// WebSocket create separate values, so filesystem watches and PTY sessions
/// cannot leak into another client.
struct HostConnection {
  fs_watch : FsWatchActor
  terminal : @terminal.TerminalState
}

///|
pub fn HostConnection::new() -> HostConnection {
  { fs_watch: FsWatchActor::new(), terminal: @terminal.new_terminal_state() }
}

///|
/// `engine` is the engine executable (the LSP pool spawns the bundled
/// `moon-lsp` resolved next to it); `executable` is the host's own binary,
/// which self-update uses to locate the running .app bundle (absent or
/// non-bundle layouts only lose the in-app install, never the announcement).
pub fn new_host_state(
  engine : String,
  runtime_dir? : @path.Path,
  executable? : String,
) -> HostState {
  let lsp = LspPoolActor::new(engine, runtime_dir?)
  // Mirror LSP wire traffic to its own log next to the host's runtime
  // state, so a broken hover/symbol round-trip can be read back without the
  // per-message noise landing in the main app log.
  if runtime_dir is Some(dir) {
    @lsp.enable_traffic_log(dir.join("lsp.log").to_string())
  }
  {
    engine,
    runtime_dir,
    lsp,
    updates: SelfUpdate::new(runtime_dir, executable),
  }
}

///|
/// The background tasks behind the host ops, spawned into the caller's
/// app-lifetime task group: the LSP pool actor, diagnostics forwarder, and the
/// self-update pump with its startup leftover sweep. These are shared by every
/// connection;
/// connection-owned filesystem watcher tasks start in `HostConnection::run`.
/// Every background task is best-effort: a language-service hiccup degrades
/// that feature, never the connection.
pub fn[G] spawn_host_pumps(
  group : @async.TaskGroup[G],
  state : HostState,
  emit : async (String, Json) -> Unit,
) -> Unit {
  group.spawn_bg(allow_failure=true, () => state.lsp.run())
  group.spawn_bg(allow_failure=true, () => {
    state.lsp.forward_diagnostics(async fn(push) {
      emit("lsp.diagnostics", ToJson::to_json(push))
    })
  })
  group.spawn_bg(allow_failure=true, () => state.updates.run(emit))
}

///|
/// Run the filesystem watcher and PTY pump owned by this connection. Their
/// notifications return only to the same transport instead of entering the
/// process-wide hub.
pub async fn HostConnection::run(
  self : HostConnection,
  emit : async (String, Json) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    group.spawn_bg(allow_failure=true, () => {
      @terminal.run_terminal_pump(self.terminal, async fn(push) {
        match push {
          Output(id~, sequence~, data~) => {
            let payload : TerminalOutputPayload = {
              id,
              sequence,
              data: @base64.encode(data),
            }
            emit("terminal.output", ToJson::to_json(payload))
          }
          Exited(id~, code~) => {
            let payload : TerminalExitPayload = { id, code }
            emit("terminal.exit", ToJson::to_json(payload))
          }
        }
      })
    })
    self.fs_watch.run(async fn(push) {
      emit("fs.changed", ToJson::to_json(push))
    })
  })
}

///|
/// A desktop page reload cannot reclaim its old emulator instances. Retire
/// those PTYs before attaching the new page; WebSocket-owned sessions are
/// cancelled automatically with their connection task group.
pub fn HostConnection::close_terminals(self : HostConnection) -> Unit {
  @terminal.close_all_terminals(self.terminal)
}

///|
fn[T : @json.FromJson] decode_payload(payload : Json) -> T raise {
  @json.from_json(payload) catch {
    _ => raise PayloadError("malformed request payload")
  }
}

///|
/// Dispatch one host method by its catalog name, returning its JSON reply —
/// or None for a name this host does not know, which the transport reports
/// as an unknown method rather than a failed op. `publish` sends shared
/// invalidations whose filesystem change must stay coupled to its notification.
pub async fn host_op(
  state : HostState,
  connection : HostConnection,
  op : String,
  payload : Json,
  publish : (String, Json) -> Unit,
) -> Json? {
  match op {
    "skills.catalog" => Some(ToJson::to_json(skills_catalog_op()))
    "skills.install" =>
      Some(
        ToJson::to_json(
          install_skill_op(decode_payload(payload), () => {
            publish("skills.changed", Json::empty_object())
          }),
        ),
      )
    "skills.installed" => Some(ToJson::to_json(installed_skills_op()))
    "skills.uninstall" =>
      Some(
        ToJson::to_json(
          uninstall_skill_op(decode_payload(payload), () => {
            publish("skills.changed", Json::empty_object())
          }),
        ),
      )
    "host.open_path" =>
      Some(ToJson::to_json(open_path_op(decode_payload(payload))))
    "update.check" =>
      Some(ToJson::to_json(state.updates.check(decode_payload(payload))))
    "update.download" =>
      Some(
        ToJson::to_json(state.updates.start_download(decode_payload(payload))),
      )
    "update.apply" => Some(ToJson::to_json(state.updates.apply()))
    "git.branch" =>
      Some(ToJson::to_json(git_branch_op(decode_payload(payload))))
    "app.list" => Some(ToJson::to_json(list_apps_op()))
    "app.launch" =>
      Some(ToJson::to_json(launch_app_op(decode_payload(payload))))
    "fs.read_directory" =>
      Some(ToJson::to_json(read_directory_op(decode_payload(payload))))
    "fs.list_files" =>
      Some(ToJson::to_json(list_files_op(decode_payload(payload))))
    "fs.read_file" =>
      Some(ToJson::to_json(read_file_op(decode_payload(payload))))
    "fs.stat_files" =>
      Some(ToJson::to_json(stat_files_op(decode_payload(payload))))
    "fs.watch" => {
      connection.fs_watch.watch(decode_payload(payload))
      Some(Json::empty_object())
    }
    "fs.unwatch" => {
      connection.fs_watch.unwatch()
      Some(Json::empty_object())
    }
    "terminal.open" =>
      Some(
        ToJson::to_json(
          terminal_open_op(connection.terminal, decode_payload(payload)),
        ),
      )
    "terminal.input" => {
      terminal_input_op(connection.terminal, decode_payload(payload))
      Some(Json::empty_object())
    }
    "terminal.resize" => {
      terminal_resize_op(connection.terminal, decode_payload(payload))
      Some(Json::empty_object())
    }
    "terminal.ack" => {
      terminal_ack_op(connection.terminal, decode_payload(payload))
      Some(Json::empty_object())
    }
    "terminal.close" => {
      terminal_close_op(connection.terminal, decode_payload(payload))
      Some(Json::empty_object())
    }
    "lsp.hover" =>
      Some(ToJson::to_json(lsp_hover_op(state.lsp, decode_payload(payload))))
    "lsp.open" =>
      Some(ToJson::to_json(lsp_open_op(state.lsp, decode_payload(payload))))
    "lsp.workspace_symbols" =>
      Some(
        ToJson::to_json(
          workspace_symbols_op(state.lsp, decode_payload(payload)),
        ),
      )
    "moonide.definition" =>
      Some(
        ToJson::to_json(moonide_definition_op(state, decode_payload(payload))),
      )
    "moonide.references" =>
      Some(
        ToJson::to_json(moonide_references_op(state, decode_payload(payload))),
      )
    "fs.browse" =>
      Some(ToJson::to_json(browse_directory_op(decode_payload(payload))))
    _ => None
  }
}

///|
/// Every host method name, in catalog order — the transport adapters
/// register or advertise exactly this set.
pub fn host_method_names() -> Array[String] {
  [
    "fs.read_file", "fs.read_directory", "fs.list_files", "fs.stat_files", "fs.watch",
    "fs.unwatch", "fs.browse", "terminal.open", "terminal.input", "terminal.resize",
    "terminal.ack", "terminal.close", "lsp.open", "lsp.hover", "lsp.workspace_symbols",
    "moonide.definition", "moonide.references", "skills.catalog", "skills.installed",
    "skills.install", "skills.uninstall", "update.check", "update.download", "update.apply",
    "app.list", "app.launch", "git.branch", "host.open_path",
  ]
}

///|
test "host catalog advertises the complete terminal surface" {
  let methods = host_method_names()
  for
    method_ in [
      "terminal.open", "terminal.input", "terminal.resize", "terminal.ack", "terminal.close",
    ] {
    assert_true(methods.contains(method_))
  }
}

///|
test "host catalog advertises Moon IDE navigation" {
  let methods = host_method_names()
  assert_true(methods.contains("moonide.definition"))
  assert_true(methods.contains("moonide.references"))
}
