///|
let session_dir_name : String = "sessions"

///|
let session_file_name : String = "openseek_session.jsonl"

///|
let lock_file_name : String = "session.lock"

///|
/// Native filesystem-backed collection of durable OpenSeek sessions.
///
/// A `SessionStore` owns only a root path string. Under that root, each session
/// is stored in `sessions/<id>/` with two files: `openseek_session.jsonl` (a
/// header line followed by append-only event lines) and `session.lock`. The
/// store is not a handle to one current session; APIs that operate on a session
/// either take a `SessionId` or a `Session` carrying its id.
pub struct SessionStore {
  priv root : String
} derive(Debug)

///|
/// Construct a store rooted at `root`.
///
/// This does not touch the filesystem and therefore does not validate that the
/// directory exists, is writable, or is a directory. Files and directories are
/// created lazily by `create`, `append`, or `compact`. Read-only operations
/// treat a missing `root/sessions` directory as an empty store where that makes
/// sense.
pub fn SessionStore::SessionStore(root : String) -> SessionStore {
  { root, }
}

///|
/// Return the root path passed to `SessionStore(root)`.
///
/// The returned string is not canonicalized. It may be relative or absolute,
/// and no filesystem check is performed by this accessor.
pub fn SessionStore::root(self : SessionStore) -> String {
  self.root
}

///|
fn validate_session_id(id : @agent_session.SessionId) -> Unit raise {
  let value = id.value()
  if value == "" {
    fail("session id must not be empty")
  }
  if value.contains("/") || value.contains("\\") {
    fail("session id must not contain path separators: \{value}")
  }
  if value == "." || value == ".." {
    fail("session id must not be `.` or `..`")
  }
}

///|
fn SessionStore::sessions_dir(self : SessionStore) -> String {
  "\{self.root}/\{session_dir_name}"
}

///|
fn SessionStore::session_dir(
  self : SessionStore,
  id : @agent_session.SessionId,
) -> String raise {
  validate_session_id(id)
  "\{self.sessions_dir()}/\{id.value()}"
}

///|
fn SessionStore::session_file_path(
  self : SessionStore,
  id : @agent_session.SessionId,
) -> String raise {
  "\{self.session_dir(id)}/\{session_file_name}"
}

///|
fn SessionStore::lock_path(
  self : SessionStore,
  id : @agent_session.SessionId,
) -> String raise {
  "\{self.session_dir(id)}/\{lock_file_name}"
}

///|
fn header_line(session : @agent_session.Session) -> String {
  let header : @session_log.SessionFileHeader = {
    id: session.id().value(),
    system_prompt: session.system_prompt(),
  }
  "\{header.to_json().stringify()}\n"
}

///|
fn events_jsonl(events : @vector.Vector[@agent_session.SessionEvent]) -> String {
  let builder = StringBuilder()
  for event in events {
    builder <+ "\{event.to_json().stringify()}\n"
  }
  builder.to_string()
}

///|
/// The complete durable form of a session: one header line followed by one
/// line per event.
fn session_file_text(session : @agent_session.Session) -> String {
  "\{header_line(session)}\{events_jsonl(session.events())}"
}

///|
fn parse_events_jsonl(
  text : String,
) -> @vector.Vector[@agent_session.SessionEvent] raise {
  let events : Array[@agent_session.SessionEvent] = [
    for line in text.split("\n") if !line.trim().is_empty() => {
      @json.from_json(@json.parse(line))
    }
  ]
  @vector.from_array(events)
}

///|
fn checked_last_sequence_in_events(
  events : @vector.Vector[@agent_session.SessionEvent],
) -> Int raise {
  let mut expected = 1
  for event in events {
    if event.sequence() != expected {
      fail(
        "session event log sequence mismatch: expected \{expected}, found \{event.sequence()}",
      )
    }
    expected += 1
  }
  expected - 1
}

///|
/// Rebuild a session from the durable single-file form: the first line must be
/// a header record, every following non-blank line must decode as an event,
/// and event sequences must be contiguous from 1.
fn session_from_file_text(
  requested_id : @agent_session.SessionId,
  text : String,
) -> @agent_session.Session raise {
  let (first, rest) = match text.split_once("\n") {
    Some((first, rest)) => (first.to_owned(), rest.to_owned())
    None => (text, "")
  }
  let header_json = @json.parse(first) catch {
    error =>
      fail(
        "session file for \{requested_id.value()} does not start with a header line: \{error}",
      )
  }
  let header = match @session_log.parse_header(header_json) {
    Some(header) => header
    None =>
      fail(
        "session file for \{requested_id.value()} does not start with a header record",
      )
  }
  if header.id != requested_id.value() {
    fail(
      "session header id mismatch: requested \{requested_id.value()}, found \{header.id}",
    )
  }
  let events = parse_events_jsonl(rest)
  ignore(checked_last_sequence_in_events(events))
  Session(SessionId(header.id), system_prompt=header.system_prompt, events~)
}

///|
async fn load_persisted_session(
  store : SessionStore,
  id : @agent_session.SessionId,
) -> @agent_session.Session {
  session_from_file_text(id, @fs.read_file(store.session_file_path(id)).text())
}

///|
async fn ensure_session_is_current(
  store : SessionStore,
  session : @agent_session.Session,
) -> Unit {
  let persisted = load_persisted_session(store, session.id()) catch {
    @os_error.OSError(_) as error if error.is_ENOENT() => {
      if session.last_sequence() != 0 {
        fail(
          "stale session snapshot for \{session.id().value()}: no durable session file, in-memory last sequence \{session.last_sequence()}",
        )
      }
      return
    }
    error => raise error
  }
  if persisted.system_prompt() != session.system_prompt() ||
    events_jsonl(persisted.events()) != events_jsonl(session.events()) {
    fail("stale session snapshot for \{session.id().value()}")
  }
}

///|
/// Persist one new event for `session`. The common case is a single
/// `O_APPEND` write of one line. The first durable write for a session (no
/// file yet) instead writes the header line and the first event atomically,
/// so a session file can never exist without its header. Callers hold the
/// exclusive session lock and have already verified the snapshot is current,
/// which for the missing-file case means `session` contains exactly the
/// events being persisted.
async fn append_durable_event(
  store : SessionStore,
  session : @agent_session.Session,
  event : @agent_session.SessionEvent,
) -> Unit {
  let path = store.session_file_path(session.id())
  if @fs.exists(path) {
    @fs.write_file(
      path,
      "\{event.to_json().stringify()}\n",
      create_mode=OpenOrCreate,
      append=true,
    )
  } else {
    write_text_atomic(path, session_file_text(session))
  }
}

///|
async fn write_text_atomic(path : String, text : String) -> Unit {
  let tmp_path = "\{path}.tmp"
  @fs.write_file(tmp_path, text, create_mode=CreateOrTruncate)
  @fs.rename(tmp_path, path, replace=true)
}

///|
async fn ensure_dir_exists(dir : String) -> Unit {
  ensure_dir_exists_with_retry(dir, attempts=4)
}

///|
async fn ensure_dir_exists_with_retry(dir : String, attempts~ : Int) -> Unit {
  if @fs.exists(dir) {
    return
  }
  @fs.mkdir(dir, recursive=true) catch {
    @os_error.OSError(_) as error if error.is_EEXIST() && attempts > 0 =>
      ensure_dir_exists_with_retry(dir, attempts=attempts - 1)
    error => if @fs.exists(dir) { () } else { raise error }
  }
}

///|
async fn ensure_session_dir(
  store : SessionStore,
  id : @agent_session.SessionId,
) -> Unit {
  let dir = store.session_dir(id)
  ensure_dir_exists(dir)
}

///|
async fn[T] with_session_lock(
  store : SessionStore,
  id : @agent_session.SessionId,
  kind : @fs.Lock,
  body : async () -> T,
) -> T {
  let file = @fs.open(
    store.lock_path(id),
    mode=ReadWrite,
    create_mode=OpenOrCreate,
  )
  defer file.close()
  file.lock(kind)
  defer file.unlock()
  body()
}

///|
async fn[T] with_existing_session_lock(
  store : SessionStore,
  id : @agent_session.SessionId,
  kind : @fs.Lock,
  body : async () -> T,
) -> T {
  let dir = store.session_dir(id)
  if !@fs.exists(dir) {
    return body()
  }
  with_session_lock(store, id, kind, body)
}

///|
/// Return whether the directory for `id` exists.
///
/// This checks only `root/sessions/<id>/`; it does not require
/// `openseek_session.jsonl` to exist and does not validate that the session is
/// loadable. Invalid ids raise before any filesystem probe, rather than being
/// silently treated as absent.
pub async fn SessionStore::exists(
  self : SessionStore,
  id : @agent_session.SessionId,
) -> Bool {
  @fs.exists(self.session_dir(id))
}

///|
/// Return the absolute or relative path to a session's
/// `openseek_session.jsonl` file.
///
/// The path is formed from the store root and `id`; the file is not opened and
/// may not exist. Invalid ids raise. This helper exists for read-only tooling,
/// such as the visualizer server, that wants to stream the raw session file
/// without duplicating the store layout rules.
pub fn SessionStore::session_file(
  self : SessionStore,
  id : @agent_session.SessionId,
) -> String raise {
  self.session_file_path(id)
}

///|
/// List known session ids under `root/sessions`, sorted by directory name.
///
/// This is a directory listing only. It does not open session files, parse
/// logs, or check loadability. A missing `root/sessions` directory returns an
/// empty array. Other filesystem errors raise. Returned ids are raw directory
/// names wrapped as `SessionId`.
pub async fn SessionStore::list(
  self : SessionStore,
) -> Array[@agent_session.SessionId] {
  let names = @fs.readdir(self.sessions_dir(), sort=true) catch {
    @os_error.OSError(_) as error if error.is_ENOENT() => []
    error => raise error
  }
  [
    for name in names if name != "." && name != ".." => SessionId(name)
  ]
}

///|
/// Human-facing metadata for one session directory.
///
/// A listing row is intentionally lighter than a loaded session. It can be
/// built without replaying the full event log, so it is suitable for pickers
/// and `--session-list`. A row can also represent a damaged directory: in that
/// case timestamp may be `None` and first prompt may be empty.
pub struct SessionListing {
  priv id : @agent_session.SessionId
  priv last_active_unix_seconds : Int64?
  priv first_prompt : String
} derive(Debug)

///|
/// Return the listed session id.
///
/// Pass this id to `load`, `exists`, or `session_file` when the caller chooses
/// this row.
pub fn SessionListing::id(self : SessionListing) -> @agent_session.SessionId {
  self.id
}

///|
/// Return the listing timestamp in unix seconds.
///
/// This is the modification time of `openseek_session.jsonl`. `None` means the
/// file could not be stat-ed — a damaged directory or one written by an
/// incompatible layout. The value is for sorting/display and is not a durable
/// session field.
pub fn SessionListing::last_active_unix_seconds(
  self : SessionListing,
) -> Int64? {
  self.last_active_unix_seconds
}

///|
/// Return the first user prompt found near the start of the event log.
///
/// The value is a display label, not a validated session field. It is `""` when
/// no user event is found within the scan limit, when the session file cannot
/// be read, or when the session directory is damaged.
pub fn SessionListing::first_prompt(self : SessionListing) -> String {
  self.first_prompt
}

///|
/// Lines scanned from the front of a session file while looking for the first
/// user prompt, not counting the header line. The agent appends the user turn
/// as a session's first event, so this is normally one line; the cap keeps a
/// pathological log from turning a listing into a full read.
let first_prompt_scan_limit : Int = 50

///|
/// The first user prompt recorded in the session file at `path`, or `""` when
/// none is found within the scan limit (or the file cannot be read). Streams
/// line by line instead of loading the session: a listing only needs a
/// label, and long or compacted histories should not make `--session-list`
/// deserialize every event ever appended.
async fn first_prompt_in_log(path : String) -> String {
  let file = @fs.open(path, mode=ReadOnly) catch { _ => return "" }
  defer file.close()
  // The first line is the session header; the prompt scan starts after it.
  let _ = file.read_until("\n") catch { _ => return "" }
  for _ in 0..<first_prompt_scan_limit {
    let next = file.read_until("\n") catch { _ => return "" }
    guard next is Some(line) else { break }
    if line.trim().is_empty() {
      continue
    }
    let event : @agent_session.SessionEvent = @json.from_json(@json.parse(line)) catch {
      _ => return ""
    }
    if event.item() is User(message) {
      return message.content()
    }
  }
  ""
}

///|
/// Order stamped rows newest-first by `(seconds, nanoseconds)`, ignoring the
/// row payload in tuple position 0.
fn[T] stamped_newest_first(a : (T, Int64, Int), b : (T, Int64, Int)) -> Int {
  let (_, a_seconds, a_nanoseconds) = a
  let (_, b_seconds, b_nanoseconds) = b
  if b_seconds != a_seconds {
    b_seconds.compare(a_seconds)
  } else {
    b_nanoseconds.compare(a_nanoseconds)
  }
}

///|
/// List sessions with picker-friendly metadata, most recently active first.
///
/// This scans each session directory for timestamps and a first prompt label,
/// but it does not replay whole histories and does not require loadability.
/// Damaged directories remain visible with `last_active_unix_seconds=None` and
/// `first_prompt=""`, ordered after timestamped rows. Use `latest` when the
/// caller needs the newest session that can actually be loaded.
pub async fn SessionStore::listings(
  self : SessionStore,
) -> Array[SessionListing] {
  let stamped : Array[(SessionListing, Int64, Int)] = []
  let unreadable : Array[SessionListing] = []
  for id in self.list() {
    let path = self.session_file_path(id) catch { _ => continue }
    let stamp = @fs.mtime(path) catch {
      _ => {
        unreadable.push({ id, last_active_unix_seconds: None, first_prompt: "" })
        continue
      }
    }
    let (seconds, nanoseconds) = stamp
    stamped.push(
      (
        {
          id,
          last_active_unix_seconds: Some(seconds),
          first_prompt: first_prompt_in_log(path),
        },
        seconds,
        nanoseconds,
      ),
    )
  }
  // Most recently active first.
  stamped.sort_by(stamped_newest_first)
  let listings = [ for entry in stamped => entry.0 ]
  for listing in unreadable {
    listings.push(listing)
  }
  listings
}

///|
/// The most recently active session id that can actually be resumed, or
/// `None` for an empty store.
///
/// Recency is the session file's modification time, which the single-file
/// layout touches on every append. Candidates are probed newest-first with a
/// real `load`: a directory can stat fine yet hold a corrupt file, and
/// resuming demands a loadable conversation — one broken directory must not
/// make every older, valid session unresumable. In the common case the newest
/// candidate loads and the probe costs one load.
pub async fn SessionStore::latest(
  self : SessionStore,
) -> @agent_session.SessionId? {
  let stamped : Array[(@agent_session.SessionId, Int64, Int)] = []
  for id in self.list() {
    let stamp = @fs.mtime(self.session_file_path(id)) catch { _ => continue }
    let (seconds, nanoseconds) = stamp
    stamped.push((id, seconds, nanoseconds))
  }
  // Newest first.
  stamped.sort_by(stamped_newest_first)
  for entry in stamped {
    let (id, _, _) = entry
    let _ = self.load(id) catch { _ => continue }
    return Some(id)
  }
  None
}

///|
/// Persist a complete session snapshot, replacing prior contents for its id.
///
/// `create` ensures the session directory exists, takes an exclusive lock, and
/// atomically rewrites `openseek_session.jsonl` (write to a temp file, then
/// rename). Use it for new sessions, fixtures, import tools, or deliberate
/// full rewrites. Do not use it for ordinary agent progress; `append`
/// preserves stale-snapshot detection and writes only one new event.
///
/// The call raises on invalid ids, filesystem errors, JSON encoding/write
/// failures, or lock failures.
pub async fn SessionStore::create(
  self : SessionStore,
  session : @agent_session.Session,
) -> Unit {
  ensure_session_dir(self, session.id())
  with_session_lock(self, session.id(), Exclusive, () => {
    write_text_atomic(
      self.session_file_path(session.id()),
      session_file_text(session),
    )
  })
}

///|
/// Load one persisted session selected by `id`.
///
/// A `SessionStore` is a directory-backed collection, not a handle to one
/// current session. For a store rooted at `root`, the id selects the files
/// under `root/sessions/<id>/`: `openseek_session.jsonl` and `session.lock`.
///
/// `load` validates the id before constructing paths, takes a shared lock when
/// the session directory already exists, reads `openseek_session.jsonl`,
/// checks that the header line's id is exactly the requested id, parses and
/// replays every event line, and checks that event sequence numbers are
/// contiguous. The returned value is a rebuilt immutable `Session`.
///
/// `load` never chooses a session implicitly and never mutates the store. Use
/// `list` or `listings` when presenting choices, or `latest` when implementing
/// "resume the newest session", then pass the chosen id to `load`.
///
/// The call raises if the id is invalid, the file cannot be read (including a
/// missing file), the header line is absent or malformed, or any event line is
/// invalid.
pub async fn SessionStore::load(
  self : SessionStore,
  id : @agent_session.SessionId,
) -> @agent_session.Session {
  with_existing_session_lock(self, id, Shared, () => {
    load_persisted_session(self, id)
  })
}

///|
/// Append one item to a durable session and return the new session value.
///
/// The input `session` is the caller's current in-memory snapshot. `append`
/// ensures the directory exists, takes an exclusive lock, loads the durable
/// snapshot, and verifies that it matches the supplied snapshot. If another
/// writer has already changed the session, this raises a stale-snapshot error
/// instead of forking the log.
///
/// On success the item is assigned the next sequence number and the current
/// wall-clock timestamp, one JSONL line is appended to
/// `openseek_session.jsonl`, and the new immutable `Session` is returned. The
/// first append for a session id creates the file, writing the header line and
/// the first event together. The input session is unchanged.
pub async fn SessionStore::append(
  self : SessionStore,
  session : @agent_session.Session,
  item : @agent_session.SessionItem,
) -> @agent_session.Session {
  ensure_session_dir(self, session.id())
  with_session_lock(self, session.id(), Exclusive, () => {
    ensure_session_is_current(self, session)
    let (next, event) = session.append_event(
      item,
      unix_ms=@env.now().reinterpret_as_int64(),
    )
    append_durable_event(self, next, event)
    next
  })
}

///|
/// Append a validated summary event to a durable session.
///
/// This has the same stale-snapshot and locking behavior as `append`, but the
/// item is created by `Session::compact`. `content` must be non-blank,
/// `from_sequence` must be positive, `to_sequence` must be at least
/// `from_sequence`, and the range must already exist in the supplied session.
///
/// The covered raw events remain in `openseek_session.jsonl`; only
/// `Session::chat_messages` applies the compaction by skipping covered earlier
/// events and emitting the summary. On success, the returned session includes
/// the new `Summary` event with a wall-clock timestamp.
pub async fn SessionStore::compact(
  self : SessionStore,
  session : @agent_session.Session,
  content~ : String,
  from_sequence~ : Int,
  to_sequence~ : Int,
) -> @agent_session.Session {
  ensure_session_dir(self, session.id())
  with_session_lock(self, session.id(), Exclusive, () => {
    ensure_session_is_current(self, session)
    let next = session.compact(
      content~,
      from_sequence~,
      to_sequence~,
      unix_ms=@env.now().reinterpret_as_int64(),
    )
    let event = match next.events().peek() {
      Some(event) => event
      None => fail("compacted session did not append a summary event")
    }
    append_durable_event(self, next, event)
    next
  })
}
