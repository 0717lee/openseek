// The session follower: the host's second reader of a conversation's durable
// record. While a desktop-managed engine can write to a session's store, one
// follower actor per session tails the record itself (`@session_record` —
// complete lines only, each event folded in once by its sequence) and
// broadcasts each newly committed event as a canonical `session.event`
// notification. Those commits, plus the `session.load` snapshot, are the
// durable transcript's only sources on the client; the live `agent.event`
// stream only settles transient stream and lifecycle state in commit-aware
// clients (docs/remote-protocol.md).
//
// The actor is the design's ordering backbone: every read of the record —
// watcher-less kicks, the poll fallback, a routed `session.load`, the final
// scan on engine exit, the archive drain — goes through one serial loop, so
// a session's commits reach the hub in sequence order and a stop
// acknowledgment really means "no scan is in flight and none will start".
// Followers run only while the host manages a writer for the session (the
// serve engine's lifetime, spawn to EOF); an idle session's `session.load`
// reads the record directly, one-shot.

///|
/// How often the actor re-checks the record without being kicked. Kicks from
/// the engine's own stdout events provide the low-latency wakeups (an append
/// is always accompanied by a nearby event — a behavioral invariant, not a
/// contract), so this poll is the safety net for the exceptions: external CLI
/// writers sharing the session, and any append whose event was lost or
/// reordered. A poll that finds nothing appended costs one stat and one short
/// read, so the fallback is cheap enough to keep on every live session.
const FollowerPollMs = 1000

///|
/// Load callers backpressure here instead of accumulating an unbounded
/// waiter array in the actor. The control inbox has one reserved logical
/// slot for each collapsed message kind (Kick, Load, Stop), so Stop can
/// always be queued even when loads are saturated.
const FollowerLoadQueueSize = 32

///|
priv enum FollowerMsg {
  // Something may have been appended: read whatever is past the reader's
  // offset.
  Kick
  // A `session.load` routed through the actor: scan — broadcasting any fresh
  // commits — and reply with the whole transcript the reader now holds.
  Load
  // Stop after a final scan. `writer_exited` is supplied only by a caller
  // that has crossed the process-exit barrier; it lets a brand-new session
  // with no record file retire as an empty drain. The completed generation
  // is a drain barrier: no scan is in flight and none will start, so the
  // record can be moved.
  Stop(final_scan~ : Bool, writer_exited~ : Bool, generation~ : Int)
}

///|
priv enum FollowerLoadReply {
  LoadOk(@protocol.SessionDocument)
  LoadFailed(String)
  // The follower was already draining; the caller waits/retries the actor.
  LoadStopped
}

///|
/// A queued load can be deactivated if its control message cannot be
/// scheduled. The actor still removes that bounded queue entry, but never
/// tries to answer an abandoned reply channel.
priv struct FollowerLoadRequest {
  reply : @async.Queue[FollowerLoadReply]
  mut active : Bool
}

///|
priv struct SessionFollower {
  session : String
  root : @pathx.Absolute
  inbox : @async.Queue[FollowerMsg]
  // Bounded load requests. One Load control message drains and answers a
  // whole batch from this queue with one snapshot.
  load_requests : @async.Queue[FollowerLoadRequest]
  // One queued Kick at a time: a delta storm collapses to a single pending
  // wakeup instead of an unbounded backlog of identical messages.
  mut kick_pending : Bool
  mut load_pending : Bool
  mut stopping : Bool
  mut retired : Bool
  // Stop callers poll a generation-stamped result, avoiding a consumable
  // one-shot ack (and an unbounded waiter collection). A failed final scan
  // completes the generation with an error and reactivates the actor.
  mut stop_generation : Int
  mut completed_stop_generation : Int
  mut completed_stop_error : String?
  mut stop_observers : Int
  // The highest sequence already broadcast. Commits at or below it are old
  // news; the frontier only advances, so a scan can never re-broadcast — not
  // even when the reader replays a record that was repaired under it.
  mut watermark : Int
  // Where this follower has read to, and the transcript it read. A scan is
  // this reader moving forward; a `session.load` is what it already holds.
  tail : @session_record.Tail
}

///|
/// The highest event sequence in a session document — what a snapshot's
/// watermark is. 0 for a record with no events.
fn session_max_sequence(session : @protocol.SessionDocument) -> Int {
  let mut max = 0
  for event in session.events.unwrap_or([]) {
    if event.sequence > max {
      max = event.sequence
    }
  }
  max
}

///|
/// The answer prefix the engine writes on a `Finished` terminal it recorded
/// because the context ceiling ended the turn (`agent_session.mbt`). The
/// durable record has no separate kind for it, so this prefix is the only
/// thing that tells a context yield from a plain finish.
const ContextYieldAnswerPrefix = "[context ceiling]"

///|
/// The exact message the engine records on a `Failed` terminal when the step
/// budget ran out (`turn_loop.mbt`). Same reason as the prefix above: the
/// record spells this outcome in text, not in a kind of its own.
const MaxStepsExhaustedMessage = "max steps exhausted"

///|
/// What a durable terminal says about the run it ended: the status clients
/// see, the answer to carry with a Finished, and the message to publish as
/// an Error ahead of a failure-ish Finished.
priv struct TerminalOutcome {
  status : RunStatus
  answer : String?
  error : String?
}

///|
/// Read a run's outcome from a durable item; `None` for items that are not
/// a terminal boundary. The inner match is exhaustive on purpose: a new
/// terminal kind must decide its mapping here at compile time — falling
/// through to `None` would silently blind the close to a run-ending
/// commit. `UnknownTerminal` is a kind this build cannot name — report
/// Failed rather than fabricating a success the record does not spell.
fn recorded_terminal_outcome(item : @protocol.SessionItem) -> TerminalOutcome? {
  match item {
    Terminal(terminal) =>
      Some(
        match terminal {
          Finished(message) =>
            if message.has_prefix(ContextYieldAnswerPrefix) {
              { status: ContextYield, answer: Some(message), error: None }
            } else {
              { status: Finished, answer: Some(message), error: None }
            }
          Aborted(reason) =>
            {
              status: Aborted,
              answer: None,
              error: Some("agent aborted: \{reason}"),
            }
          // Recorded exactly when a cancel tore the turn down — a more
          // precise fact than the host's own cancel_requested flag, which
          // can race a natural abort.
          Interrupted(_) =>
            { status: Cancelled, answer: None, error: Some("cancelled") }
          Failed(message) =>
            if message == MaxStepsExhaustedMessage {
              { status: MaxStepsExhausted, answer: None, error: Some(message) }
            } else {
              { status: Failed, answer: None, error: Some(message) }
            }
        },
      )
    UnknownTerminal(_) => Some({ status: Failed, answer: None, error: None })
    _ => None
  }
}

///|
/// The single closer for a run that ends in the durable record. The engine
/// appends a turn's Terminal before emitting the matching stdout event, so
/// the record is the authority on WHEN a run is over — and the follower,
/// its reader, is the only place that publishes the run's Error/Finished
/// and flips the phase. The stream consumer only forwards events now; its
/// death can delay this close until the poll ticker's next scan, never
/// lose it.
///
/// Attribution needs no clock, and no run id in the record. Within one
/// engine generation, closing a run and advancing the watermark past its
/// terminal are the same synchronous act, so a terminal read past the
/// watermark cannot belong to a run that already closed; turns are strictly
/// sequential, so at most one is open. Across generations, no engine spawns
/// until the predecessor's record is drained and the successor's baseline
/// has adopted its frontier (`handle_spawn_command`, `SessionFollower::run`
/// — both refuse rather than guess). A terminal read while this engine's
/// run is open is therefore that run's own.
///
/// Deliberately reads `slot.engine`, not `live()`: a condemned engine
/// draining toward EOF still owns its open run, and this close firing from
/// the retirement's final scan is what settles that run with the record's
/// real outcome instead of the synthetic failure reserved for a child that
/// died without committing one.
fn SessionFollower::close_run_from_terminal(
  self : SessionFollower,
  sink : EventSink,
  manager : EngineManager,
  event : @protocol.SessionEvent,
) -> Unit {
  guard recorded_terminal_outcome(event.item) is Some(outcome) else { return }
  guard manager.pump is Serving(sessions~) &&
    sessions.get(self.session) is Some(slot) &&
    slot.engine is Some(engine) &&
    engine.phase is Running(run_id~, ..) else {
    return
  }
  if outcome.error is Some(message) {
    emit_error(sink, message, run_id~)
  }
  emit_finished(sink, run_id, outcome.status, answer?=outcome.answer)
  // One synchronous block with the announcement: the phase flip (into a
  // queued compaction when one is pending, back between turns otherwise)
  // and the steer ledger's terminal cut cannot be separated from it by a
  // suspension.
  engine.phase = engine.phase.after_run_close()
  engine.steer_runs.record_terminal(run_id)
}

///|
/// One scan: read whatever the writer appended since the last one, broadcast
/// everything committed past the watermark, and advance it. Raises when the
/// record cannot be read — the watermark then stays put, so the next scan
/// retries the same span.
///
/// A scan broadcasts; it does not build a snapshot. Kicks and the poll ticker
/// run one per committed event, and a document costs a copy of the whole
/// transcript — the load path asks the reader for that separately, so this
/// path stays proportional to what was appended.
///
/// The reader may report a whole record again (it re-reads from the head when
/// the file was replaced under it); the watermark check here is what keeps
/// that from reaching clients twice.
async fn SessionFollower::scan(
  self : SessionFollower,
  sink : EventSink,
  manager : EngineManager,
) -> Unit {
  for event in self.tail.poll() {
    if event.sequence <= self.watermark {
      continue
    }
    emit(
      sink,
      SessionCommit({
        session: self.session,
        sequence: event.sequence,
        event,
        // The root this follower reads from is the store half of the durable
        // identity — broadcast it so clients place the session without
        // guessing.
        session_root: self.root.resource_path(),
      }),
    )
    self.watermark = event.sequence
    // A terminal boundary is the run's close authority — attribution and
    // outcome selection live in `close_run_from_terminal`. Broadcast first,
    // close second, so the Finished a client receives always trails the
    // commit it settles.
    self.close_run_from_terminal(sink, manager, event)
  }
}

///|
/// The actor. Baseline first: adopt the record's current frontier without
/// broadcasting — anything committed before this follower existed reaches
/// clients through `session.load`, not through a replay storm — then serve
/// the inbox serially until a Stop, with a poll ticker as the kick fallback.
/// The ready ack carries the baseline's outcome, so the spawn path waits for
/// it and refuses a frontier the baseline could not prove: an absent record
/// proves an empty history (a first turn baselines at 0), but one that
/// exists and cannot be read would replay as history the moment it becomes
/// readable — straight into `close_run_from_terminal`.
async fn SessionFollower::run(
  self : SessionFollower,
  sink : EventSink,
  manager : EngineManager,
  ready : @async.Queue[String?],
) -> Unit {
  let follower = self
  // Cancellation can land during baseline, a blocking record read, or an
  // in-flight load generation. Every exit retires this exact identity and
  // completes queued readers with LoadStopped instead of stranding reply.get.
  defer retire_follower_actor(manager, follower)
  // This actor is a fire-and-forget background task, so a baseline failure
  // raised out of it would be swallowed silently and leave the spawn path
  // waiting forever. It travels through the ready ack instead.
  let baseline_failure : String? = try {
    ignore(follower.tail.poll())
    None
  } catch {
    error if @async.is_being_cancelled() => raise error
    // No record yet: this is a session's first turn, and watermark 0 is the
    // truth rather than a guess.
    @session_record.Absent(_) => None
    error => Some("\{error}")
  }
  follower.watermark = follower.tail.watermark()
  ready.put(baseline_failure)
  guard baseline_failure is None else { return }
  let mut retired_generation = 0
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, allow_failure=true, () => {
      for ;; {
        @async.sleep(FollowerPollMs)
        kick_follower_inbox(follower)
      }
    })
    for ;; {
      match follower.inbox.get() {
        Kick => {
          follower.kick_pending = false
          follower.scan(sink, manager) catch {
            error if @async.is_being_cancelled() => raise error
            error =>
              @xlog.debug() <?
                {
                  "event": "desktop_follower_scan_failed",
                  "session": follower.session,
                  "error": "\{error}",
                }
          }
        }
        Load => {
          // The one path that pays for a snapshot: scan first, so the reply
          // carries every commit this generation just broadcast.
          let response = try {
            follower.scan(sink, manager)
            LoadOk(follower.tail.document())
          } catch {
            error if @async.is_being_cancelled() => raise error
            error => LoadFailed("\{error}")
          }
          // Keep `load_pending` set while draining. Reply queues are fresh
          // Blocking(1) queues, so these puts do not suspend; every caller
          // that joined before the queue is observed empty receives this
          // one snapshot. A later caller queues the next Load generation.
          for ;; {
            let request = follower.load_requests.try_get() catch { _ => None }
            match request {
              Some(request) =>
                if request.active {
                  request.active = false
                  request.reply.put(response)
                }
              None => {
                follower.load_pending = false
                break
              }
            }
          }
        }
        Stop(final_scan~, writer_exited~, generation~) => {
          let failure = if final_scan {
            try {
              // Everything the departed writer persisted is broadcast
              // before this generation can retire successfully.
              follower.scan(sink, manager)
              None
            } catch {
              error if @async.is_being_cancelled() => raise error
              // A first prompt can be cancelled after a partial stdin write
              // but before the engine creates its durable record. Once the
              // caller has proved the writer exited, a record that was never
              // created and a zero watermark together prove there is no
              // durable tail to drain. Every other failure — a malformed
              // record, one that vanished after this follower read it, a
              // store root that is not a directory — keeps the follower
              // active for a later retry.
              @session_record.Absent(detail) =>
                if writer_exited && follower.watermark == 0 {
                  None
                } else {
                  Some(detail)
                }
              error => Some("\{error}")
            }
          } else {
            None
          }
          if failure is Some(detail) {
            // A failed final scan is not a drain. Keep the actor installed
            // and polling, and publish the exact failure to every caller
            // waiting on this stop generation.
            follower.completed_stop_generation = generation
            follower.completed_stop_error = Some(detail)
            if follower.stop_observers == 0 {
              follower.stopping = false
            }
          } else {
            retired_generation = generation
            break
          }
        }
      }
    }
    group.return_immediately(())
  })
  // Publish the successful generation before removing the identity. A stop
  // waiter can therefore distinguish this deliberate retirement from an
  // actor that vanished without completing its final scan.
  follower.completed_stop_generation = retired_generation
  follower.completed_stop_error = None
}

///|
/// Remove exactly this follower generation and make every queued caller
/// observe retirement. Closing is synchronous, so startup rollback can use
/// this from a cancellation path even when the follower task itself belongs
/// to a task group that is already being torn down. The identity check only
/// guards the manager entry; a stale actor is still closed without touching
/// the successor that replaced it.
fn retire_follower_actor(
  manager : EngineManager,
  follower : SessionFollower,
) -> Unit {
  if follower.retired {
    return
  }
  follower.retired = true
  if manager.followers.get(follower.session) is Some(current) &&
    physical_equal(current, follower) {
    manager.followers.remove(follower.session)
  }
  follower.inbox.close(clear=true)
  follower.load_requests.close()
  // Defensive completion for any request that crossed retirement. Normal
  // Stop ordering drains every pre-Stop Load first; startup cancellation can
  // happen earlier, so those readers get an explicit retry signal here.
  for ;; {
    let request = follower.load_requests.try_get() catch { _ => None }
    match request {
      Some(request) =>
        if request.active {
          request.active = false
          ignore(request.reply.try_put(LoadStopped) catch { _ => false })
        }
      None => break
    }
  }
}

///|
/// Queue a Kick, collapsing repeats while one is already pending. Safe to
/// call from anywhere; a closed inbox (the actor is retiring) refuses it
/// quietly.
fn kick_follower_inbox(follower : SessionFollower) -> Unit {
  if follower.stopping || follower.kick_pending {
    return
  }
  if (follower.inbox.try_put(Kick) catch { _ => false }) {
    follower.kick_pending = true
  }
}

///|
/// Wake `session`'s follower, if any — the engine consumer calls this on
/// every stdout event, which is what gives commits their low latency.
fn EngineManager::kick_follower(self : EngineManager, session : String) -> Unit {
  if self.followers.get(session) is Some(follower) {
    kick_follower_inbox(follower)
  }
}

///|
/// Make sure a follower is watching `config.session` before its engine can
/// write, and only return once its baseline scan is done. Runs inside the
/// pump's spawn path, so the follower task lives in the same task group as
/// the engines. The returned identity is present only when this call installed
/// a new follower; its caller owns startup rollback until the engine reader
/// and consumer have both been scheduled. A session root can still be absent
/// only when the durable store cannot be resolved; in that case there is no
/// record for a follower to scan.
async fn[G] ensure_follower(
  sink~ : EventSink,
  group~ : @async.TaskGroup[G],
  manager~ : EngineManager,
  config~ : RunConfig,
) -> SessionFollower? {
  guard config.session_root is Some(root) else { return None }
  let session = config.session
  // A predecessor draining its final scan removes itself from the map when
  // done; wait for that rather than racing it with a second broadcaster for
  // the same session (per-session commit order is the design's backbone).
  for ;; {
    match manager.followers.get(session) {
      Some(follower) => {
        if !follower.stopping && follower.root.to_string() == root.to_string() {
          return None
        }
        // Join an in-flight drain, or retire an active follower attached to
        // another session root. A failed final scan propagates and prevents
        // a child for the new root from being spawned.
        stop_follower(manager, session, writer_exited=false)
      }
      None => break
    }
  }
  let follower : SessionFollower = {
    session,
    root,
    inbox: Queue(kind=Blocking(3)),
    load_requests: Queue(kind=Blocking(FollowerLoadQueueSize)),
    kick_pending: false,
    load_pending: false,
    stopping: false,
    retired: false,
    stop_generation: 0,
    completed_stop_generation: 0,
    completed_stop_error: None,
    stop_observers: 0,
    watermark: 0,
    tail: Tail(root, session),
  }
  manager.followers[session] = follower
  let ready : @async.Queue[String?] = Queue(kind=Blocking(1))
  group.spawn_bg(no_wait=true, allow_failure=true, () => {
    follower.run(sink, manager, ready)
  })
  // The actor lives in the pump group rather than this caller's task, so
  // cancelling startup does not cancel it. Retire it synchronously on the way
  // out; waiting for a Stop would deadlock if the pump group is also exiting.
  let baseline_failure = {
    errdefer discard_follower_startup(manager, follower)
    ready.get()
  }
  if baseline_failure is Some(detail) {
    // The actor already retired itself on its way out; this only clears an
    // entry that retirement could have lost to an identity race.
    discard_follower_startup(manager, follower)
    raise EngineError("failed to baseline the session record: \{detail}")
  }
  Some(follower)
}

///|
/// Stop `session`'s follower and wait for its final scan to drain. This is
/// the barrier archive relies on: after it returns, no scan is in flight and
/// none will start, so the record directory can be moved without a late read
/// broadcasting from beyond the grave.
async fn stop_follower(
  manager : EngineManager,
  session : String,
  writer_exited~ : Bool,
  final_scan? : Bool = true,
) -> Unit {
  guard manager.followers.get(session) is Some(follower) else { return }
  stop_follower_instance(manager, follower, writer_exited~, final_scan~)
}

///|
/// Stop one captured follower generation, but only while it is still the
/// manager's current identity. EOF cleanup captures this before publishing
/// the engine-exit latch, so a delayed cleanup can never stop a successor.
async fn stop_follower_instance(
  manager : EngineManager,
  follower : SessionFollower,
  writer_exited~ : Bool,
  final_scan? : Bool = true,
) -> Unit {
  let session = follower.session
  guard manager.followers.get(session) is Some(current) &&
    physical_equal(current, follower) else {
    return
  }
  let generation = if follower.stopping {
    follower.stop_generation
  } else {
    // This flag is set before the first possible yield. No load/kick can
    // slip behind the drain request, and ensure_follower can never mistake
    // this generation for an active reusable actor.
    follower.stopping = true
    follower.stop_generation = follower.stop_generation + 1
    let generation = follower.stop_generation
    let queued = follower.inbox.try_put(
      Stop(final_scan~, writer_exited~, generation~),
    ) catch {
      _ => false
    }
    if !queued {
      follower.completed_stop_generation = generation
      follower.completed_stop_error = Some("follower control queue is closed")
      follower.stopping = false
      raise EngineError("follower control queue is closed")
    }
    generation
  }
  follower.stop_observers = follower.stop_observers + 1
  defer {
    follower.stop_observers = follower.stop_observers - 1
    // Keep a failed generation closed while any of its callers still need
    // to observe the result. The last observer reactivates the actor, after
    // which a later lifecycle operation may start a fresh retry generation.
    if follower.stop_generation == generation &&
      follower.completed_stop_generation == generation &&
      follower.completed_stop_error is Some(_) &&
      follower.stop_observers == 0 {
      follower.stopping = false
    }
  }
  for ;; {
    if follower.completed_stop_generation == generation {
      if follower.completed_stop_error is Some(detail) {
        raise EngineError(detail)
      }
      return
    }
    guard manager.followers.get(session) is Some(current) &&
      physical_equal(current, follower) else {
      raise EngineError("follower retired without completing its final scan")
    }
    @async.sleep(10)
  }
}

///|
/// Roll back a follower initialized before process startup commits. No
/// prompt can have reached a child yet, hence no writer has a final commit
/// to scan; this is synchronous actor initialization cleanup, not a drain.
fn discard_follower_startup(
  manager : EngineManager,
  follower : SessionFollower,
) -> Unit {
  retire_follower_actor(manager, follower)
}

///|
/// Queue a bounded, coalesced snapshot request. When the request queue is
/// full, `put` backpressures this caller; Stop remains independent in the
/// three-slot control inbox and can always overtake load saturation after
/// the single pending Load generation.
async fn request_follower_load(follower : SessionFollower) -> FollowerLoadReply {
  if follower.stopping {
    return LoadStopped
  }
  let reply : @async.Queue[FollowerLoadReply] = Queue(kind=Blocking(1))
  let request : FollowerLoadRequest = { reply, active: true }
  // The request must be present before its collapsed control signal. A full
  // queue backpressures here; once accepted, either the current Load scan
  // drains it or this caller schedules the next generation.
  follower.load_requests.put(request) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return LoadStopped
  }
  if request.active && !follower.load_pending {
    follower.load_pending = true
    let queued = follower.inbox.try_put(Load) catch { _ => false }
    if !queued {
      follower.load_pending = false
      request.active = false
      return LoadStopped
    }
  }
  reply.get()
}

// The follower's pure core: the watermark a snapshot reports, and the run
// outcome a durable terminal spells. Reading the record is
// `@session_record`'s own tested job; the actor around it (baseline, serial
// loop, stop drain) is exercised end to end against real records.
