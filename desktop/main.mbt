///|
fn main {
  // Hidden probe target: the login-shell environment probe re-execs this
  // binary through the user's shell; print the marker-wrapped JSON
  // environment and quit before any logging or CEF setup.
  if @env.args() is [_, "--print-env-json", mark, ..] {
    @shellenv.print_env_json(mark)
    return
  }
  // The process main thread now owns AppKit and CEF. Proton runs this async
  // body on its application thread and marshals UI work back to the main
  // thread, so native shutdown cannot race a still-open browser window.
  @proton.run(() => {
    // Proton runs everything in one process; the executable path locates the
    // bundled frontend assets and the engine binary that ship alongside it.
    let executable = match @env.args().get(0) {
      Some(command) => command
      None => abort("current executable command is unavailable")
    }
    let log = launch_logger()
    log.info() <?
      {
        "event": "desktop_main_start",
        "message": "start",
        "log_path": @env.get_env_var("OPENSEEK_DESKTOP_LOG").unwrap_or(""),
      }
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
    // The relay sign-in store: a persisted session from auth.json, unless the
    // environment override pins the connector config directly (development).
    let auth = @auth.AuthStore::load(
      runtime_dir?,
      env_override?=relay_settings(),
    )
    let state = @api.ApiState::new(engine~, runtime_dir?, executable~, auth~)
    let relay = @remote.RelayActor::new(state, announce=device => {
      log.info() <? { "message": "relay registered", "device": device }
    })
    // The window is an ordinary page against the host's own loopback origin:
    // the frontend bundle over http://127.0.0.1 and one JSON-RPC WebSocket —
    // the same catalog, envelope, and delivery profile a relay browser gets
    // (docs/remote-protocol.md). The launch token minted here is the
    // WebSocket's capability; it rides the entry URL's query string.
    guard @entropy.random_hex(32) is Some(token) else {
      // No OS entropy is a hard failure, never weak randomness.
      abort("no OS entropy available for the desktop transport token")
    }
    let extras : @remote.LocalExtras = {
      show_notification: (title, body, payload) => {
        // A missing native backend or denied permission stays silent: the
        // transcript remains the authoritative result.
        @proton_native.notification_show(title, body, payload?) catch {
          _ => ()
        }
      },
    }
    let preferred_port = match runtime_dir {
      Some(dir) => @host.load_local_http_port(dir)
      None => None
    }
    let local_server = @remote.LocalServer::start(
      state,
      asset_dir=@host.frontend_asset_dir(frontend_entry),
      token~,
      extras~,
      preferred_port?,
    )
    if runtime_dir is Some(dir) && preferred_port != Some(local_server.port()) {
      @host.save_local_http_port(dir, local_server.port())
    }
    log.info() <? { "message": "local origin", "port": local_server.port() }
    let app = @proton.url(
      "SeekMoon",
      local_server.entry_url(),
      width=1120,
      height=760,
    ).debug_level(1)
    @async.with_task_group(group => {
      // The engine actor and host actors run for the app's lifetime — they
      // feed every client rather than borrowing a request task as their
      // owner. The local server owns the window's origin for the same span.
      group.spawn_bg(allow_failure=true, () => local_server.run())
      group.spawn_bg(allow_failure=true, () => {
        state
        .engine_actor()
        .run(state.sink(), message => {
          state.publish("agent.error", { "message": Json::string(message) })
        })
      })
      @host.spawn_host_pumps(group, state.host_state(), (method_, params) => {
        state.publish(method_, params)
      })
      // The relay actor runs for the app's lifetime: it registers
      // this host whenever a sign-in (or the environment override) says so,
      // and idles otherwise.
      group.spawn_bg(allow_failure=true, () => relay.run())
      // System-notification clicks surface from the native queue; the hub
      // routes them, and the delivery profile hands them only to the
      // loopback window.
      group.spawn_bg(allow_failure=true, () => notification_click_pump(state))
      log.info() <? { "event": "desktop_app_run_start" }
      try {
        app.run()
        log.info() <?
          {
            "event": "desktop_app_run_return",
            "result": "ok",
            "message": "host process exit ok",
          }
      } catch {
        error =>
          log.error() <?
            {
              "event": "desktop_app_run_return",
              "result": "error",
              "message": "host process error",
              "error": @debug.render(Repr(error)),
            }
      }
      @proton_native.notification_cleanup() catch {
        _ => ()
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
    log.info() <? { "event": "desktop_main_return" }
  })
}

///|
/// How often the native notification-click queue is drained. Banner clicks
/// are human-speed; a quarter second keeps the jump feeling immediate.
const NotificationClickPollMs = 250

///|
/// Surface native notification activations as the `notification.click`
/// notification, carrying the opaque payload the poster stamped (the run
/// id). Poll errors are ignored: a broken native queue must not take the
/// host down, and the transcript remains the authoritative result.
async fn notification_click_pump(state : @api.ApiState) -> Unit {
  for ;; {
    @async.sleep(NotificationClickPollMs)
    for ;; {
      let click = @proton_native.notification_poll_click() catch { _ => None }
      guard click is Some(click) else { break }
      if click.payload is Some(payload) {
        state.publish("notification.click", { "payload": Json::string(payload) })
      }
    }
  }
}

///|
/// The development relay override, all-or-nothing from the environment:
/// `OPENSEEK_RELAY_URL` (the relay's `/v1/tunnel` WebSocket URL) and
/// `OPENSEEK_DEVICE_TOKEN` (the secret that keeps this machine's device id
/// stable); `OPENSEEK_DEVICE_NAME` labels the device on the relay's status
/// page and defaults to "desktop". When set it bypasses sign-in entirely.
fn relay_settings() -> @auth.ConnectorConfig? {
  guard @envx.get("OPENSEEK_RELAY_URL") is Some(relay_url) &&
    @envx.get("OPENSEEK_DEVICE_TOKEN") is Some(device_token) else {
    return None
  }
  let device_name = match @envx.get("OPENSEEK_DEVICE_NAME") {
    Some(name) => name
    None => "desktop"
  }
  Some({ relay_url, device_token, device_name })
}
