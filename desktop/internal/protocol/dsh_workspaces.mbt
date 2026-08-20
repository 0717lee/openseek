// The one dsh document Desktop makes decisions from. Every other dsh reply
// stays opaque JSON on its way to the renderer, but `workspace.list` is read
// natively three times over — it builds the Files/Terminal grant table, it
// answers whether a checkout may be removed, and it authorizes a first-send
// worktree request. Decoding it once, strictly, is what stops those three
// readers from inventing three different answers to "this row is malformed";
// they previously raised, skipped, and silently dropped respectively.
//
// dsh owns this schema and versions it, so unknown fields are ignored here
// rather than rejected the way Desktop's own envelopes reject them.

///|
/// One dsh Workspace as `workspace.list` reports it. `path` is dsh's own
/// `fs.realpath` canon and stays host-native; the renderer projection happens
/// at the API boundary, not in this codec.
pub(all) struct DshWorkspaceView {
  workspace_id : String
  title : String
  path : String
  // dsh's ordered ownership account. Membership is derived from each
  // session's cwd, so a session appears under exactly one Workspace.
  session_ids : Array[String]
} derive(Debug, Eq)

///|
/// The complete `workspace.list` value.
pub(all) struct DshWorkspaceList {
  items : Array[DshWorkspaceView]
  // The registry-global archive set, layered over Workspace accounting: an
  // archived session keeps its slot in `session_ids`, so this is what
  // separates a live conversation from a hidden one.
  archived_session_ids : Array[String]
} derive(Debug, Eq)

///|
/// Decode one required array of session ids. Empty ids are rejected rather
/// than carried: they cannot name a conversation, and every caller uses them
/// to key authority.
fn decode_session_ids(
  value : Json,
  path : @json.JsonPath,
) -> Array[String] raise @json.JsonDecodeError {
  guard value is Array(values) else {
    raise JsonDecodeError((path, "expected array of session ids"))
  }
  let session_ids : Array[String] = []
  for index, entry in values {
    guard entry is String(session_id) && !session_id.trim().is_empty() else {
      raise JsonDecodeError((path.add_index(index), "expected session id"))
    }
    session_ids.push(session_id)
  }
  session_ids
}

///|
pub impl FromJson for DshWorkspaceView with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise JsonDecodeError((path, "expected dsh workspace object"))
  }
  let workspace_id = match fields.get("workspaceId") {
    Some(String(value)) => value
    Some(_) =>
      raise JsonDecodeError((path.add_key("workspaceId"), "expected string"))
    None =>
      raise JsonDecodeError(
        (path.add_key("workspaceId"), "missing required field"),
      )
  }
  let title = match fields.get("title") {
    Some(String(value)) => value
    Some(_) => raise JsonDecodeError((path.add_key("title"), "expected string"))
    None =>
      raise JsonDecodeError((path.add_key("title"), "missing required field"))
  }
  let workspace_path = match fields.get("path") {
    Some(String(value)) => value
    Some(_) => raise JsonDecodeError((path.add_key("path"), "expected string"))
    None =>
      raise JsonDecodeError((path.add_key("path"), "missing required field"))
  }
  let session_ids = match fields.get("sessionIds") {
    Some(value) => decode_session_ids(value, path.add_key("sessionIds"))
    None =>
      raise JsonDecodeError(
        (path.add_key("sessionIds"), "missing required field"),
      )
  }
  { workspace_id, title, path: workspace_path, session_ids }
}

///|
pub impl ToJson for DshWorkspaceView with fn to_json(self) {
  {
    "workspaceId": Json::string(self.workspace_id),
    "title": Json::string(self.title),
    "path": Json::string(self.path),
    "sessionIds": Json::array(self.session_ids.map(Json::string)),
  }
}

///|
pub impl FromJson for DshWorkspaceList with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise JsonDecodeError((path, "expected dsh workspace.list value"))
  }
  let items : Array[DshWorkspaceView] = match fields.get("items") {
    Some(Array(values)) => {
      let items : Array[DshWorkspaceView] = []
      for index, value in values {
        items.push(
          @json.from_json(value, path=path.add_key("items").add_index(index)),
        )
      }
      items
    }
    Some(_) => raise JsonDecodeError((path.add_key("items"), "expected array"))
    None =>
      raise JsonDecodeError((path.add_key("items"), "missing required field"))
  }
  // The archive set participates in every native authority decision: it
  // removes hidden sessions from Files/Terminal grants, first-send worktree
  // eligibility, and checkout occupancy. Treating an absent or reshaped field
  // as empty would therefore restore capabilities that dsh has withdrawn.
  let archived_session_ids = match fields.get("archivedSessionIds") {
    Some(value) => decode_session_ids(value, path.add_key("archivedSessionIds"))
    None =>
      raise JsonDecodeError(
        (path.add_key("archivedSessionIds"), "missing required field"),
      )
  }
  { items, archived_session_ids }
}

///|
pub impl ToJson for DshWorkspaceList with fn to_json(self) {
  {
    "items": Json::array(self.items.map(item => item.to_json())),
    "archivedSessionIds": Json::array(
      self.archived_session_ids.map(Json::string),
    ),
  }
}

///|
/// How many conversations here the user can still return to. An archived
/// session keeps its slot in `session_ids`, so the archive set is subtracted
/// rather than assumed absent. It arrives as a list because that is its wire
/// shape; membership is all this asks of it, so the caller hands over a set.
pub fn DshWorkspaceView::live_session_count(
  self : DshWorkspaceView,
  archived : Set[String],
) -> Int {
  let mut live = 0
  for session_id in self.session_ids {
    if !archived.contains(session_id) {
      live = live + 1
    }
  }
  live
}
