///|
async fn main {
  // Hidden probe target: the login-shell environment probe re-execs this
  // binary through the user's shell; print the marker-wrapped JSON
  // environment and quit before any logging or CEF setup.
  if @env.args() is [_, "--print-env-json", mark, ..] {
    @shellenv.print_env_json(mark)
    return
  }
  // Proton runs everything in one process; the executable path locates the
  // bundled frontend assets and the engine binary that ship alongside it.
  let executable = match @env.args().get(0) {
    Some(command) => command
    None => abort("current executable command is unavailable")
  }
  let log = launch_logger()
  log.info() <? { "message": "start" }
  // A Finder/Dock launch inherits only launchd's minimal environment; graft
  // the user's login-shell environment (PATH, custom variables) onto this
  // process before anything downstream — engine, LSP, shell tool — spawns.
  @shellenv.apply_login_shell_env(executable, log)
  let frontend_entry = @host.frontend_entry_path(executable)
  let engine = @engine.engine_command(executable)
  log.info() <? { "message": "host process start" }
  log.info() <? { "message": "frontend entry", "path": frontend_entry }
  log.info() <? { "message": "engine", "path": engine }
  let runtime_dir = @host.prepared_runtime_dir()
  let state = @api.ApiState::new(engine~, runtime_dir?, executable~, on_finished=payload => {
    notify_run_finished(payload)
  })
  let bridge = @extension.DesktopBridgeActor::new(state)
  // Proton exposes the `__MoonBit__` bridge — both the ops and the event
  // channel the frontend listens on — only to the `proton://app/` origin its
  // asset entry serves from. The window is bridge-only: it makes no HTTP
  // requests at all (a proton:// page's http fetches stall inside CEF's
  // network service). Remote browsers use the same method catalog over the
  // relay WebSocket instead (docs/remote-protocol.md).
  let app = @proton.asset(
      "OpenSeek Desktop",
      frontend_entry,
      width=1120,
      height=760,
    )
    .debug_level(1)
    .extension(
      @proton_extension.from_command_spec(
        @extension.openseek_extension(state, bridge),
      ),
    )
  @async.with_task_group(group => {
    // The bridge actor, engine actor, and host actors run for the app's
    // lifetime — they feed every page/client rather than borrowing a
    // `host.connect` request task as their owner.
    group.spawn_bg(allow_failure=true, () => bridge.run())
    group.spawn_bg(allow_failure=true, () => {
      state.engine_actor().run(state.sink(), message => {
        state.publish("agent.error", { "message": Json::string(message) })
      })
    })
    @host.spawn_host_pumps(group, state.host_state(), (method_, params) => {
      state.publish(method_, params)
    })
    // Remote access is opt-in: point the host at a relay through the
    // environment and it registers itself at startup.
    if relay_settings() is Some((relay_url, device_token, device_name)) {
      let relay = @remote.RelayActor::new(
        state,
        relay_url~,
        device_token~,
        device_name~,
        announce=device => {
          log.info() <? { "message": "relay registered", "device": device }
        },
      )
      group.spawn_bg(allow_failure=true, () => {
        relay.run()
      })
    }
    match app.run() {
      Ok(_) => log.info() <? { "message": "host process exit ok" }
      Err(error) =>
        log.error() <? { "message": "host process error", "error": error }
    }
    // The window is closed: tear the pumps (and with them every serve
    // engine) down rather than wait on their tasks forever.
    group.return_immediately(())
  })
  // A successful `update.apply` swapped the bundle on disk and left a
  // relaunch marker: reopen the new version now that the run loop is done.
  // `open -n` hands the launch to LaunchServices, so the new instance is
  // not our child and this process can exit right after.
  if runtime_dir is Some(dir) &&
    @update.take_relaunch_target(work_dir=dir.to_string()) is Some(target) {
    log.info() <? { "message": "relaunch after update", "path": target }
    let code = @process.run("open", ["-n", target]) catch {
      error => {
        log.error() <? { "message": "relaunch failed", "error": "\{error}" }
        return
      }
    }
    if code != 0 {
      log.error() <? { "message": "relaunch failed", "code": code }
    }
  }
}

///|
/// The relay connection settings, all-or-nothing from the environment:
/// `OPENSEEK_RELAY_URL` (the relay's `/tunnel` WebSocket URL) and
/// `OPENSEEK_DEVICE_TOKEN` (the secret that keeps this machine's device id
/// stable); `OPENSEEK_DEVICE_NAME` labels the device on the relay's status
/// page and defaults to "desktop".
fn relay_settings() -> (String, String, String)? {
  guard @envx.get("OPENSEEK_RELAY_URL") is Some(relay_url) &&
    @envx.get("OPENSEEK_DEVICE_TOKEN") is Some(device_token) else {
    return None
  }
  let device_name = match @envx.get("OPENSEEK_DEVICE_NAME") {
    Some(name) => name
    None => "desktop"
  }
  Some((relay_url, device_token, device_name))
}
