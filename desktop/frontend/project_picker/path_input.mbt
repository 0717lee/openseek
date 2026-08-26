// Path-input projection for the project picker. Ordinary typing narrows the
// already loaded directory rows and ranks prefix matches first. A separator
// after an exact loaded child commits that child immediately, avoiding a stale
// parent listing while still issuing at most one Host request per directory.

///|
fn State::editable_path(self : State) -> String {
  match self.location {
    Some(Directory(resource)) => resource.path
    Some(DriveList) => "/"
    None => ""
  }
}

///|
/// Protocol paths encode a Windows drive as `/c:/...`. Only those paths use
/// case-insensitive parent matching; POSIX directory names remain exact.
fn is_windows_drive_resource_path(path : String) -> Bool {
  guard path.length() >= 3 && path[0] == '/' && path[2] == ':' else {
    return false
  }
  let drive = path[1]
  (drive >= 'A' && drive <= 'Z') || (drive >= 'a' && drive <= 'z')
}

///|
/// The part of the draft that can describe a child of the current listing.
/// An absolute path under another parent remains directly submittable but does
/// not pretend that the current directory's rows are its completions.
fn State::path_filter(self : State) -> String {
  guard self.path_draft is Some(raw) else { return "" }
  let draft = raw.trim().to_owned()
  match self.location {
    Some(Directory(resource)) => {
      let base = if resource.path.has_suffix("/") {
        resource.path
      } else {
        resource.path + "/"
      }
      let case_insensitive = is_windows_drive_resource_path(resource.path)
      let comparable_draft = if case_insensitive {
        draft.to_lower()
      } else {
        draft
      }
      let comparable_path = if case_insensitive {
        resource.path.to_lower()
      } else {
        resource.path
      }
      let comparable_base = if case_insensitive {
        base.to_lower()
      } else {
        base
      }
      if comparable_draft == comparable_path ||
        comparable_draft == comparable_base {
        return ""
      }
      match comparable_draft.strip_prefix(comparable_base) {
        Some(suffix) => {
          let suffix = "\{suffix}".to_lower()
          if suffix.contains("/") {
            ""
          } else {
            suffix
          }
        }
        None => if draft.contains("/") { "" } else { draft.to_lower() }
      }
    }
    Some(DriveList) => {
      let query = match draft.to_lower().strip_prefix("/") {
        Some(suffix) => "\{suffix}"
        None => draft.to_lower()
      }
      if query.contains("/") {
        ""
      } else {
        query
      }
    }
    None => ""
  }
}

///|
/// Stable local filtering: directory order is preserved inside two buckets,
/// with prefix matches before looser contains matches.
fn State::visible_entries(self : State) -> Array[String] {
  let query = self.path_filter()
  if query.is_empty() {
    return self.entries
  }
  let prefixes : Array[String] = []
  let contains : Array[String] = []
  for name in self.entries {
    let candidate = name.to_lower()
    if candidate.has_prefix(query) {
      prefixes.push(name)
    } else if candidate.contains(query) {
      contains.push(name)
    }
  }
  for name in contains {
    prefixes.push(name)
  }
  prefixes
}

///|
fn State::entry_target(self : State, name : String) -> String {
  match self.location {
    Some(Directory(resource)) => resource.picker_child_path(name)
    Some(DriveList) => "/" + name + "/"
    None => name
  }
}

///|
/// A trailing separator is an explicit request to continue inside a folder.
/// Commit only a child from the listing the Host already validated: partial,
/// misspelled, and unrelated absolute paths remain editable and require Enter.
/// Resource paths use `/` on every host; Windows resource locations compare
/// case-insensitively, just like their local completion filter.
fn State::committed_child_path(self : State, raw : String) -> (String, String)? {
  let draft = raw.trim().to_owned()
  guard draft.has_suffix("/") else { return None }
  let case_insensitive = match self.location {
    Some(Directory(resource)) => is_windows_drive_resource_path(resource.path)
    Some(DriveList) => true
    None => false
  }
  let comparable_draft = if case_insensitive { draft.to_lower() } else { draft }
  for name in self.entries {
    let target = self.entry_target(name)
    let committed = if target.has_suffix("/") { target } else { target + "/" }
    let child_draft = name + "/"
    let comparable_committed = if case_insensitive {
      committed.to_lower()
    } else {
      committed
    }
    let comparable_child_draft = if case_insensitive {
      child_draft.to_lower()
    } else {
      child_draft
    }
    if comparable_draft == comparable_committed ||
      comparable_draft == comparable_child_draft {
      return Some((target, committed))
    }
  }
  None
}

///|
/// Suggestions are active only for a real filter. Opening the editor with the
/// current directory prefilled must not make Enter unexpectedly choose row 0.
fn State::selected_path_suggestion(self : State) -> String? {
  guard !self.path_filter().is_empty() else { return None }
  let visible = self.visible_entries()
  guard self.path_draft is Some(raw) else { return None }
  let draft = raw.trim()
  // An exact loaded child is already complete, even when a longer sibling
  // sorts ahead of it after refiltering (`better` beside `betterment`).
  for name in visible {
    if draft == self.entry_target(name) {
      return None
    }
  }
  guard visible.get(self.path_selection) is Some(name) else { return None }
  Some(name)
}

///|
fn State::move_path_selection(self : State, delta : Int) -> State {
  guard !self.path_filter().is_empty() else { return self }
  let count = self.visible_entries().length()
  guard count > 0 else { return self }
  { ..self, path_selection: (self.path_selection + delta + count) % count }
}

///|
/// Enter accepts the highlighted local completion when one exists; otherwise
/// it submits the trimmed draft verbatim for normal Host validation.
fn State::path_destination(self : State) -> String? {
  match self.selected_path_suggestion() {
    Some(name) => Some(self.entry_target(name))
    None =>
      match self.path_draft {
        Some(raw) => {
          let path = raw.trim()
          if path.is_empty() {
            None
          } else {
            Some(path.to_owned())
          }
        }
        None => None
      }
  }
}
