// The pump that owns every PTY child: spawned in the host services' task
// group (like the LSP and watcher pumps), it consumes `open_terminal`
// requests and runs one task per session. The connection owner shuts down the
// terminal state before its group ends, waking this pump and closing every
// session; each session's `defer` then releases its PTY.

///|
/// Read PTY output in chunks this large; a typical child burst fits in one.
const ReadChunkBytes = 16384

///|
/// Run terminal sessions until the state shuts down or this task is cancelled,
/// forwarding every session's pushes through `emit`.
pub async fn run_terminal_pump(
  state : TerminalState,
  emit : async (TerminalPush) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    for ;; {
      let request = state.requests.get() catch {
        TerminalPumpClosed => return
        error => raise error
      }
      group.spawn_bg(allow_failure=true, () => run_session(state, request, emit))
    }
  })
}

///|
/// One session's lifetime: spawn the PTY child, answer the opener, then loop
/// reading output until the child exits (or `close_terminal` requests it),
/// pausing whenever the flow-control debt passes the high watermark.
async fn run_session(
  state : TerminalState,
  request : OpenRequest,
  emit : async (TerminalPush) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    if request.connection_generation != state.connection_generation {
      let message = if state.closed {
        "terminal service is closed"
      } else {
        "terminal open was cancelled by reconnect"
      }
      request.reply.put(Err(message))
      return
    }
    let pty = @pty.spawn(
      group,
      request.argv,
      // pty 0.2.3 applies the working directory in the platform spawn call,
      // so neither POSIX nor Windows needs a shell command that performs cd.
      cwd=request.cwd,
      cols=request.cols,
      rows=request.rows,
    ) catch {
      error if @async.is_being_cancelled() => raise error
      error => {
        request.reply.put(Err(@debug.render(Repr(error))))
        return
      }
    }
    // Spawning suspends, so a reconnect can invalidate the request while the
    // child is being created. Close it before publishing a stale session.
    if request.connection_generation != state.connection_generation {
      let message = if state.closed {
        "terminal service is closed"
      } else {
        "terminal open was cancelled by reconnect"
      }
      request.reply.put(Err(message))
      pty.close()
      return
    }
    let session : TerminalSession = {
      pty,
      unacked: 0,
      unacked_chunks: Map([]),
      next_output_sequence: 1,
      cond: Cond(),
      close_requested: Queue(kind=Blocking(1)),
      closing: false,
    }
    state.sessions[request.id] = session
    defer {
      state.sessions.remove(request.id)
      pty.close()
    }
    // `Pty::cancel` uses the process package's five-second graceful timeout on
    // Unix. A terminal close is an explicit immediate operation, so a
    // session-owned task applies the cross-platform hard cancellation handler
    // while the normal reader and waiter continue to drain and reap the child.
    group.spawn_bg(no_wait=true, () => {
      session.close_requested.get()
      let cancel = @process.hard_cancel()
      cancel(pty.pid())
    })
    request.reply.put(Ok(()))
    @xlog.debug() <?
      {
        "event": "terminal_spawn",
        "id": request.id,
        "pid": pty.pid(),
        "argv0": request.argv.get(0).unwrap_or(""),
        // The directory passed directly to the platform process spawn.
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
      let sequence = session.next_output_sequence
      session.next_output_sequence = sequence + 1
      // Record the debt before emitting: the webview can acknowledge as soon
      // as it receives the event, including before this task resumes.
      session.unacked_chunks[sequence] = n
      session.unacked += n
      emit(Output(id=request.id, sequence~, data=Bytes::from_array(buf[:n])))
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
/// Build the argv for a Windows session: the requested command when present,
/// or the system command interpreter from `%COMSPEC%`.
#cfg(platform="windows")
fn session_argv(command? : Array[String]) -> Array[String] raise TerminalError {
  if command is Some(argv) {
    guard !argv.is_empty() else {
      raise TerminalError("terminal command must not be empty")
    }
    return argv
  }
  [@env.get("COMSPEC").unwrap_or("cmd.exe")]
}

///|
/// Build the argv for a POSIX session: the requested command when present,
/// or the user's login shell with the terminal emulator capabilities set.
/// `/usr/bin/env` execs the shell directly without a quoting or `cd` script.
#cfg(not(platform="windows"))
fn session_argv(command? : Array[String]) -> Array[String] raise TerminalError {
  if command is Some(argv) {
    guard !argv.is_empty() else {
      raise TerminalError("terminal command must not be empty")
    }
    return argv
  }
  let shell = @env.get("SHELL").unwrap_or("/bin/sh")
  ["/usr/bin/env", "TERM=xterm-256color", "COLORTERM=truecolor", shell, "-l"]
}
