///|
/// A snapshot of one file as it was before a mutating tool wrote it. `before` is
/// `None` when the file did not exist (the write created it), and `Some(content)`
/// when it was overwritten. `after` is exactly what the tool wrote: `edit_undo`
/// compares it against the current file before restoring, so a revert never
/// clobbers work the agent did *after* the edition being undone.
pub(all) struct FileSnapshot {
  path : String
  before : String?
  after : String
} derive(Debug, Eq)

///|
/// One edition recorded by a successful mutating tool call. Usually the files it
/// wrote; when `reason` is `Some`, it is instead a non-undoable *barrier* — the
/// mutation happened but cannot be reverted (e.g. a write that clobbered binary
/// content we could not snapshot as text). `edit_undo` refuses at a barrier
/// rather than skipping it and reverting an older edition, preserving LIFO.
pub struct UndoEntry {
  files : Array[FileSnapshot]
  reason : String?
} derive(Debug)

///|
/// A bounded LIFO stack of undo editions, shared by the mutating tools
/// (`edit`/`multi_edit`/`write`) and `edit_undo`. In-memory and session-scoped:
/// only the most recent `max_depth` editions can be reverted; older ones are
/// dropped so memory stays bounded. `edit_undo` is a safety net for the last few
/// mistakes, not a full history.
pub struct UndoStore {
  priv mut entries : Array[UndoEntry]
  priv max_depth : Int
}

///|
/// Create an empty store that keeps at most `max_depth` recent editions
/// (clamped to at least one).
pub fn UndoStore::new(max_depth? : Int = 10) -> UndoStore {
  { entries: [], max_depth: if max_depth < 1 { 1 } else { max_depth } }
}

///|
/// Record a successful edition: the snapshots of the files it wrote. Only
/// successful, applied mutations should be pushed — a rejected or failed tool
/// call must not leave an undo entry. When the depth cap is exceeded the oldest
/// editions are dropped.
pub fn UndoStore::push(self : UndoStore, files : Array[FileSnapshot]) -> Unit {
  self.record({ files, reason: None })
}

///|
/// Record a non-undoable barrier: the mutation succeeded but cannot be reverted.
/// `edit_undo` refuses (with `reason`) when it reaches one, so it never reverts
/// an older edition past a change it could not snapshot.
pub fn UndoStore::push_barrier(self : UndoStore, reason : String) -> Unit {
  self.record({ files: [], reason: Some(reason) })
}

///|
fn UndoStore::record(self : UndoStore, entry : UndoEntry) -> Unit {
  self.entries.push(entry)
  let extra = self.entries.length() - self.max_depth
  if extra > 0 {
    self.entries = [ for i in extra..<self.entries.length() => self.entries[i] ]
  }
}

///|
/// Remove and return the most recent edition, or `None` when nothing is left to
/// undo.
pub fn UndoStore::pop(self : UndoStore) -> UndoEntry? {
  self.entries.pop()
}

///|
/// Number of editions currently available to undo.
pub fn UndoStore::depth(self : UndoStore) -> Int {
  self.entries.length()
}
