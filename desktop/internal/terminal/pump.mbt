// The pump that owns every PTY child: spawned in the `connect` op's task
// group (like the LSP and watcher pumps), it consumes `open_terminal`
// requests and runs one task per session. Webview disconnect cancels the
// group, which cancels every session task; each task's `defer` then releases
// its PTY, so no child outlives the connection.

///|
/// Read PTY output in chunks this large; a typical child burst fits in one.
const ReadChunkBytes = 16384

///|
/// Run terminal sessions until cancelled, forwarding every session's pushes
/// through `emit`.
pub async fn run_terminal_pump(
  state : TerminalState,
  emit : async (TerminalPush) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    for ;; {
      let request = state.requests.get()
      group.spawn_bg(allow_failure=true, () => run_session(state, request, emit))
    }
  })
}

///|
/// One session's lifetime: spawn the PTY child, answer the opener, then loop
/// reading output until the child exits (or `close_terminal` cancels it),
/// pausing whenever the flow-control debt passes the high watermark.
async fn run_session(
  state : TerminalState,
  request : OpenRequest,
  emit : async (TerminalPush) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    let pty = @pty.spawn(
      group,
      request.argv,
      cols=request.cols,
      rows=request.rows,
    ) catch {
      error if @async.is_being_cancelled() => raise error
      error => {
        request.reply.put(Err(@debug.render(Repr(error))))
        return
      }
    }
    let session : TerminalSession = {
      pty,
      unacked: 0,
      cond: Cond(),
      closing: false,
    }
    state.sessions[request.id] = session
    defer {
      state.sessions.remove(request.id)
      pty.close()
    }
    request.reply.put(Ok(()))
    @xlog.debug() <?
      {
        "event": "terminal_spawn",
        "id": request.id,
        "pid": pty.pid(),
        "argv0": request.argv.get(0).unwrap_or(""),
        // The launcher's `cd` target: a session that dies immediately with
        // status 1 failed exactly here.
        "cwd": request.cwd,
      }
    let reader = pty.reader()
    let buf : FixedArray[Byte] = FixedArray::make(ReadChunkBytes, b'\x00')
    for ;; {
      // A closed master reports the child's exit as EIO on macOS rather
      // than a clean EOF; both end the session the same way.
      let n = reader.read(buf) catch {
        error if @async.is_being_cancelled() => raise error
        _ => 0
      }
      if n <= 0 {
        break
      }
      emit(Output(id=request.id, data=Bytes::from_array(buf[:n])))
      session.unacked += n
      while session.unacked >= HighWatermark && !session.closing {
        session.cond.wait()
      }
    }
    let code = pty.wait() catch {
      error if @async.is_being_cancelled() => raise error
      _ => -1
    }
    @xlog.debug() <?
      { "event": "terminal_exit", "id": request.id, "code": code }
    emit(Exited(id=request.id, code~))
  })
}

///|
/// The POSIX launcher: enter the workspace, advertise the emulator's
/// capabilities, then become the requested program. Argument passing keeps
/// the working directory and command out of shell-quoting territory.
const UnixLaunchScript = "cd \"$1\" || exit 1\nexport TERM=xterm-256color COLORTERM=truecolor\nshift\nexec \"$@\""

///|
/// Build the argv for a session in `cwd`: the user's login shell by default,
/// or `command` when given.
fn session_argv(
  cwd : String,
  command? : Array[String],
) -> Array[String] raise TerminalError {
  if @env.get("OS") is Some("Windows_NT") {
    // Best-effort Windows path (untested here): ConPTY inherits the host's
    // working directory, so the session enters the workspace itself.
    guard command is None else {
      raise TerminalError(
        "custom terminal commands are not supported on Windows yet",
      )
    }
    return [
      "powershell.exe",
      "-NoLogo",
      "-NoExit",
      "-Command",
      "Set-Location -LiteralPath \"" + cwd + "\"",
    ]
  }
  let launch = if command is Some(argv) {
    guard !argv.is_empty() else {
      raise TerminalError("terminal command must not be empty")
    }
    argv
  } else {
    let shell = @env.get("SHELL").unwrap_or("/bin/sh")
    [shell, "-l"]
  }
  ["/bin/sh", "-c", UnixLaunchScript, "sh", cwd, ..launch]
}
