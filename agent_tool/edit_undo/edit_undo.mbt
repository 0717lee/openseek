///|
/// Tool definition for `edit_undo`: reverts the most recent edition made by a
/// file-mutating tool (`edit` / `multi_edit` / `write`), restoring every file
/// that call touched to its prior content (a file the edition *created* is
/// deleted). It is a bounded safety net for the last few mistakes — repeated
/// calls walk back the recent editions, and an empty history is an error.
///
/// Conflict-aware: a file is reverted only when it is unchanged since the
/// edition (its current content still matches what the tool wrote). If any file
/// in the edition was edited afterward, the whole revert is refused as a
/// conflict, so undo never discards newer work.
pub fn definition(
  undo? : @undo.UndoStore? = None,
) -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="edit_undo",
    description="Revert the most recent edit/multi_edit/write edition, restoring every file that call touched to its prior content (a file the edition created is deleted). A bounded safety net for recovering from a bad edit — for example a multi_edit batch that broke the build with many errors. Repeated calls walk back the recent editions; when nothing is left to undo it returns an error. A file is reverted only if it is unchanged since the edition; if any touched file was edited afterward the revert is refused as a conflict so it never discards newer work. After restoring, `moon check` feedback is appended so you can confirm the resulting state. Takes no arguments.",
    schema=JsonSchema({ "type": "object", "properties": {} }),
    execute=Async(_arguments => execute(undo)),
  )
}

///|
async fn execute(undo : @undo.UndoStore?) -> @agent_tool.ToolAction {
  let brief = "edit_undo"
  let store = match undo {
    Some(store) => store
    None =>
      return @agent_tool.ToolAction::respond(
        "error: edit_undo is unavailable (no undo history was provided)",
        is_error=true,
        brief~,
      )
  }
  let entry = match store.pop() {
    Some(entry) => entry
    None =>
      return @agent_tool.ToolAction::respond(
        "error: edit_undo: nothing to undo",
        is_error=true,
        brief~,
      )
  }
  // Conflict check: every file must be unchanged since the edition (its current
  // content still equals what the tool wrote). Atomic — if any file changed,
  // revert none and leave the stack as it was so the agent can resolve it.
  let conflicts : Array[String] = []
  for snap in entry.files {
    let current = read_current(snap.path)
    let unchanged = match (current, snap.before) {
      (Some(content), _) => content == snap.after
      // A created file that is already gone: deleting it is a no-op, not a conflict.
      (None, None) => true
      // An edited file we can no longer read counts as changed.
      (None, Some(_)) => false
    }
    if !unchanged {
      conflicts.push(snap.path)
    }
  }
  if conflicts.length() > 0 {
    store.push(entry.files)
    return @agent_tool.ToolAction::respond(
      "error: edit_undo: \{conflicts.length()} file(s) changed since the edit; not reverting (conflict):\n\{conflicts.join("\n")}",
      is_error=true,
      brief~,
    )
  }
  // Restore: write back each original, or delete a file the edition created.
  for snap in entry.files {
    match snap.before {
      Some(original) =>
        @fs.write_file(snap.path, original, create_mode=CreateOrTruncate) catch {
          error if @async.is_being_cancelled() => raise error
          error =>
            return @agent_tool.ToolAction::respond(
              "error: edit_undo: failed to restore \{snap.path}: \{error}",
              is_error=true,
              brief~,
            )
        }
      None =>
        @fs.remove(snap.path) catch {
          error if @async.is_being_cancelled() => raise error
          _ => () // already gone is fine
        }
    }
  }
  let summary = "ok: reverted \{entry.files.length()} file(s) (undid the last edit)"
  let response = match entry.files.get(0) {
    Some(first) => @auto_check.append_summary(first.path, summary)
    None => summary
  }
  @agent_tool.ToolAction::respond(response, brief~)
}

///|
/// A file's current content, or `None` when it cannot be read (missing or
/// unreadable) — which the conflict check treats as "changed".
async fn read_current(path : String) -> String? {
  Some(@fs.read_file(path).text()) catch {
    _ => None
  }
}
