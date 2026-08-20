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
/// A lifecycle Finished that was published before the follower could prove
/// the matching durable frontier. The actor retains published entries until
/// retirement as an idempotence ledger: a producer that registers the same run
/// again across the semantic-terminal and failed-command paths cannot make it
/// be announced twice.
priv struct PendingDurableFinish {
  run_id : String
  mut published : Bool
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
  // Pending run identities belong to this retryable drain, not to the serve
  // handle: EOF may retire a dead handle while a failed final scan deliberately
  // leaves this actor alive for archive/detach to retry later.
  durable_finishes : Array[PendingDurableFinish]
  // The highest sequence already broadcast. Commits at or below it are old
  // news; the frontier only advances, so a scan can never re-broadcast — not
  // even when the reader replays a record that was repaired under it.
  mut watermark : Int
  // Where this follower has read to, and the transcript it read. A scan is
  // this reader moving forward; a `session.load` is what it already holds.
  tail : @session_record.Tail
}

///|
/// Remember that `run_id` needs an exact post-Finished durable boundary.
/// Registration is idempotent across the semantic-terminal and failed-command
/// paths, which may race while the child is shutting down.
fn SessionFollower::expect_durable_finish(
  self : SessionFollower,
  run_id : String,
) -> Unit {
  for pending in self.durable_finishes {
    if pending.run_id == run_id {
      return
    }
  }
  self.durable_finishes.push({ run_id, published: false })
}

///|
/// Publish every retained boundary at the frontier proved by this successful
/// final scan, and keep the entries as the actor's dedupe ledger. Publishing
/// is total, so this is the seam's only outcome.
fn SessionFollower::publish_durable_finishes(
  self : SessionFollower,
  sink : EventSink,
) -> Unit {
  let mut index = 0
  while index < self.durable_finishes.length() {
    let pending = self.durable_finishes[index]
    if !pending.published {
      emit_durable_boundary(sink, pending.run_id, self.session, self.watermark)
      pending.published = true
    }
    index = index + 1
  }
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
  emit_finished(
    sink,
    run_id,
    outcome.status,
    answer?=outcome.answer,
    durable_sequence=event.sequence,
  )
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
          // Both a readable snapshot and the exact-zero proof above are
          // successful drains. Publish pending lifecycle boundaries at this
          // single seam before retirement.
          if final_scan && failure is None {
            follower.publish_durable_finishes(sink)
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
    durable_finishes: [],
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

///|
test "recorded terminal outcomes follow the durable-log contracts" {
  guard recorded_terminal_outcome(Terminal(Finished("done")))
    is Some({ status: Finished, answer: Some("done"), error: None }) else {
    fail("expected a plain finish")
  }
  guard recorded_terminal_outcome(
      Terminal(Finished("[context ceiling] checkpointed")),
    )
    is Some({ status: ContextYield, .. }) else {
    fail("expected the answer prefix to spell a context yield")
  }
  guard recorded_terminal_outcome(Terminal(Failed("max steps exhausted")))
    is Some({ status: MaxStepsExhausted, .. }) else {
    fail("expected the exact message to spell a max-steps stop")
  }
  guard recorded_terminal_outcome(Terminal(Failed("boom")))
    is Some({ status: Failed, error: Some("boom"), .. }) else {
    fail("expected a plain failure")
  }
  guard recorded_terminal_outcome(Terminal(Interrupted("cancelled")))
    is Some({ status: Cancelled, error: Some("cancelled"), .. }) else {
    fail("expected an interruption to close as cancelled")
  }
  guard recorded_terminal_outcome(
      UnknownTerminal({ "kind": "terminal", "payload": { "kind": "novel" } }),
    )
    is Some({ status: Failed, answer: None, error: None }) else {
    fail("expected an unknown terminal to close as failed")
  }
  assert_true(
    recorded_terminal_outcome(
      Summary({ content: "s", from_sequence: 1, to_sequence: 2 }),
    )
    is None,
  )
}

///|
test "session_max_sequence is the snapshot's watermark" {
  let session : @protocol.SessionDocument = {
    version: None,
    id: Some("s"),
    system_prompt: None,
    events: Some([
      {
        sequence: 5,
        ts: None,
        item: User({ content: "five", submission_id: None }),
      },
      {
        sequence: 9,
        ts: None,
        item: User({ content: "nine", submission_id: None }),
      },
      {
        sequence: 7,
        ts: None,
        item: User({ content: "seven", submission_id: None }),
      },
    ]),
  }
  inspect(session_max_sequence(session), content="9")
  inspect(session_max_sequence({ ..session, events: Some([]) }), content="0")
}

///|
/// One durable event line, as the store writes them.
#cfg(not(platform="windows"))
fn session_user_event(sequence : Int, content : String) -> String {
  "{\"sequence\":\{sequence},\"item\":{\"kind\":\"user\",\"payload\":{\"content\":\"\{content}\"}}}"
}

///|
/// Stand in for the engine: write `session`'s record under `root` in the
/// store's own form, a header line followed by one line per event.
#cfg(not(platform="windows"))
async fn write_session_record(
  root : @pathx.Absolute,
  session : String,
  events : Array[String],
) -> Unit {
  let path = @session_record.record_path(root, session)
  @fsx.ensure_dir(path.dirname())
  let text = StringBuilder()
  text <+ "{\"version\":1,\"id\":\"\{session}\",\"system_prompt\":\"\"}\n"
  for event in events {
    text.write_string(event)
    text <+ "\n"
  }
  @fs.write_file(
    path.to_string(),
    text.to_string(),
    create_mode=CreateOrTruncate,
  )
}

///|
/// A record no reader can make sense of: present, so this is not an absent
/// record, but headed by a line that is not a header.
#cfg(not(platform="windows"))
async fn write_damaged_record(root : @pathx.Absolute, session : String) -> Unit {
  let path = @session_record.record_path(root, session)
  @fsx.ensure_dir(path.dirname())
  @fs.write_file(
    path.to_string(),
    "{\"not\":\"a header\"}\n",
    create_mode=CreateOrTruncate,
  )
}

///|
/// A config for a follower with no engine behind it. Every test below hands
/// `engine` a path that is never created, let alone spawned: a follower reads
/// the record itself, and the path only fills the field a run config has.
#cfg(not(platform="windows"))
fn follower_test_config(
  engine : String,
  session : String,
  root : @pathx.Absolute,
) -> RunConfig {
  {
    task: "test",
    api_key: "test",
    api_url: None,
    model: "test",
    max_steps: 1,
    engine,
    cwd: None,
    session,
    session_root: Some(root),
  }
}

///|
/// The follower is the run's single closer: a durable Terminal read past
/// the watermark closes the open run immediately — real status, exact
/// sequence, no grace — and the engine stays alive for its next turn.
#cfg(not(platform="windows"))
async test "a durable terminal closes its open run" {
  let dir = @fs.tmpdir(prefix="openseek-durable-close-")
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  let manager = new_engine_manager("/bin/sh")
  let emitted : Array[EngineEvent] = []
  let sink = EventSink(fn(event) { emitted.push(event) })
  @async.with_task_group(group => {
    let (child_stdin, writer) = @process.write_to_process()
    let process = @process.spawn(
      group,
      "/bin/sh",
      ["-c", "sleep 30"],
      stdin=child_stdin,
      no_wait=true,
    )
    let engine = test_serve_engine(
      "s-close",
      writer,
      process,
      sink,
      phase=Running(
        run_id="r-close",
        cancel_requested=false,
        compact_queued=false,
      ),
      session_root=root,
    )
    let sessions : Map[String, SessionSlot] = Map([])
    let slot = slot_for(sessions, "s-close")
    slot.engine = Some(engine)
    manager.pump = Serving(sessions~)
    let follower = follower_state_fixture("s-close")
    fn terminal_event(
      sequence : Int,
      terminal : @protocol.SessionTerminal,
    ) -> @protocol.SessionEvent {
      { sequence, ts: None, item: Terminal(terminal) }
    }

    // A terminal closes the open run immediately: real status, the record's
    // answer, the exact sequence — and the engine stays live for reuse.
    // `ts: None` on every event doubles as proof that attribution never
    // consults the record clock.
    follower.close_run_from_terminal(
      sink,
      manager,
      terminal_event(42, Finished("all done")),
    )
    assert_true(engine.phase is Idle(last_run=Some("r-close")))
    assert_false(engine.condemned)
    assert_true(slot.live() is Some(_))
    guard emitted is [Finished(finish)] else {
      fail("expected exactly one finished event")
    }
    assert_eq(finish.run_id, "r-close")
    assert_eq(finish.status, "finished")
    assert_eq(finish.answer, Some("all done"))
    assert_eq(finish.durable_sequence, Some(42))
    emitted.clear()

    // With the phase already closed, replaying the same commit is inert.
    follower.close_run_from_terminal(
      sink,
      manager,
      terminal_event(42, Finished("all done")),
    )
    assert_true(emitted.is_empty())

    // A cancel is recorded as Interrupted, and closes with the same
    // Error+Finished pair the stream path used to publish.
    engine.phase = Running(
      run_id="r-close-2",
      cancel_requested=true,
      compact_queued=false,
    )
    follower.close_run_from_terminal(
      sink,
      manager,
      terminal_event(44, Interrupted("cancelled")),
    )
    guard emitted is [Error(error), Finished(cancel_finish)] else {
      fail("expected an error and a finished event")
    }
    assert_eq(error.message, Some("cancelled"))
    assert_eq(cancel_finish.status, "cancelled")
    assert_eq(cancel_finish.durable_sequence, Some(44))
    emitted.clear()

    // A close with a compaction queued behind the turn lands in Compacting,
    // exactly as the stream close did, so nothing slips in ahead of it.
    engine.phase = Running(
      run_id="r-close-3",
      cancel_requested=false,
      compact_queued=true,
    )
    follower.close_run_from_terminal(
      sink,
      manager,
      terminal_event(46, Finished("done")),
    )
    assert_true(engine.phase is Compacting(last_run=Some("r-close-3")))
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
/// The baseline refuses to guess. With an existing record it cannot read,
/// the spawn fails loudly with the cause instead of starting at watermark 0
/// — which would replay the whole history into the durable close on the
/// first successful scan. An absent record is the legitimate first-turn
/// case and baselines at 0.
#cfg(not(platform="windows"))
async test "an unreadable existing record refuses the spawn baseline" {
  let dir = @fs.tmpdir(prefix="openseek-follower-baseline-")
  let engine = dir + "/engine.sh"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  let manager = new_engine_manager(engine)
  let sink = EventSink(fn(_) { () })
  @async.with_task_group(group => {
    // No record file: absence is proof, so the follower installs at the
    // proven-empty watermark and the first turn can run.
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, "s-baseline", root),
      ),
    )
    guard manager.followers.get("s-baseline") is Some(follower) else {
      fail("expected a follower for the record-less first turn")
    }
    assert_eq(follower.watermark, 0)
    discard_follower_startup(manager, follower)

    // A record that exists and cannot be read refuses the spawn instead,
    // and leaves no follower installed.
    write_damaged_record(root, "s-baseline")
    let detail = try {
      ignore(
        ensure_follower(
          sink~,
          group~,
          manager~,
          config=follower_test_config(engine, "s-baseline", root),
        ),
      )
      "no error"
    } catch {
      EngineError(detail) => detail
      error if @async.is_being_cancelled() => raise error
      error => "\{error}"
    }
    assert_true(detail.contains("failed to baseline the session record"))
    assert_true(manager.followers.get("s-baseline") is None)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "failed final scan keeps the follower active and propagates" {
  let dir = @fs.tmpdir(prefix="openseek-follower-stop-")
  let engine = dir + "/engine.sh"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  // The record must be readable while the follower baselines — a spawn over
  // one that is not is refused outright. Damaging it afterwards is the case
  // this test is about: a record that goes bad under a live follower.
  write_session_record(root, "s-fail", [])
  let manager = new_engine_manager(engine)
  let sink = EventSink(fn(_) { () })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, "s-fail", root),
      ),
    )
    guard manager.followers.get("s-fail") is Some(follower) else {
      fail("expected follower")
    }
    write_damaged_record(root, "s-fail")
    let detail = try {
      stop_follower(manager, "s-fail", writer_exited=true)
      "no error"
    } catch {
      EngineError(detail) => detail
      error if @async.is_being_cancelled() => raise error
      error => "\{error}"
    }
    assert_true(detail.contains("session record"))
    assert_true(
      manager.followers.get("s-fail") is Some(current) &&
      physical_equal(current, follower),
    )
    assert_false(follower.stopping)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "zero-watermark durable boundary survives a failed final scan" {
  let dir = @fs.tmpdir(prefix="openseek-follower-durable-zero-")
  let engine = dir + "/engine.sh"
  let session = "s-durable-zero"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  // A record the writer created but has not committed anything to: the
  // baseline reads it, and the boundary below lands at sequence 0.
  write_session_record(root, session, [])
  let manager = new_engine_manager(engine)
  let emitted : Array[EngineEvent] = []
  let sink = EventSink(fn(event) { emitted.push(event) })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, session, root),
      ),
    )
    guard manager.followers.get(session) is Some(follower) else {
      fail("expected follower")
    }
    follower.expect_durable_finish("r-durable-zero")
    follower.expect_durable_finish("r-durable-zero")
    // Damaged under the follower, so its final scan cannot prove a frontier.
    write_damaged_record(root, session)
    let detail = try {
      stop_follower(manager, session, writer_exited=true)
      "no error"
    } catch {
      EngineError(detail) => detail
      error if @async.is_being_cancelled() => raise error
      error => "\{error}"
    }
    assert_true(detail.contains("session record"))
    assert_true(
      follower.durable_finishes
      is [{ run_id: "r-durable-zero", published: false }],
    )
    assert_false(emitted.iter().any(event => event is DurableBoundary(_)))

    // Readable again: every retry drains, and the retained boundary is
    // published exactly once across all of them.
    write_session_record(root, session, [])
    let retry_a = group.spawn(() => {
      stop_follower(manager, session, writer_exited=true)
    })
    let retry_b = group.spawn(() => {
      stop_follower(manager, session, writer_exited=true)
    })
    retry_a.wait()
    retry_b.wait()
    stop_follower(manager, session, writer_exited=true)
    let boundaries : Array[Int] = []
    for event in emitted {
      if event is DurableBoundary(payload) && payload.run_id == "r-durable-zero" {
        boundaries.push(payload.sequence)
      }
    }
    assert_eq(boundaries, [0])
    assert_true(follower.durable_finishes[0].published)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "absent first record publishes one exact-zero durable boundary" {
  let dir = @fs.tmpdir(prefix="openseek-follower-durable-absent-")
  let engine = dir + "/engine.sh"
  let session = "s-durable-absent"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  // No record at all: the writer was cancelled before creating one.
  let manager = new_engine_manager(engine)
  let emitted : Array[EngineEvent] = []
  let sink = EventSink(fn(event) { emitted.push(event) })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, session, root),
      ),
    )
    guard manager.followers.get(session) is Some(follower) else {
      fail("expected follower")
    }
    follower.expect_durable_finish("r-durable-absent")
    stop_follower(manager, session, writer_exited=true)
    stop_follower(manager, session, writer_exited=true)

    let boundaries : Array[Int] = []
    for event in emitted {
      if event is DurableBoundary(payload) &&
        payload.run_id == "r-durable-absent" {
        boundaries.push(payload.sequence)
      }
    }
    assert_eq(boundaries, [0])
    assert_true(follower.retired)
    assert_true(manager.followers.get(session) is None)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "nonzero durable boundary survives a failed final scan" {
  let dir = @fs.tmpdir(prefix="openseek-follower-durable-tail-")
  let engine = dir + "/engine.sh"
  let session = "s-durable-tail"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  write_session_record(root, session, [])
  let manager = new_engine_manager(engine)
  let emitted : Array[EngineEvent] = []
  let sink = EventSink(fn(event) { emitted.push(event) })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, session, root),
      ),
    )
    guard manager.followers.get(session) is Some(follower) else {
      fail("expected follower")
    }
    follower.expect_durable_finish("r-durable-tail")
    write_damaged_record(root, session)
    stop_follower(manager, session, writer_exited=true) catch {
      EngineError(detail) => assert_true(detail.contains("session record"))
      error if @async.is_being_cancelled() => raise error
      error => raise error
    }

    // The writer's last commit is only readable on the retry, so the drain
    // that succeeds is also the one that broadcasts it.
    write_session_record(root, session, [session_user_event(1, "done")])
    stop_follower(manager, session, writer_exited=true)
    let relevant : Array[EngineEvent] = []
    for event in emitted {
      match event {
        SessionCommit(payload) if payload.session == session =>
          relevant.push(event)
        DurableBoundary(payload) if payload.run_id == "r-durable-tail" =>
          relevant.push(event)
        _ => ()
      }
    }
    guard relevant
      is [
        SessionCommit({ sequence: 1, session_root, .. }),
        DurableBoundary({ sequence: 1, .. }),
      ] else {
      fail("expected one rooted commit and one durable boundary")
    }
    assert_eq(session_root, root.resource_path())
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
/// A child that dies mid-turn but committed its Terminal first is settled
/// by the retirement's final drain with the record's real outcome; the
/// synthetic Failed is reserved for a death that left no Terminal.
#cfg(not(platform="windows"))
async test "EOF retirement closes a committed turn with its real outcome" {
  let dir = @fs.tmpdir(prefix="openseek-eof-durable-close-")
  let session = "s-eof-close"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  write_session_record(root, session, [])
  let manager = new_engine_manager(dir + "/engine.sh")
  let emitted : Array[EngineEvent] = []
  let sink = EventSink(fn(event) { emitted.push(event) })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(dir + "/engine.sh", session, root),
      ),
    )
    guard manager.followers.get(session) is Some(follower) else {
      fail("expected follower")
    }
    let (child_stdin, writer) = @process.write_to_process()
    let process = @process.spawn(
      group,
      "/bin/sh",
      ["-c", "sleep 30"],
      stdin=child_stdin,
      no_wait=true,
    )
    let engine = test_serve_engine(
      session,
      writer,
      process,
      sink,
      phase=Running(
        run_id="r-eof",
        cancel_requested=false,
        compact_queued=false,
      ),
      session_root=root,
      follower~,
    )
    let sessions : Map[String, SessionSlot] = Map([])
    let slot = slot_for(sessions, session)
    slot.engine = Some(engine)
    manager.pump = Serving(sessions~)
    // The turn committed its Terminal before the child died — the order a
    // real engine appends in — so the final drain finds it.
    write_session_record(root, session, [
      "{\"sequence\":7,\"item\":{\"kind\":\"terminal\",\"payload\":{\"kind\":\"interrupted\",\"message\":\"cancelled\"}}}",
    ])
    let messages : @async.Queue[StreamMessage] = Queue(
      kind=Blocking(EngineStreamQueueSize),
    )
    messages.put(StreamExited(0))
    let stderr_task = group.spawn(no_wait=true, () => "")
    engine.run(manager, messages, stderr_task)

    // The final drain found the Terminal: the run settled with the record's
    // own outcome and sequence, and no synthetic failure was fabricated.
    assert_true(engine.phase is Idle(last_run=Some("r-eof")))
    assert_true(slot.engine is None)
    let mut cancelled = 0
    for event in emitted {
      if event is Finished(payload) {
        assert_eq(payload.run_id, "r-eof")
        assert_eq(payload.status, "cancelled")
        assert_eq(payload.durable_sequence, Some(7))
        cancelled += 1
      }
    }
    assert_eq(cancelled, 1)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "abrupt EOF retains a failed final drain for later boundary retry" {
  let dir = @fs.tmpdir(prefix="openseek-follower-abrupt-eof-")
  let engine_path = dir + "/engine.sh"
  let session = "s-abrupt-eof"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  write_session_record(root, session, [])
  let manager = new_engine_manager(engine_path)
  let emitted : Array[EngineEvent] = []
  let sink = EventSink(fn(event) { emitted.push(event) })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine_path, session, root),
      ),
    )
    guard manager.followers.get(session) is Some(follower) else {
      fail("expected follower")
    }
    let (child_stdin, writer) = @process.write_to_process()
    let process = @process.spawn(
      group,
      "/bin/sh",
      ["-c", "exit 7"],
      stdin=child_stdin,
      no_wait=true,
    )
    let engine = test_serve_engine(
      session,
      writer,
      process,
      sink,
      phase=Running(
        run_id="r-abrupt-eof",
        cancel_requested=false,
        compact_queued=false,
      ),
      session_root=root,
      follower~,
    )
    let sessions : Map[String, SessionSlot] = Map([])
    let slot = slot_for(sessions, session)
    slot.engine = Some(engine)
    manager.pump = Serving(sessions~)
    let messages : @async.Queue[StreamMessage] = Queue(
      kind=Blocking(EngineStreamQueueSize),
    )
    messages.put(StreamExited(7))
    let stderr_task = group.spawn(no_wait=true, () => "")
    // The record is unreadable at EOF, so the drain this engine's exit runs
    // cannot prove a frontier and the boundary stays pending.
    write_damaged_record(root, session)
    engine.run(manager, messages, stderr_task)

    // `run` returning is retirement: the slot is clear and every lifecycle
    // event this engine owed has been published.
    assert_true(slot.engine is None)
    assert_true(
      follower.durable_finishes
      is [{ run_id: "r-abrupt-eof", published: false }],
    )
    let mut finished_index = -1
    let mut early_boundaries = 0
    for index, event in emitted {
      match event {
        Finished(payload) if payload.run_id == "r-abrupt-eof" => {
          assert_true(payload.durable_sequence is None)
          finished_index = index
        }
        DurableBoundary(payload) if payload.run_id == "r-abrupt-eof" =>
          early_boundaries = early_boundaries + 1
        _ => ()
      }
    }
    assert_true(finished_index >= 0)
    assert_eq(early_boundaries, 0)

    write_session_record(root, session, [])
    stop_follower(manager, session, writer_exited=true)
    let mut boundary_index = -1
    let mut boundary_count = 0
    for index, event in emitted {
      if event is DurableBoundary(payload) && payload.run_id == "r-abrupt-eof" {
        assert_eq(payload.sequence, 0)
        boundary_index = index
        boundary_count = boundary_count + 1
      }
    }
    assert_eq(boundary_count, 1)
    assert_true(boundary_index > finished_index)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "workspace detach drains an orphaned pending follower before commit" {
  ambient_env_test_lock.acquire()
  defer ambient_env_test_lock.release()
  let previous = @sys.get_env_var("OPENSEEK_SESSION_ROOT")
  let dir = @fs.tmpdir(prefix="openseek-detach-orphan-follower-")
  let global_root : @pathx.Absolute = @pathx.Path(dir + "/global").resolve()
  let workspace : @pathx.Absolute = @pathx.Path(dir + "/workspace").resolve()
  let root = @workspaces.store_root(workspace)
  let engine_path = dir + "/engine.sh"
  let session = "s-detach-orphan"
  @sys.set_env_var("OPENSEEK_SESSION_ROOT", global_root.to_string())
  defer restore_session_root_env(previous)
  @fsx.ensure_dir(workspace.to_path())
  ignore(attach_workspace(workspace.to_string(), fn(_) { () }))
  write_session_record(root, session, [])
  let manager = new_engine_manager(engine_path)
  let sessions : Map[String, SessionSlot] = Map([])
  manager.pump = Serving(sessions~)
  let emitted : Array[EngineEvent] = []
  let sink = EventSink(fn(event) { emitted.push(event) })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine_path, session, root),
      ),
    )
    guard manager.followers.get(session) is Some(follower) else {
      fail("expected follower")
    }
    follower.expect_durable_finish("r-detach-orphan")
    write_damaged_record(root, session)
    stop_follower(manager, session, writer_exited=true) catch {
      EngineError(detail) => assert_true(detail.contains("session record"))
      error if @async.is_being_cancelled() => raise error
      error => raise error
    }
    assert_false(follower.retired)

    // The detach below drains the orphan, so the record has to be readable
    // again by then.
    write_session_record(root, session, [])
    let committed_after_boundary : Ref[Bool] = Ref(false)
    let detached = detach_workspace(manager, workspace.to_string(), fn(_) {
      committed_after_boundary.val = emitted
        .iter()
        .any(event => {
          event
          is DurableBoundary({ run_id: "r-detach-orphan", sequence: 0, .. })
        })
    })
    assert_true(committed_after_boundary.val)
    assert_true(detached is Workspaces([]))
    assert_true(follower.retired)
    assert_true(manager.followers.get(session) is None)
    let boundaries : Array[Int] = []
    for event in emitted {
      if event is DurableBoundary(payload) &&
        payload.run_id == "r-detach-orphan" {
        boundaries.push(payload.sequence)
      }
    }
    assert_eq(boundaries, [0])
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "workspace detach refuses an idle engine whose follower cannot drain" {
  let dir = @fs.tmpdir(prefix="openseek-detach-follower-stop-")
  let workspace : @pathx.Absolute = @pathx.Path(dir + "/workspace").resolve()
  let root = @workspaces.store_root(workspace)
  let engine_path = dir + "/engine.sh"
  let session = "s-detach-fail"
  // Readable at baseline, damaged once the follower is watching: a spawn
  // over an unreadable record is refused before it gets this far.
  write_session_record(root, session, [])
  let manager = new_engine_manager(engine_path)
  let sink = EventSink(fn(_) { () })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine_path, session, root),
      ),
    )
    guard manager.followers.get(session) is Some(follower) else {
      fail("expected follower")
    }
    write_damaged_record(root, session)
    let (child_stdin, writer) = @process.write_to_process()
    // The real EOF consumer reaches this state after its first failed final
    // scan: the child is gone and the consumer with it, but the follower is
    // still live. Detach must retry it and propagate the failure again — so
    // the fixture's child exits on its own and its close barrier is the
    // process task, exactly as it would be in production.
    let process = @process.spawn(
      group,
      "/bin/sh",
      ["-c", "exit 0"],
      stdin=child_stdin,
      no_wait=true,
    )
    let engine = test_serve_engine(
      session,
      writer,
      process,
      sink,
      phase=Idle(last_run=Some("r-detach-fail")),
      session_root=root,
      follower~,
      condemned=true,
    )
    let sessions : Map[String, SessionSlot] = Map([])
    let slot = slot_for(sessions, session)
    slot.engine = Some(engine)
    manager.pump = Serving(sessions~)
    let detail = try {
      manager.close_engines_for_workspace(workspace)
      "no error"
    } catch {
      EngineError(detail) => detail
      error if @async.is_being_cancelled() => raise error
      error => "\{error}"
    }
    assert_true(detail.contains("session record"))
    assert_true(
      manager.followers.get(session) is Some(current) &&
      physical_equal(current, follower),
    )
    assert_false(follower.stopping)
    discard_follower_startup(manager, follower)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "record stat failure is not mistaken for an empty final drain" {
  let dir = @fs.tmpdir(prefix="openseek-follower-stat-")
  let engine = dir + "/engine.sh"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  // Opening the pinned record beneath a regular file deterministically raises
  // ENOTDIR. That failure must complete Stop as failed and leave the actor
  // installed, never masquerade as the ENOENT of a record never created.
  // The follower baselines over a real record first — the spawn path refuses
  // a record it cannot read — and the directory turns into a file after.
  write_session_record(root, "s-stat", [])
  let manager = new_engine_manager(engine)
  let sink = EventSink(fn(_) { () })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, "s-stat", root),
      ),
    )
    guard manager.followers.get("s-stat") is Some(follower) else {
      fail("expected follower")
    }
    let record = @session_record.record_path(root, "s-stat")
    let session_dir = record.dirname()
    @fs.rmdir(session_dir.to_string(), recursive=true)
    @fs.write_file(
      session_dir.to_string(),
      "file",
      create_mode=CreateOrTruncate,
    )
    let detail = try {
      stop_follower(manager, "s-stat", writer_exited=true)
      "no error"
    } catch {
      EngineError(detail) => detail
      error if @async.is_being_cancelled() => raise error
      error => "\{error}"
    }
    // The reader takes the record's lock first, so ENOTDIR surfaces there —
    // still the failure this test is about, and still not the ENOENT that
    // would prove no record was ever created.
    assert_true(detail.contains("Not a directory"))
    assert_true(
      manager.followers.get("s-stat") is Some(current) &&
      physical_equal(current, follower),
    )
    assert_false(follower.stopping)
    discard_follower_startup(manager, follower)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "root change retires the old follower before installing another" {
  let dir = @fs.tmpdir(prefix="openseek-follower-root-")
  let engine = dir + "/engine.sh"
  let manager = new_engine_manager(engine)
  let sink = EventSink(fn(_) { () })
  let root_a : @pathx.Absolute = @pathx.Path(dir + "/a").resolve()
  let root_b : @pathx.Absolute = @pathx.Path(dir + "/b").resolve()
  // The same session id under two stores: installing the second follower
  // drains the first, which needs a readable record of its own.
  write_session_record(root_a, "s-root", [])
  write_session_record(root_b, "s-root", [])
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, "s-root", root_a),
      ),
    )
    guard manager.followers.get("s-root") is Some(first) else {
      fail("expected first follower")
    }
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, "s-root", root_b),
      ),
    )
    guard manager.followers.get("s-root") is Some(second) else {
      fail("expected replacement follower")
    }
    assert_false(physical_equal(first, second))
    assert_eq(second.root.to_string(), root_b.to_string())
    discard_follower_startup(manager, second)
  })
  @fs.rmdir(dir, recursive=true)
}

///|
#cfg(not(platform="windows"))
async test "one Load control message answers a bounded request batch" {
  let dir = @fs.tmpdir(prefix="openseek-follower-load-")
  let engine = dir + "/engine.sh"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  write_session_record(root, "s-load", [session_user_event(1, "hello")])
  let manager = new_engine_manager(engine)
  let sink = EventSink(fn(_) { () })
  @async.with_task_group(group => {
    ignore(
      ensure_follower(
        sink~,
        group~,
        manager~,
        config=follower_test_config(engine, "s-load", root),
      ),
    )
    guard manager.followers.get("s-load") is Some(follower) else {
      fail("expected follower")
    }
    let replies : Array[@async.Queue[FollowerLoadReply]] = []
    for _ in 0..<8 {
      let reply : @async.Queue[FollowerLoadReply] = Queue(kind=Blocking(1))
      replies.push(reply)
      follower.load_requests.put({ reply, active: true })
    }
    follower.load_pending = true
    assert_true(follower.inbox.try_put(Load))
    // One scan answers the whole batch: every caller receives the very same
    // snapshot value, not one read each.
    let mut shared : @protocol.SessionDocument? = None
    for reply in replies {
      guard reply.get() is LoadOk(document) else { fail("expected a snapshot") }
      match shared {
        None => shared = Some(document)
        Some(first) => assert_true(physical_equal(first, document))
      }
    }
    guard shared is Some(document) else { fail("expected a snapshot") }
    assert_eq(session_max_sequence(document), 1)
    discard_follower_startup(manager, follower)
  })
  @fs.rmdir(dir, recursive=true)
}

///|
fn follower_state_fixture(session : String) -> SessionFollower {
  let root : @pathx.Absolute = @pathx.Path("/tmp/follower-state-fixture").resolve()
  {
    session,
    root,
    inbox: Queue(kind=Blocking(3)),
    load_requests: Queue(kind=Blocking(1)),
    kick_pending: false,
    load_pending: false,
    stopping: false,
    retired: false,
    stop_generation: 0,
    completed_stop_generation: 0,
    completed_stop_error: None,
    stop_observers: 0,
    durable_finishes: [],
    watermark: 0,
    tail: Tail(root, session),
  }
}

///|
test "startup rollback closes waiters and preserves a successor identity" {
  let manager = new_engine_manager("unused")
  let abandoned = follower_state_fixture("s-startup")
  let reply : @async.Queue[FollowerLoadReply] = Queue(kind=Blocking(1))
  let request : FollowerLoadRequest = { reply, active: true }
  assert_true(abandoned.load_requests.try_put(request))
  manager.followers["s-startup"] = abandoned
  discard_follower_startup(manager, abandoned)
  assert_true(manager.followers.get("s-startup") is None)
  assert_false(request.active)
  assert_true(reply.try_get() is Some(LoadStopped))
  assert_false(abandoned.inbox.try_put(Kick) catch { _ => false })

  let stale = follower_state_fixture("s-startup")
  let successor = follower_state_fixture("s-startup")
  manager.followers["s-startup"] = successor
  discard_follower_startup(manager, stale)
  assert_true(
    manager.followers.get("s-startup") is Some(current) &&
    physical_equal(current, successor),
  )
  assert_true(successor.inbox.try_put(Kick))
}

///|
test "pump reset completes every queued follower load" {
  let manager = new_engine_manager("unused")
  let follower = follower_state_fixture("s-reset")
  let reply : @async.Queue[FollowerLoadReply] = Queue(kind=Blocking(1))
  let request : FollowerLoadRequest = { reply, active: true }
  assert_true(follower.load_requests.try_put(request))
  manager.followers["s-reset"] = follower
  manager.pump = Serving(sessions=Map([]))
  reset_engine_generation(manager, Ref(None))
  assert_true(manager.pump is Stopped)
  assert_true(manager.followers.get("s-reset") is None)
  assert_false(request.active)
  assert_true(reply.try_get() is Some(LoadStopped))
}

///|
async test "identity-scoped stop never retires a successor" {
  let manager = new_engine_manager("unused")
  let departed = follower_state_fixture("s-exit")
  let successor = follower_state_fixture("s-exit")
  manager.followers["s-exit"] = successor
  stop_follower_instance(manager, departed, writer_exited=false)
  assert_true(
    manager.followers.get("s-exit") is Some(current) &&
    physical_equal(current, successor),
  )
  assert_false(successor.stopping)
  assert_true(successor.inbox.try_get() is None)
}

///|
#cfg(not(platform="windows"))
async test "cancelling follower baseline removes its startup identity" {
  let dir = @fs.tmpdir(prefix="openseek-follower-cancel-")
  let engine = dir + "/engine.sh"
  let root : @pathx.Absolute = @pathx.Path(dir + "/root").resolve()
  // A record long enough that its baseline spans many reads, so the cancel
  // below lands inside one instead of racing a read that already finished.
  write_session_record(
    root,
    "s-cancel",
    Array::makei(12_000, index => session_user_event(index + 1, "line")),
  )
  let manager = new_engine_manager(engine)
  let sink = EventSink(fn(_) { () })
  @async.with_task_group(group => {
    let startup = group.spawn(() => {
      ignore(
        ensure_follower(
          sink~,
          group~,
          manager~,
          config=follower_test_config(engine, "s-cancel", root),
        ),
      )
    })
    while manager.followers.get("s-cancel") is None {
      @async.pause()
    }
    startup.cancel()
    let cancelled = try {
      startup.wait()
      false
    } catch {
      error if @async.is_cancellation_error(error) => true
      _ => false
    }
    assert_true(cancelled)
    assert_true(manager.followers.get("s-cancel") is None)
    group.return_immediately(())
  })
  @fs.rmdir(dir, recursive=true)
}

///|
async test "load request is queued before its collapsed control message" {
  let follower = follower_state_fixture("s-order")
  @async.with_task_group(group => {
    let caller = group.spawn(() => request_follower_load(follower))
    assert_true(follower.inbox.get() is Load)
    let request = follower.load_requests.get()
    assert_true(request.active)
    request.active = false
    request.reply.put(
      LoadOk({ version: None, id: None, system_prompt: None, events: Some([]) }),
    )
    assert_true(caller.wait() is LoadOk(_))
  })
}

///|
async test "backpressured load schedules the next control generation" {
  let follower = follower_state_fixture("s-backpressure")
  let placeholder : @async.Queue[FollowerLoadReply] = Queue(kind=Blocking(1))
  follower.load_requests.put({ reply: placeholder, active: false })
  follower.load_pending = true
  @async.with_task_group(group => {
    let caller = group.spawn(() => request_follower_load(follower))
    @async.pause()
    // Freeing the sole request slot accepts and wakes the blocked caller.
    // Model the previous Load generation finishing before that caller runs.
    ignore(follower.load_requests.get())
    follower.load_pending = false
    assert_true(follower.inbox.get() is Load)
    let request = follower.load_requests.get()
    assert_true(request.active)
    request.active = false
    request.reply.put(
      LoadOk({ version: None, id: None, system_prompt: None, events: Some([]) }),
    )
    assert_true(caller.wait() is LoadOk(_))
  })
}

///|
async test "stop requires its generation proof when follower identity vanishes" {
  let manager = new_engine_manager("unused")
  let follower = follower_state_fixture("s-stop-proof")
  manager.followers["s-stop-proof"] = follower
  @async.with_task_group(group => {
    let caller = group.spawn(() => {
      try {
        stop_follower(manager, "s-stop-proof", writer_exited=false)
        "no error"
      } catch {
        EngineError(detail) => detail
        error if @async.is_being_cancelled() => raise error
        error => "\{error}"
      }
    })
    guard follower.inbox.get() is Stop(generation~, ..) else {
      fail("expected Stop")
    }
    manager.followers.remove("s-stop-proof")
    let detail = caller.wait()
    assert_true(detail.contains("without completing"))

    let completed = follower_state_fixture("s-stop-complete")
    manager.followers["s-stop-complete"] = completed
    let successful = group.spawn(() => {
      stop_follower(manager, "s-stop-complete", writer_exited=false)
      true
    })
    guard completed.inbox.get() is Stop(generation=completed_generation, ..) else {
      fail("expected second Stop")
    }
    completed.completed_stop_generation = completed_generation
    completed.completed_stop_error = None
    manager.followers.remove("s-stop-complete")
    assert_true(successful.wait())
    ignore(generation)
  })
}
