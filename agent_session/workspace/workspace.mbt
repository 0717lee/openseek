///|
const WorkspacesDirName : String = "workspaces"

///|
const WorkspaceFileName : String = "workspace.json"

///|
const WorkspaceLockFileName : String = "workspace.lock"

///|
const WorkspaceFileVersion : Int = 1

///|
/// Where a workspace keeps its durable sessions: `.openseek` inside the
/// project directory.
const StoreDirName : String = ".openseek"

///|
/// The global OpenSeek home (`~/.openseek` unless overridden). The home only
/// *indexes* workspaces — one `workspaces/<key>/workspace.json` per project
/// directory ever opened — so they can be found again from anywhere; the
/// sessions themselves stay in each project's `.openseek`, traveling (and
/// dying) with the project. Constructing a home touches nothing on disk;
/// index entries appear when the first workspace is opened.
pub(all) struct WorkspaceHome(String) derive(Debug)

///|
/// One opened workspace: a project directory, indexed under the OpenSeek
/// home.
pub struct Workspace {
  priv path : String
} derive(Debug)

///|
/// The workspace's project directory, canonicalized.
pub fn Workspace::path(self : Workspace) -> String {
  self.path
}

///|
/// The directory holding this workspace's durable sessions — the root to
/// open a `SessionStore` at: `.openseek` inside the project, exactly where
/// the pre-workspace TUI kept them, so existing stores need no migration.
pub fn Workspace::store_root(self : Workspace) -> String {
  self.path + "/" + StoreDirName
}

///|
fn WorkspaceHome::workspaces_dir(self : WorkspaceHome) -> String {
  self.0 + "/" + WorkspacesDirName
}

///|
/// FNV-1a-64 of the canonical workspace path, as 16 hex chars. The key only
/// needs to be stable and filesystem-safe — `workspace.json` carries the real
/// path, and `open` probes past collisions — but stable means stable across
/// releases: the key names directories on disk, and changing the function
/// would orphan every existing workspace. Hence a fixed local hash instead of
/// `Hash::hash`, whose algorithm the core library is free to change.
fn workspace_key(path : String) -> String {
  let mut hash : UInt64 = 0xcbf29ce484222325
  for byte in @utf8.encode(path) {
    hash = (hash ^ byte.to_uint64()) * 0x100000001b3
  }
  let hex = hash.to_string(radix=16)
  "0".repeat(16 - hex.length()) + hex
}

///|
priv struct WorkspaceFile {
  path : String
  last_opened_unix : Int64
}

///|
fn workspace_file_json(path : String, last_opened_unix : Int64) -> Json {
  Json::object({
    "version": WorkspaceFileVersion.to_json(),
    "path": Json::string(path),
    // Unix seconds fit a double exactly; `Json::number` keeps the field an
    // ordinary JSON number instead of Int64's string encoding.
    "last_opened_unix": Json::number(last_opened_unix.to_double()),
  })
}

///|
fn decode_workspace_file(
  json : Json,
  json_path : @json.JsonPath,
) -> WorkspaceFile raise @json.JsonDecodeError {
  let fields = match json {
    Object(fields) => fields
    _ => raise JsonDecodeError((json_path, "expected workspace object"))
  }
  match fields.get("version") {
    Some(Number(version, ..)) =>
      if version.to_int() != WorkspaceFileVersion {
        raise JsonDecodeError(
          (
            json_path.add_key("version"),
            "unsupported workspace version: \{version.to_int()}",
          ),
        )
      }
    _ => raise JsonDecodeError((json_path.add_key("version"), "expected int"))
  }
  let path = match fields.get("path") {
    Some(String(path)) => path
    _ => raise JsonDecodeError((json_path.add_key("path"), "expected string"))
  }
  let last_opened_unix = match fields.get("last_opened_unix") {
    Some(Number(value, ..)) => value.to_int64()
    _ =>
      raise JsonDecodeError(
        (json_path.add_key("last_opened_unix"), "expected int"),
      )
  }
  { path, last_opened_unix }
}

///|
impl @json.FromJson for WorkspaceFile with fn from_json(
  json : Json,
  json_path : @json.JsonPath,
) -> WorkspaceFile {
  decode_workspace_file(json, json_path)
}

///|
fn decode_workspace_text(text : String) -> WorkspaceFile raise {
  @json.from_json(@json.parse(text))
}

///|
/// The raw `workspace.json` under `dir`, or `None` when absent.
async fn read_workspace_text(dir : String) -> String? {
  Some(@fs.read_file(dir + "/" + WorkspaceFileName).text()) catch {
    @os_error.OSError(_) as error if error.is_ENOENT() => None
    error => raise error
  }
}

///|
async fn write_workspace_file(
  dir : String,
  path : String,
  last_opened_unix : Int64,
) -> Unit {
  let file_path = dir + "/" + WorkspaceFileName
  let tmp_path = file_path + ".tmp"
  @fs.write_file(
    tmp_path,
    workspace_file_json(path, last_opened_unix).stringify(),
    create_mode=CreateOrTruncate,
  )
  @fs.rename(tmp_path, file_path, replace=true)
}

///|
async fn ensure_dir(dir : String) -> Unit {
  @fs.mkdir(dir, recursive=true) catch {
    // Already present — whether from an earlier open or a concurrent one —
    // is exactly the state this function ensures.
    @os_error.OSError(_) as error if error.is_EEXIST() => ()
    error => raise error
  }
}

///|
async fn[T] with_workspace_lock(dir : String, body : async () -> T) -> T {
  let file = @fs.open(
    dir + "/" + WorkspaceLockFileName,
    mode=ReadWrite,
    create_mode=OpenOrCreate,
  )
  defer file.close()
  file.lock(Exclusive)
  defer file.unlock()
  body()
}

///|
/// Open the workspace for the project directory at `path`, indexing it under
/// the home on first open and bumping its last-opened stamp otherwise.
/// `path` must name an existing directory and is canonicalized (symlinks
/// resolved), so every spelling of a directory opens the same workspace.
/// Distinct directories whose keys collide are kept apart by probing
/// `<key>-1`, `<key>-2`, … until the stored path matches or a free slot
/// claims the new entry. A `workspace.json` that exists but cannot be
/// decoded raises rather than being silently reclaimed: the slot belongs to
/// a workspace this function can no longer identify.
pub async fn WorkspaceHome::open(
  self : WorkspaceHome,
  path : String,
  now_unix~ : Int64,
) -> Workspace {
  let canonical = @fs.realpath(path)
  let key = workspace_key(canonical)
  let mut probe = 0
  for ;; {
    let dir = if probe == 0 {
      self.workspaces_dir() + "/" + key
    } else {
      self.workspaces_dir() + "/" + key + "-\{probe}"
    }
    ensure_dir(dir)
    let claimed = with_workspace_lock(dir, () => {
      if read_workspace_text(dir) is Some(text) &&
        decode_workspace_text(text).path != canonical {
        // Another workspace's slot (key collision): probe the next one.
        false
      } else {
        write_workspace_file(dir, canonical, now_unix)
        true
      }
    })
    if claimed {
      return { path: canonical }
    }
    probe += 1
  }
}

///|
/// One row of a workspace listing: the project path plus when it was last
/// opened.
struct WorkspaceListing {
  path : String
  last_opened_unix : Int64
} derive(Debug)

///|
/// The listed workspace's project directory.
pub fn WorkspaceListing::path(self : WorkspaceListing) -> String {
  self.path
}

///|
/// The directory holding the listed workspace's durable sessions — see
/// `Workspace::store_root`.
pub fn WorkspaceListing::store_root(self : WorkspaceListing) -> String {
  self.path + "/" + StoreDirName
}

///|
/// When the listed workspace was last opened, unix seconds.
pub fn WorkspaceListing::last_opened_unix(self : WorkspaceListing) -> Int64 {
  self.last_opened_unix
}

///|
/// Known workspaces, most recently opened first. Derived by scanning
/// `workspaces/*/workspace.json` — there is no single registry file to
/// maintain (or corrupt), and a deleted index entry simply disappears from
/// the listing. An entry whose `workspace.json` is missing or undecodable is
/// skipped: without it there is no path to show.
pub async fn WorkspaceHome::listings(
  self : WorkspaceHome,
) -> Array[WorkspaceListing] {
  let names = @fs.readdir(self.workspaces_dir(), sort=true) catch {
    @os_error.OSError(_) as error if error.is_ENOENT() => []
    error => raise error
  }
  let listings : Array[WorkspaceListing] = []
  for name in names {
    let dir = self.workspaces_dir() + "/" + name
    guard read_workspace_text(dir) is Some(text) else { continue }
    let file = decode_workspace_text(text) catch { _ => continue }
    listings.push({ path: file.path, last_opened_unix: file.last_opened_unix })
  }
  listings.sort_by((a, b) => b.last_opened_unix.compare(a.last_opened_unix))
  listings
}
