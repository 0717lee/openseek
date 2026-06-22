///|
/// One decoded command from the serve-mode controller (e.g. the TUI) on
/// stdin.
priv enum ServeCommand {
  Prompt(String)
  Steer(String)
  Compact
  Cancel
}

///|
/// A queued serve-mode operation that must wait for active work to finish.
priv enum PendingWork {
  PendingPrompt(String)
  PendingCompact
}

///|
/// The one operation currently occupying the serve loop. Compaction is a
/// non-steerable active operation, but it is still cancellable like a turn.
priv enum ActiveWork {
  ActiveTurn(@async.Task[Unit])
  ActiveCompact(@async.Task[Unit])
}

///|
/// One unit of work for the serve loop's single consumer: a wire command in
/// arrival order, the completion of active work, or the stdin-EOF shutdown
/// marker. Funneling all three through one queue is what makes
/// command handling race-free against turn lifecycle.
priv enum ServeStep {
  Wire(ServeCommand)
  TurnDone
  CompactDone(@agent_session.Session)
  Shutdown
}

///|
/// Decode one JSONL command line from the controller.
///
/// `prompt` starts a turn, `steer` injects input into the running one,
/// `compact` summarizes the current conversation once no work is active, and
/// `cancel` interrupts the active or next queued prompt. Anything else is an
/// `Err` whose text is emitted as a `command_error` event — a controller bug
/// must be visible on the wire, not silently swallowed, but it must not kill
/// the session either.
fn decode_serve_command(json : Json) -> Result[ServeCommand, String] {
  match json {
    { "command": "prompt", "text": String(text), .. } => Ok(Prompt(text))
    { "command": "steer", "text": String(text), .. } => Ok(Steer(text))
    { "command": "prompt", .. } | { "command": "steer", .. } =>
      Err("expected a string \"text\" field")
    { "command": "compact", .. } => Ok(Compact)
    { "command": "cancel", .. } => Ok(Cancel)
    { "command": String(other), .. } => Err("unknown command: \{other}")
    _ => Err("expected a {\"command\": ...} object")
  }
}

///|
test "serve commands decode and reject with actionable errors" {
  assert_true(
    decode_serve_command({ "command": "prompt", "text": "hi" })
    is Ok(Prompt("hi")),
  )
  assert_true(
    decode_serve_command({ "command": "steer", "text": "left" })
    is Ok(Steer("left")),
  )
  assert_true(decode_serve_command({ "command": "compact" }) is Ok(Compact))
  assert_true(decode_serve_command({ "command": "cancel" }) is Ok(Cancel))
  guard decode_serve_command({ "command": "prompt" }) is Err(message) else {
    fail("textless prompt accepted")
  }
  assert_true(message.contains("text"))
  guard decode_serve_command({ "command": "reboot" }) is Err(message) else {
    fail("unknown command accepted")
  }
  assert_true(message.contains("unknown command: reboot"))
  guard decode_serve_command("nonsense") is Err(message) else {
    fail("non-object accepted")
  }
  assert_true(message.contains("command"))
}

///|
fn remove_next_pending_prompt(pending : Array[PendingWork]) -> Unit {
  for index, work in pending {
    if work is PendingPrompt(_) {
      ignore(pending.remove(index))
      return
    }
  }
}

///|
fn has_pending_prompt(pending : Array[PendingWork]) -> Bool {
  for work in pending {
    if work is PendingPrompt(_) {
      return true
    }
  }
  false
}

///|
test "pending prompt helpers ignore queued compactions" {
  let pending : Array[PendingWork] = []
  assert_false(has_pending_prompt(pending))
  pending.push(PendingCompact)
  assert_false(has_pending_prompt(pending))
  pending.push(PendingPrompt("next"))
  assert_true(has_pending_prompt(pending))
  remove_next_pending_prompt(pending)
  assert_false(has_pending_prompt(pending))
  assert_eq(pending.length(), 1)
  assert_true(pending[0] is PendingCompact)
}

///|
/// Run the engine as a long-lived session server: read JSONL commands from
/// stdin, run turns sequentially against one shared session, and write the
/// usual JSONL event stream to stdout. This is the engine half of the
/// persistent-engine design — one process per conversation instead of one
/// per prompt.
///
/// The runtime and the tool registry are built once and shared by every
/// turn, so stateful tools survive turn boundaries (a `moon_check` watcher
/// started in turn 1 keeps reporting in turn 5). `steer` rides the
/// runtime's lossless steering queue into the running (or already
/// submitted) turn; with no turn to land in it is rejected with a
/// `steer_dropped` event — that only happens by racing the terminal event
/// through the pipes, and an engine must never start a turn the controller
/// did not ask for. `cancel` interrupts the current active work but never the
/// process. stdin EOF is the shutdown signal: the running work finishes
/// first, then the loop drains and exits.
async fn run_serve(
  matches : @argparse.Matches,
  workspace_root~ : String,
) -> Unit {
  let api_key = api_key(matches)
  let api_url = api_url(matches)
  let model = @deepseek.Model::parse(value(matches, "model"))
  let max_steps = max_steps(matches)
  let thinking = @deepseek.ThinkingMode::parse(value(matches, "thinking"))
  let (store, initial_session) = match session_id(matches) {
    Some(id) => {
      let store = @store.SessionStore(session_root(matches, workspace_root~))
      (
        Some(store),
        load_or_new_session(store, id, matches, model, workspace_root~),
      )
    }
    // No durable session requested: the conversation still spans every
    // prompt of this process's lifetime, it just leaves nothing behind.
    None =>
      (
        None,
        Session(
          SessionId("serve"),
          system_prompt=configured_system_prompt(
            matches,
            model,
            workspace_root~,
          ),
        ),
      )
  }
  // The live conversation value. `append_item` updates it on every appended
  // event, so even a turn that raises leaves `session` reflecting all the
  // events it recorded before failing.
  let mut session = initial_session
  @async.with_task_group(group => {
    let runtime = @agent_runtime.AgentRuntime(workspace_root~)
    let scope = @agent_runtime.AgentTaskScope(group)
    // Built once: stateful tool records live in this registry, and
    // rebuilding it per turn would orphan running watchers (see
    // @agent.build_tools).
    let tools = @agent.build_tools(runtime, scope)
    // All scheduling flows through one ordered queue with one consumer:
    // wire commands from the reader, plus the internal turn-completion and
    // shutdown markers. A second scheduler (e.g. acting on commands inside
    // the reader) would race the consumer's view of the active turn — a
    // controller writing `prompt\nsteer\n` in one buffer must have its
    // steer land in that prompt's turn, exactly as the wire order says.
    let steps : @async.Queue[ServeStep] = Queue(kind=Unbounded)
    group.spawn_bg(no_wait=true) <| () => {
      @jsonl.each(@stdio.stdin, json => {
        match decode_serve_command(json) {
          Ok(command) => steps.try_put(Wire(command)) |> ignore
          Err(message) =>
            @xlog.error() <? { "event": "command_error", "error": message }
        }
      }) catch {
        error if @async.is_being_cancelled() ||
          @async.is_cancellation_error(error) => raise error
        // A malformed (non-JSON) line is a controller bug: report it and
        // stop reading commands, which shuts the server down gracefully.
        error =>
          @xlog.error() <?
            { "event": "command_error", "error": "command stream: \{error}" }
      }
      steps.try_put(Shutdown) |> ignore
    }
    let pending : Array[PendingWork] = []
    let mut active_work : ActiveWork? = None
    let mut shutting_down = false
    async fn compact_and_report(
      current : @agent_session.Session,
    ) -> @agent_session.Session {
      @compact.compact_session(store?, current, api_key~, model~, api_url?) catch {
        error if @async.is_being_cancelled() ||
          @async.is_cancellation_error(error) => raise error
        error => {
          @xlog.error() <? { "event": "compaction_failed", "error": "\{error}" }
          current
        }
      }
    }
    fn start_turn(task_text : String) -> @async.Task[Unit] {
      group.spawn() <| () => {
        let _ = @agent.run_turn_in_scope(
          runtime,
          scope,
          api_key,
          model,
          session,
          task_text,
          append_item=(current, item) => {
            let next = match store {
              Some(store) => store.append(current, item)
              None => current.append(item)
            }
            session = next
            next
          },
          max_steps~,
          thinking~,
          api_url?,
          tools~,
        ) catch {
          error => {
            // The turn died but the session server must not: a cancelled
            // turn already appended its Interrupted terminal inside the
            // loop, and any other failure is reported as a terminal wire
            // event so the controller can close the run.
            if @async.is_being_cancelled() ||
              @async.is_cancellation_error(error) {
              @xlog.warn() <?
                { "event": "agent_aborted", "reason": "interrupted" }
            } else {
              @xlog.error() <? { "event": "turn_failed", "error": "\{error}" }
            }
            ignore(steps.try_put(TurnDone) catch { _ => false })
            return
          }
        }
        ignore(steps.try_put(TurnDone) catch { _ => false })
      }
    }

    fn start_compaction(current : @agent_session.Session) -> @async.Task[Unit] {
      group.spawn() <| () => {
        let next = compact_and_report(current) catch {
          error if @async.is_being_cancelled() ||
            @async.is_cancellation_error(error) => {
            @xlog.warn() <?
              { "event": "compaction_failed", "error": "cancelled" }
            current
          }
          error => {
            @xlog.error() <?
              { "event": "compaction_failed", "error": "\{error}" }
            current
          }
        }
        ignore(steps.try_put(CompactDone(next)) catch { _ => false })
      }
    }

    fn start_next_pending() -> Unit {
      pending_loop~: for ;; {
        if active_work is Some(_) || pending.length() == 0 {
          break pending_loop~
        }
        match pending.remove(0) {
          PendingPrompt(text) => {
            active_work = Some(ActiveTurn(start_turn(text)))
            break pending_loop~
          }
          PendingCompact => {
            active_work = Some(ActiveCompact(start_compaction(session)))
            break pending_loop~
          }
        }
      }
    }

    serve~: for ;; {
      let step = steps.get() catch {
        error if @async.is_being_cancelled() ||
          @async.is_cancellation_error(error) => raise error
        _ => break serve~
      }
      match step {
        Wire(Prompt(text)) =>
          match active_work {
            // One turn at a time: extra prompts wait their wire-order turn.
            Some(_) => pending.push(PendingPrompt(text))
            None => active_work = Some(ActiveTurn(start_turn(text)))
          }
        Wire(Steer(text)) =>
          match active_work {
            Some(ActiveTurn(_)) => @agent.steer(runtime, text)
            Some(ActiveCompact(_)) | None =>
              if has_pending_prompt(pending) {
                @agent.steer(runtime, text)
              } else {
                @xlog.warn() <? { "event": "steer_dropped", "content": text }
              }
          }
        Wire(Cancel) =>
          match active_work {
            Some(ActiveTurn(task)) => task.cancel()
            Some(ActiveCompact(task)) => task.cancel()
            None =>
              // No active work: in wire order the cancel targets the next
              // submitted prompt, so withdraw it before it starts.
              if pending.length() > 0 {
                remove_next_pending_prompt(pending)
              }
          }
        Wire(Compact) =>
          if active_work is Some(_) {
            pending.push(PendingCompact)
          } else {
            active_work = Some(ActiveCompact(start_compaction(session)))
          }
        TurnDone => {
          // A steer that raced the turn's end (or was queued while it was
          // dying) may still sit in the runtime's steering queue; the next
          // turn must not inherit input the user aimed at this one. Reject
          // leftovers on the wire like any other undeliverable steer.
          for text in runtime.drain_steers() {
            @xlog.warn() <? { "event": "steer_dropped", "content": text }
          }
          active_work = None
          start_next_pending()
          if active_work is None && pending.length() == 0 && shutting_down {
            break serve~
          }
        }
        CompactDone(next) => {
          session = next
          active_work = None
          start_next_pending()
          if active_work is None && pending.length() == 0 && shutting_down {
            break serve~
          }
        }
        Shutdown => {
          shutting_down = true
          if active_work is None && pending.length() == 0 {
            break serve~
          }
        }
      }
    }
  })
}
