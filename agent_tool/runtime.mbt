///|
pub let default_daemon_event_capacity : Int = 32

///|
pub(all) enum DaemonStatus {
  Running
  Stopped
}

///|
pub struct DaemonEvent {
  id : String
  name : String?
  command : String
  cwd : String?
  status : DaemonStatus
  seq : Int
  output : String
  output_truncated : Bool
  max_output_chars : Int
  exit_code : Int?
}

///|
pub fn DaemonEvent::DaemonEvent(
  id~ : String,
  name~ : String?,
  command~ : String,
  cwd~ : String?,
  status~ : DaemonStatus,
  seq~ : Int,
  output~ : String,
  output_truncated~ : Bool,
  max_output_chars~ : Int,
  exit_code~ : Int?,
) -> DaemonEvent {
  {
    id,
    name,
    command,
    cwd,
    status,
    seq,
    output,
    output_truncated,
    max_output_chars,
    exit_code,
  }
}

///|
pub(all) enum AgentEvent {
  DaemonUpdate(DaemonEvent)
}

///|
priv struct DaemonRecord {
  id : String
  name : String?
  command : String
  cwd : String?
  process : @process.Process
  max_output_chars : Int
  mut status : DaemonStatus
  mut seq : Int
  mut output : String
  mut output_truncated : Bool
  mut exit_code : Int?
}

///|
pub struct AgentRuntime[X] {
  priv group : @async.TaskGroup[X]
  priv events : @aqueue.Queue[AgentEvent]
  priv daemons : Map[String, DaemonRecord]
  priv mut next_daemon_index : Int
}

///|
pub fn[X] AgentRuntime::AgentRuntime(
  group : @async.TaskGroup[X],
) -> AgentRuntime[X] {
  {
    group,
    events: Queue(kind=DiscardOldest(default_daemon_event_capacity)),
    daemons: {},
    next_daemon_index: 1,
  }
}

///|
pub fn[X] AgentRuntime::group(self : AgentRuntime[X]) -> @async.TaskGroup[X] {
  self.group
}

///|
pub fn[X] AgentRuntime::next_daemon_id(self : AgentRuntime[X]) -> String {
  let id = "daemon-\{self.next_daemon_index}"
  self.next_daemon_index += 1
  id
}

///|
pub fn[X] AgentRuntime::register_daemon(
  self : AgentRuntime[X],
  id~ : String,
  name~ : String?,
  command~ : String,
  cwd~ : String?,
  process~ : @process.Process,
  max_output_chars~ : Int,
) -> DaemonEvent {
  let record = {
    id,
    name,
    command,
    cwd,
    process,
    max_output_chars,
    status: Running,
    seq: 0,
    output: "",
    output_truncated: false,
    exit_code: None,
  }
  self.daemons[record.id] = record
  record.to_event()
}

///|
pub fn[X] AgentRuntime::daemon_event(
  self : AgentRuntime[X],
  id : String,
) -> DaemonEvent? {
  match self.daemons.get(id) {
    Some(record) => Some(record.to_event())
    None => None
  }
}

///|
pub fn[X] AgentRuntime::record_daemon_output(
  self : AgentRuntime[X],
  id : String,
  chunk : String,
) -> DaemonEvent? {
  match self.daemons.get(id) {
    None => None
    Some(record) => {
      let output = record.output + chunk
      record.output = retain_output_tail(output, record.max_output_chars)
      record.output_truncated = record.output_truncated ||
        output.char_length() > record.max_output_chars
      record.seq += 1
      let event = record.to_event()
      self.emit(event)
      Some(event)
    }
  }
}

///|
pub fn[X] AgentRuntime::mark_daemon_stopped(
  self : AgentRuntime[X],
  id : String,
  exit_code : Int?,
) -> DaemonEvent? {
  match self.daemons.get(id) {
    None => None
    Some(record) => {
      record.status = Stopped
      record.exit_code = exit_code
      record.seq += 1
      let event = record.to_event()
      self.emit(event)
      Some(event)
    }
  }
}

///|
pub fn[X] AgentRuntime::stop_daemon(
  self : AgentRuntime[X],
  id : String,
) -> DaemonEvent? {
  match self.daemons.get(id) {
    None => None
    Some(record) =>
      if record.status is Running {
        record.process.cancel()
        self.mark_daemon_stopped(id, None)
      } else {
        Some(record.to_event())
      }
  }
}

///|
pub fn[X] AgentRuntime::emit(
  self : AgentRuntime[X],
  event : DaemonEvent,
) -> Unit {
  ignore(self.events.try_put(DaemonUpdate(event)) catch { _ => false })
}

///|
pub fn[X] AgentRuntime::drain_events(
  self : AgentRuntime[X],
) -> Array[AgentEvent] {
  let events : Array[AgentEvent] = []
  for ;; {
    let next = self.events.try_get() catch { _ => None }
    match next {
      None => return events
      Some(event) => events.push(event)
    }
  }
}

///|
fn DaemonRecord::to_event(self : DaemonRecord) -> DaemonEvent {
  {
    id: self.id,
    name: self.name,
    command: self.command,
    cwd: self.cwd,
    status: self.status,
    seq: self.seq,
    output: self.output,
    output_truncated: self.output_truncated,
    max_output_chars: self.max_output_chars,
    exit_code: self.exit_code,
  }
}

///|
fn retain_output_tail(content : String, max_chars : Int) -> String {
  if content.char_length() <= max_chars {
    content
  } else {
    let keep_from = content.char_length() - max_chars
    match content.offset_of_nth_char(keep_from) {
      Some(offset) => content[offset:].to_owned()
      None => content
    }
  }
}
