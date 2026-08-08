// Cross-process serialization for shared durable state. This process is not
// the only writer of the files under the session root and the runtime
// directory: a second desktop instance, a TUI launched in the same workspace,
// and a leftover process from a previous run all reach the same registries. An
// `@async.Mutex` orders this process's own tasks and nothing else, so a
// read-modify-write that must not lose a concurrent update pairs one with the
// advisory file lock here.

///|
/// The advisory lock beside `path`. It is a sidecar rather than the data file
/// itself because an atomic save replaces the target by rename: a lock taken
/// on the data file would be attached to the inode that rename orphans, and
/// two writers would each hold "the lock" on a different file.
fn lock_file(path : @pathx.Path) -> @pathx.Path {
  path.dirname().join(path.basename().to_owned() + ".lock")
}

///|
/// An advisory lock on one shared file, held across processes until `release`.
/// It is acquired beside the `@async.Mutex` that orders this process's own
/// tasks, and in the same shape:
///
/// ```moonbit skip
/// registry_lock.acquire()
/// defer registry_lock.release()
/// let shared = @fsx.FileLock::acquire(registry_file, Exclusive)
/// defer shared.release()
/// ```
///
/// `Exclusive` must span a complete read-modify-write: the read has to happen
/// after the lock is granted, since a value read before it may already be
/// stale. `Shared` covers a read that must not overlap a mutation — a reader
/// of a file saved by `write_text_atomic` needs no lock at all.
///
/// The lock only orders writers that take it. Keeping unlocked readers safe
/// is `write_text_atomic`'s job: another tool, an older build, or a plain
/// `cat` never takes this lock and must still see a complete file.
struct FileLock {
  file : @fs.File
}

///|
/// Take the advisory lock guarding `path`, waiting for whichever process
/// holds it. Blocking is the point: a mutation that gave up here would be the
/// lost update the lock exists to prevent.
pub async fn FileLock::acquire(path : @pathx.Path, kind : @fs.Lock) -> FileLock {
  // The lock precedes the data file: a first-run registry write creates the
  // directory itself, and there is nothing to open a lock in until it exists.
  ensure_dir(path.dirname())
  let file = @fs.open(
    lock_file(path).to_string(),
    mode=ReadWrite,
    create_mode=OpenOrCreate,
  )
  // A wait interrupted by cancellation leaves the descriptor ours to close;
  // leaking it would also leak the lock for as long as the process lives.
  file.lock(kind) catch {
    error => {
      file.close()
      raise error
    }
  }
  { file, }
}

///|
pub fn FileLock::release(self : FileLock) -> Unit {
  self.file.unlock()
  self.file.close()
}

///|
/// Replace `path`'s contents in one step: write a temp file beside it, then
/// rename over the target. A reader therefore sees either the old contents or
/// the new ones and never a truncated prefix, whether or not it takes the
/// lock, and a crash mid-write leaves the previous file intact.
///
/// The temp file's name is derived from the target's, so concurrent writers
/// would collide on it: call this under an exclusive `FileLock`, which every
/// caller does.
///
/// Windows may refuse to rename over an existing file; removing the target
/// first narrows the window where neither name holds the new content to that
/// one platform.
pub async fn write_text_atomic(
  path : @pathx.Path,
  content : String,
  permission? : Int = 0o644,
) -> Unit {
  let target = path.to_string()
  let temp = path.dirname().join(path.basename().to_owned() + ".tmp")
  @fs.write_file(
    temp.to_string(),
    content,
    create_mode=CreateOrTruncate,
    permission~,
  )
  @fs.rename(temp.to_string(), target) catch {
    error if @async.is_being_cancelled() => raise error
    rename_failure => {
      // The retry exists only for the Windows refusal above, which is a
      // regular file standing in the way. Anything else at the target is a
      // different failure and must surface as one: a directory there means
      // the path is wrong, and removing it would recursively destroy whatever
      // it holds rather than report that.
      let replaceable = (@fs.kind(target) is Regular) catch {
        error if @async.is_being_cancelled() => raise error
        _ => false
      }
      guard replaceable else { raise rename_failure }
      @fs.remove(target)
      @fs.rename(temp.to_string(), target)
    }
  }
}

// Tests. The lock is flock-based — it belongs to the open file description,
// not the process — so two acquires of one path contend inside a single
// process through exactly the mechanism a second instance would hit. That is
// what makes these tests meaningful without spawning a helper process.

///|
async test "an atomic save replaces the target and leaves no temp behind" {
  let root : @pathx.Path = @fs.tmpdir(prefix="openseek-fsx-atomic-")
  let file = root.join("registry.json")
  write_text_atomic(file, "first")
  assert_eq(read_text(file), "first")
  write_text_atomic(file, "second")
  assert_eq(read_text(file), "second")
  assert_false(exists(root.join("registry.json.tmp")))
  @fs.rmdir(root.to_string(), recursive=true)
}

///|
async test "an exclusive lock makes the next holder wait for the release" {
  let root : @pathx.Path = @fs.tmpdir(prefix="openseek-fsx-exclusive-")
  let file = root.join("registry.json")
  let log : Array[String] = []
  @async.with_task_group(group => {
    let first = FileLock::acquire(file, Exclusive)
    group.spawn(() => {
      let second = FileLock::acquire(file, Exclusive)
      defer second.release()
      log.push("second acquired")
    })
    |> ignore
    // Long enough for the waiter to reach the lock and block on it.
    @async.sleep(100)
    log.push("first releasing")
    first.release()
  })
  assert_eq(log, ["first releasing", "second acquired"])
  @fs.rmdir(root.to_string(), recursive=true)
}

///|
/// Readers must not queue behind each other, or every unlocked read this
/// design relies on would have been the wrong call.
async test "shared locks admit each other" {
  let root : @pathx.Path = @fs.tmpdir(prefix="openseek-fsx-shared-")
  let file = root.join("registry.json")
  let log : Array[String] = []
  @async.with_task_group(group => {
    let first = FileLock::acquire(file, Shared)
    group.spawn(() => {
      let second = FileLock::acquire(file, Shared)
      defer second.release()
      log.push("second acquired")
    })
    |> ignore
    @async.sleep(100)
    log.push("first releasing")
    first.release()
  })
  assert_eq(log, ["second acquired", "first releasing"])
  @fs.rmdir(root.to_string(), recursive=true)
}

///|
/// The Windows retry must not turn "something else already occupies this
/// path" into a recursive delete of whatever that something holds.
async test "an atomic save refuses a target that is not a regular file" {
  let root : @pathx.Path = @fs.tmpdir(prefix="openseek-fsx-kind-")
  let occupied = root.join("registry.json")
  ensure_dir(occupied)
  let kept = occupied.join("keep.txt")
  write_text_atomic(kept, "precious")
  let mut refused = false
  write_text_atomic(occupied, "clobber") catch {
    _ => refused = true
  }
  assert_true(refused)
  assert_eq(read_text(kept), "precious")
  @fs.rmdir(root.to_string(), recursive=true)
}

///|
/// A released lock must leave nothing behind that keeps the next acquire out
/// — the failure this catches is `release` closing the descriptor without
/// unlocking, which only shows up on the second acquire.
async test "a lock can be retaken after release" {
  let root : @pathx.Path = @fs.tmpdir(prefix="openseek-fsx-retake-")
  let file = root.join("registry.json")
  for _ in 0..<3 {
    let lock = FileLock::acquire(file, Exclusive)
    write_text_atomic(file, "held")
    lock.release()
  }
  assert_eq(read_text(file), "held")
  @fs.rmdir(root.to_string(), recursive=true)
}
