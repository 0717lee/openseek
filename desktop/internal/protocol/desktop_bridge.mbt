// Target-neutral wire types for the `openseek` desktop bridge. The native
// host and the JS frontend both use these definitions, so field names,
// optionality, and custom tagged encodings are one compiler-checked contract.

///|
/// An object payload for bridge operations that take no arguments.
pub(all) struct EmptyPayload {} derive(Debug, Eq)

///|
/// Engine placement inside WSL. An absent distro uses the user's default;
/// an absent engine uses `openseek` from the distro's PATH.
pub(all) struct WslPayload {
  distro : String?
  engine : String?
} derive(Debug, Eq)

///|
/// Start one engine run. Optional text is normalized by the frontend: present
/// values are trimmed and non-blank; absent values let the host choose its
/// configured default. `workspace` selects an attached project, while `wsl`
/// being present opts into WSL execution.
pub(all) struct StartPayload {
  task : String
  api_key : String?
  api_url : String?
  model : String?
  max_steps : Int?
  session : String?
  session_root : String?
  workspace : String?
  wsl : WslPayload?
} derive(Debug, Eq)

///|
/// The immediate result of accepting a start request. Progress and the final
/// answer continue over pushed engine events.
pub(all) struct StartReply {
  run_id : Int
  status : String
  exit_code : Int
} derive(Debug, Eq)

///|
/// Cancel a specific run, or the current run when `run_id` is absent.
pub(all) struct CancelPayload {
  run_id : Int?
} derive(Debug, Eq)

///|
/// Whether a live run accepted cancellation and the run it addressed.
pub(all) struct CancelReply {
  cancelled : Bool
  run_id : Int?
} derive(Debug, Eq)

///|
/// Deliver steering text to a specific run, or the current run when
/// `run_id` is absent.
pub(all) struct SteerPayload {
  text : String
  run_id : Int?
} derive(Debug, Eq)

///|
/// Whether a live run accepted the steering text and the run it addressed.
pub(all) struct SteerReply {
  steered : Bool
  run_id : Int?
} derive(Debug, Eq)

///|
/// Compact a durable conversation. It carries the same engine settings as a
/// start, minus the task, because a resumed conversation may need a fresh
/// serve process before compaction can begin.
pub(all) struct CompactPayload {
  session : String
  api_key : String?
  api_url : String?
  model : String?
  max_steps : Int?
  session_root : String?
  workspace : String?
  wsl : WslPayload?
} derive(Debug, Eq)

///|
/// Whether the compact command reached a live engine for the conversation.
/// Actual progress remains event-driven.
pub(all) struct CompactReply {
  compacting : Bool
} derive(Debug, Eq)

///|
/// The app-lifetime connect task only replies when its host pump disconnects.
pub(all) struct ConnectReply {
  disconnected : Bool
} derive(Debug, Eq)

///|
/// Load a durable session, optionally naming the workspace store that owns it.
/// Without the hint the host probes attached workspaces and the global store.
pub(all) struct LoadSessionPayload {
  session : String
  workspace : String?
} derive(Debug, Eq)

///|
/// One `list_sessions` group. An empty `workspace` denotes the global scratch
/// store; a failed group carries its message in `error` and an empty sessions
/// array so one broken workspace does not blank the whole sidebar.
pub(all) struct SessionGroup {
  workspace : String
  name : String
  session_root : String
  sessions : Json
  error : String
}

///|
/// All live or archived session stores, grouped by workspace.
pub(all) struct SessionsReply {
  groups : Array[SessionGroup]
}

///|
/// The engine's durable session document, forwarded without reshaping.
pub(all) struct LoadSessionReply {
  session : Json
}

///|
/// The project directory to attach to or detach from the workspace registry.
pub(all) struct WorkspacePayload {
  path : String
} derive(Debug, Eq)

///|
/// The current registry of attached project directories.
pub(all) struct WorkspacesReply {
  workspaces : Array[String]
} derive(Debug, Eq)

///|
/// The system folder picker's selection; absent means the user cancelled.
pub(all) struct PickWorkspaceReply {
  path : String?
} derive(Debug, Eq)

///|
/// Install one skill from the registry. `package_path` is absent for a module-
/// root skill and present for a skill subpackage.
pub(all) struct InstallSkillPayload {
  module_name : String
  version : String
  package_path : String?
} derive(Debug, Eq)

///|
/// Remove one registry-installed skill by its library id.
pub(all) struct UninstallSkillPayload {
  id : String
} derive(Debug, Eq)

///|
/// One installable skill reported by the registry catalog.
pub(all) struct MarketSkill {
  name : String
  module_name : String
  package_path : String
  version : String
  description : String
  author : String
  repository : String
} derive(Debug, Eq)

///|
/// One entry in the engine's global skills library.
pub(all) struct InstalledSkill {
  id : String
  name : String
  description : String
  source : String
} derive(Debug, Eq)

///|
/// The registry's installable skills.
pub(all) struct SkillsCatalogReply {
  skills : Array[MarketSkill]
} derive(Debug, Eq)

///|
/// The global skills library, including registry installs and hand-written
/// skills.
pub(all) struct InstalledSkillsReply {
  skills : Array[InstalledSkill]
} derive(Debug, Eq)

///|
/// The library entry created by an install operation.
pub(all) struct InstallSkillReply {
  installed : InstalledSkill
} derive(Debug, Eq)

///|
/// Whether an uninstall operation removed an entry.
pub(all) struct UninstallSkillReply {
  removed : Bool
} derive(Debug, Eq)

///|
/// Open a transcript-referenced file. A relative `path` is resolved against
/// `cwd` for a live run, or against the directory derived from `session` for a
/// resumed conversation. This user-clicked path is not workspace-contained.
pub(all) struct OpenPathPayload {
  session : String
  cwd : String
  path : String
} derive(Debug, Eq)

///|
/// Whether the file was handed to the system opener.
pub(all) struct OpenPathReply {
  opened : Bool
} derive(Debug, Eq)

///|
/// The release stream for update checks and downloads. Anything other than
/// literal `staging`, including an absent value, resolves to production.
pub(all) struct UpdateChannelPayload {
  channel : String?
} derive(Debug, Eq)

///|
/// A self-update check result, discriminated on the wire by `kind`. Outcomes
/// are data rather than rejected operations so the frontend can distinguish
/// routine offline failures from malformed or broken release metadata.
pub(all) enum CheckUpdateReply {
  UpToDate
  Available(version~ : String, installable~ : Bool)
  Unreachable(reason~ : String)
  Malformed(reason~ : String)
  Broken(version~ : String, reason~ : String)
} derive(Debug, Eq)

///|
/// The version now downloaded, verified, and staged for installation.
pub(all) struct DownloadUpdateReply {
  version : String
} derive(Debug, Eq)

///|
/// Whether the staged update was applied and the window may close.
pub(all) struct ApplyUpdateReply {
  applied : Bool
} derive(Debug, Eq)

///|
/// Ask for the git branch of the conversation's working directory. `cwd` is
/// used for a live run; an empty value falls back to `session`-derived state.
pub(all) struct WorkspaceBranchPayload {
  session : String
  cwd : String
} derive(Debug, Eq)

///|
/// The checked-out branch, or an empty string outside a repository or when git
/// is unavailable. Detached HEAD is reported as its short hash.
pub(all) struct WorkspaceBranchReply {
  branch : String
} derive(Debug, Eq)

///|
/// Move a durable session into or out of its store's `archived` twin.
pub(all) struct ArchiveSessionPayload {
  session : String
} derive(Debug, Eq)

///|
/// One launcher app detected as installed. `icon` is a `data:image/png` URL,
/// or empty when extraction failed and the frontend should show a fallback.
pub(all) struct AppEntry {
  id : String
  name : String
  icon : String
} derive(Debug, Eq)

///|
/// Installed launcher apps in catalog order.
pub(all) struct ListAppsReply {
  apps : Array[AppEntry]
} derive(Debug, Eq)

///|
/// Launch one detected app with the conversation's working directory. An
/// empty `cwd` falls back to the directory derived from `session`.
pub(all) struct LaunchAppPayload {
  session : String
  cwd : String
  app : String
} derive(Debug, Eq)

///|
/// Whether the app launcher accepted the directory.
pub(all) struct LaunchAppReply {
  launched : Bool
} derive(Debug, Eq)

///|
/// List one workspace-relative directory; an empty `path` names the workspace
/// root. `workspace` lets a fresh conversation browse before its durable
/// session record exists.
pub(all) struct ReadDirPayload {
  session : String
  path : String
  workspace : String?
} derive(Debug, Eq)

///|
/// One directory child, named relative to its requested parent.
pub(all) struct DirEntry {
  name : String
  is_dir : Bool
} derive(Debug, Eq)

///|
/// Directory children, sorted by the host with directories first.
pub(all) struct ReadDirReply {
  entries : Array[DirEntry]
} derive(Debug, Eq)

///|
/// Enumerate every file under a conversation workspace for the editor's fuzzy
/// file finder. `workspace` is the same fresh-conversation hint used by
/// `ReadDirPayload`.
pub(all) struct ListFilesPayload {
  session : String
  workspace : String?
} derive(Debug, Eq)

///|
/// Workspace-relative `/`-separated file paths. `truncated` means the host hit
/// its index cap and stopped, so the snapshot is partial.
pub(all) struct ListFilesReply {
  files : Array[String]
  truncated : Bool
} derive(Debug, Eq)

///|
/// Read one workspace-relative file, optionally using a fresh-conversation
/// workspace hint.
pub(all) struct ReadFilePayload {
  session : String
  path : String
  workspace : String?
} derive(Debug, Eq)

///|
/// A file read result, discriminated on the wire by `kind`. Withheld binary or
/// oversized files carry no address. Content includes the host-resolved
/// absolute path and opaque mtime signature used by later stat comparisons.
pub(all) enum ReadFileReply {
  Binary
  Oversized
  Content(content~ : String, absolute~ : String, sig~ : String)
} derive(Debug, Eq)

///|
/// Stat the open editor tabs in one request. Paths are workspace-relative and
/// use the same resolution rules as `ReadFilePayload`.
pub(all) struct StatFilesPayload {
  session : String
  paths : Array[String]
  workspace : String?
} derive(Debug, Eq)

///|
/// One file's opaque mtime signature. An empty signature means the file is
/// missing or no longer resolves; the frontend compares signatures only for
/// equality.
pub(all) struct FileStat {
  path : String
  sig : String
} derive(Debug, Eq)

///|
/// Signatures for the files the host could address from the batch request.
pub(all) struct StatFilesReply {
  stats : Array[FileStat]
} derive(Debug, Eq)

///|
/// Point the host's single workspace watcher at this conversation. An empty
/// `session` parks the watcher when the editor panel closes.
pub(all) struct WatchWorkspacePayload {
  session : String
  workspace : String?
} derive(Debug, Eq)

///|
/// A coarse workspace-change push. It intentionally carries only the watched
/// root; the frontend re-stats tabs and re-lists expanded directories.
pub(all) struct FsChangedPayload {
  root : String
} derive(Debug, Eq)

///|
/// Ask the language server for hover at a zero-based position in an absolute
/// path. The host accepts only paths inside an attached workspace.
pub(all) struct LspHoverPayload {
  path : String
  line : Int
  character : Int
} derive(Debug, Eq)

///|
/// A flat hover reply. Empty `value` means no hover. The four zero-based
/// position fields are valid only when `has_range` is true.
pub(all) struct LspHoverReply {
  value : String
  markdown : Bool
  has_range : Bool
  start_line : Int
  start_character : Int
  end_line : Int
  end_character : Int
} derive(Debug, Eq)

///|
/// Tell the host that the editor is showing this absolute path, opening or
/// syncing it in the language server and enabling diagnostics pushes.
pub(all) struct LspOpenPayload {
  path : String
} derive(Debug, Eq)

///|
/// The language server's current raw LSP diagnostics array for an opened file.
pub(all) struct LspDiagnosticsReply {
  diagnostics : Json
}

///|
/// A diagnostics push for one absolute path. `diagnostics` has the same raw LSP
/// shape as `LspDiagnosticsReply`.
pub(all) struct DiagnosticsPush {
  path : String
  diagnostics : Json
}

///|
/// Search the conversation workspace's language-server symbol index. The
/// optional workspace hint supports conversations without durable state yet.
pub(all) struct WorkspaceSymbolsPayload {
  session : String
  query : String
  workspace : String?
} derive(Debug, Eq)

///|
/// A zero-based line and column in a symbol location.
pub(all) struct SymbolPosition {
  line : Int
  col : Int
} derive(Debug, Eq)

///|
/// A symbol's zero-based LSP-shaped source range.
pub(all) struct SymbolRange {
  start : SymbolPosition
  end : SymbolPosition
} derive(Debug, Eq)

///|
/// One workspace-symbol match. `path` is workspace-relative; `kind` is the raw
/// LSP SymbolKind and `container` is absent for top-level symbols. An all-zero
/// range represents a location for which the server supplied no range.
pub(all) struct SymbolItem {
  name : String
  kind : Int?
  container : String?
  path : String
  range : SymbolRange
} derive(Debug, Eq)

///|
/// Workspace symbol matches, capped by the host.
pub(all) struct WorkspaceSymbolsReply {
  symbols : Array[SymbolItem]
} derive(Debug, Eq)
