// Concrete command replies. Each enum describes that command's real outcomes;
// the private wire structs retain the existing JSON object layout so older
// desktop pages and relay clients keep working across an update.

///|
fn Json::failed_command_reply(message : String) -> Json {
  { "error": message }
}

///|
fn Json::command_reply_error(self : Json) -> String? {
  if self is Object(fields) && fields.get("error") is Some(String(message)) {
    Some(message)
  } else {
    None
  }
}

///|
/// Unit-shaped replies still use the established `{}` / `{error}` wire
/// format. This validation belongs only to that JSON boundary; callers work
/// with each command's concrete enum below.
fn Json::expect_command_reply_object(
  self : Json,
  path : @json.JsonPath,
) -> Unit raise @json.JsonDecodeError {
  guard self is Object(fields) else {
    raise JsonDecodeError((path, "expected command reply object"))
  }
  if fields.get("error") is Some(error) && !(error is String(_)) {
    raise JsonDecodeError(
      (path.add_key("error"), "command error must be a string"),
    )
  }
}

///|
pub(all) enum CancelSearchFilesReply {
  FileSearchCancelled
  CancelSearchFilesError(String)
} derive(Debug, Eq)

///|
pub impl ToJson for CancelSearchFilesReply with fn to_json(self) {
  match self {
    FileSearchCancelled => Json::empty_object()
    CancelSearchFilesError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for CancelSearchFilesReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  match json.command_reply_error() {
    Some(message) => CancelSearchFilesError(message)
    None => FileSearchCancelled
  }
}

///|
pub(all) enum ClearFileSearchCacheReply {
  FileSearchCacheCleared
  ClearFileSearchCacheError(String)
} derive(Debug, Eq)

///|
pub impl ToJson for ClearFileSearchCacheReply with fn to_json(self) {
  match self {
    FileSearchCacheCleared => Json::empty_object()
    ClearFileSearchCacheError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for ClearFileSearchCacheReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  match json.command_reply_error() {
    Some(message) => ClearFileSearchCacheError(message)
    None => FileSearchCacheCleared
  }
}

///|
pub(all) enum WatchReply {
  FileWatchStarted
  FileWatchError(String)
} derive(Debug, Eq)

///|
pub impl ToJson for WatchReply with fn to_json(self) {
  match self {
    FileWatchStarted => Json::empty_object()
    FileWatchError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for WatchReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  match json.command_reply_error() {
    Some(message) => FileWatchError(message)
    None => FileWatchStarted
  }
}

///|
pub(all) enum UnwatchReply {
  FileWatchStopped
  FileUnwatchError(String)
} derive(Debug, Eq)

///|
pub impl ToJson for UnwatchReply with fn to_json(self) {
  match self {
    FileWatchStopped => Json::empty_object()
    FileUnwatchError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for UnwatchReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  match json.command_reply_error() {
    Some(message) => FileUnwatchError(message)
    None => FileWatchStopped
  }
}

///|
pub(all) enum TerminalInputReply {
  TerminalInputAccepted
  TerminalInputError(String)
} derive(Debug, Eq)

///|
pub impl ToJson for TerminalInputReply with fn to_json(self) {
  match self {
    TerminalInputAccepted => Json::empty_object()
    TerminalInputError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for TerminalInputReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  match json.command_reply_error() {
    Some(message) => TerminalInputError(message)
    None => TerminalInputAccepted
  }
}

///|
pub(all) enum TerminalResizeReply {
  TerminalResized
  TerminalResizeError(String)
} derive(Debug, Eq)

///|
pub impl ToJson for TerminalResizeReply with fn to_json(self) {
  match self {
    TerminalResized => Json::empty_object()
    TerminalResizeError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for TerminalResizeReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  match json.command_reply_error() {
    Some(message) => TerminalResizeError(message)
    None => TerminalResized
  }
}

///|
pub(all) enum TerminalAckReply {
  TerminalOutputAcknowledged
} derive(Debug, Eq)

///|
pub impl ToJson for TerminalAckReply with fn to_json(self) {
  match self {
    TerminalOutputAcknowledged => Json::empty_object()
  }
}

///|
pub impl FromJson for TerminalAckReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  TerminalOutputAcknowledged
}

///|
pub(all) enum TerminalCloseReply {
  TerminalClosed
} derive(Debug, Eq)

///|
pub impl ToJson for TerminalCloseReply with fn to_json(self) {
  match self {
    TerminalClosed => Json::empty_object()
  }
}

///|
pub impl FromJson for TerminalCloseReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  TerminalClosed
}

///|
pub(all) enum HostConnectReply {
  HostConnected
  HostConnectError(String)
} derive(Debug, Eq)

///|
pub impl ToJson for HostConnectReply with fn to_json(self) {
  match self {
    HostConnected => Json::empty_object()
    HostConnectError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for HostConnectReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  match json.command_reply_error() {
    Some(message) => HostConnectError(message)
    None => HostConnected
  }
}

///|
pub(all) enum BrowserOpenReply {
  BrowserOpened
  BrowserOpenError(String)
} derive(Debug, Eq)

///|
pub impl ToJson for BrowserOpenReply with fn to_json(self) {
  match self {
    BrowserOpened => Json::empty_object()
    BrowserOpenError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for BrowserOpenReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  match json.command_reply_error() {
    Some(message) => BrowserOpenError(message)
    None => BrowserOpened
  }
}

///|
pub(all) enum BrowserNavigateReply {
  BrowserNavigated
  BrowserNavigateError(String)
} derive(Debug, Eq)

///|
pub impl ToJson for BrowserNavigateReply with fn to_json(self) {
  match self {
    BrowserNavigated => Json::empty_object()
    BrowserNavigateError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for BrowserNavigateReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  match json.command_reply_error() {
    Some(message) => BrowserNavigateError(message)
    None => BrowserNavigated
  }
}

///|
pub(all) enum BrowserBackReply {
  BrowserWentBack
  BrowserBackError(String)
} derive(Debug, Eq)

///|
pub impl ToJson for BrowserBackReply with fn to_json(self) {
  match self {
    BrowserWentBack => Json::empty_object()
    BrowserBackError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for BrowserBackReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  match json.command_reply_error() {
    Some(message) => BrowserBackError(message)
    None => BrowserWentBack
  }
}

///|
pub(all) enum BrowserForwardReply {
  BrowserWentForward
  BrowserForwardError(String)
} derive(Debug, Eq)

///|
pub impl ToJson for BrowserForwardReply with fn to_json(self) {
  match self {
    BrowserWentForward => Json::empty_object()
    BrowserForwardError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for BrowserForwardReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  match json.command_reply_error() {
    Some(message) => BrowserForwardError(message)
    None => BrowserWentForward
  }
}

///|
pub(all) enum BrowserReloadReply {
  BrowserReloaded
  BrowserReloadError(String)
} derive(Debug, Eq)

///|
pub impl ToJson for BrowserReloadReply with fn to_json(self) {
  match self {
    BrowserReloaded => Json::empty_object()
    BrowserReloadError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for BrowserReloadReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  match json.command_reply_error() {
    Some(message) => BrowserReloadError(message)
    None => BrowserReloaded
  }
}

///|
pub(all) enum OpenDevtoolsReply {
  DevtoolsOpened
  OpenDevtoolsError(String)
} derive(Debug, Eq)

///|
pub impl ToJson for OpenDevtoolsReply with fn to_json(self) {
  match self {
    DevtoolsOpened => Json::empty_object()
    OpenDevtoolsError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for OpenDevtoolsReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  match json.command_reply_error() {
    Some(message) => OpenDevtoolsError(message)
    None => DevtoolsOpened
  }
}

///|
pub(all) enum BrowserBoundsReply {
  BrowserBoundsSet
  BrowserBoundsError(String)
} derive(Debug, Eq)

///|
pub impl ToJson for BrowserBoundsReply with fn to_json(self) {
  match self {
    BrowserBoundsSet => Json::empty_object()
    BrowserBoundsError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for BrowserBoundsReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  match json.command_reply_error() {
    Some(message) => BrowserBoundsError(message)
    None => BrowserBoundsSet
  }
}

///|
pub(all) enum BrowserVisibleReply {
  BrowserVisibilitySet
  BrowserVisibilityError(String)
} derive(Debug, Eq)

///|
pub impl ToJson for BrowserVisibleReply with fn to_json(self) {
  match self {
    BrowserVisibilitySet => Json::empty_object()
    BrowserVisibilityError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for BrowserVisibleReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  match json.command_reply_error() {
    Some(message) => BrowserVisibilityError(message)
    None => BrowserVisibilitySet
  }
}

///|
pub(all) enum BrowserCloseReply {
  BrowserClosed
  BrowserCloseError(String)
} derive(Debug, Eq)

///|
pub impl ToJson for BrowserCloseReply with fn to_json(self) {
  match self {
    BrowserClosed => Json::empty_object()
    BrowserCloseError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for BrowserCloseReply with fn from_json(json, path) {
  json.expect_command_reply_object(path)
  match json.command_reply_error() {
    Some(message) => BrowserCloseError(message)
    None => BrowserClosed
  }
}

///|
pub(all) enum StartReply {
  Started(run_id~ : String, status~ : String, exit_code~ : Int)
  StartError(String)
}

///|
pub impl ToJson for StartReply with fn to_json(self) {
  match self {
    Started(run_id~, status~, exit_code~) =>
      ToJson::to_json(({ run_id, status, exit_code } : StartWire))
    StartError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for StartReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    StartError(message)
  } else {
    let reply : StartWire = @json.from_json(json)
    Started(run_id=reply.run_id, status=reply.status, exit_code=reply.exit_code)
  }
}

///|
pub(all) enum CancelReply {
  Cancelled(run_id~ : String?)
  NoRunToCancel
  CancelError(String)
}

///|
pub impl ToJson for CancelReply with fn to_json(self) {
  match self {
    Cancelled(run_id~) =>
      ToJson::to_json(({ cancelled: true, run_id } : CancelWire))
    NoRunToCancel =>
      ToJson::to_json(({ cancelled: false, run_id: None } : CancelWire))
    CancelError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for CancelReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    return CancelError(message)
  }
  let reply : CancelWire = @json.from_json(json)
  if reply.cancelled {
    Cancelled(run_id=reply.run_id)
  } else {
    NoRunToCancel
  }
}

///|
pub(all) enum SteerReply {
  Steered(run_id~ : String?)
  NothingToSteer
  SteerError(String)
}

///|
pub impl ToJson for SteerReply with fn to_json(self) {
  match self {
    Steered(run_id~) => ToJson::to_json(({ steered: true, run_id } : SteerWire))
    NothingToSteer =>
      ToJson::to_json(({ steered: false, run_id: None } : SteerWire))
    SteerError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for SteerReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    return SteerError(message)
  }
  let reply : SteerWire = @json.from_json(json)
  if reply.steered {
    Steered(run_id=reply.run_id)
  } else {
    NothingToSteer
  }
}

///|
pub(all) enum CompactReply {
  CompactionRequested
  CompactError(String)
}

///|
pub impl ToJson for CompactReply with fn to_json(self) {
  match self {
    CompactionRequested => ToJson::to_json(({ compacting: true } : CompactWire))
    CompactError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for CompactReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    CompactError(message)
  } else {
    let _reply : CompactWire = @json.from_json(json)
    CompactionRequested
  }
}

///|
pub(all) enum GoalReply {
  GoalDelivered
  GoalError(String)
}

///|
pub impl ToJson for GoalReply with fn to_json(self) {
  match self {
    GoalDelivered => ToJson::to_json(({ delivered: true } : GoalWire))
    GoalError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for GoalReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    GoalError(message)
  } else {
    let _reply : GoalWire = @json.from_json(json)
    GoalDelivered
  }
}

///|
pub(all) enum RunsReply {
  Runs(runs~ : Array[StartedPayload], settled~ : Array[RunSettlementPayload])
}

///|
pub impl ToJson for RunsReply with fn to_json(self) {
  match self {
    Runs(runs~, settled~) => ToJson::to_json(({ runs, settled } : RunsWire))
  }
}

///|
pub impl FromJson for RunsReply with fn from_json(json, _path) {
  let reply : RunsWire = @json.from_json(json)
  Runs(runs=reply.runs, settled=reply.settled)
}

///|
pub(all) enum SessionsReply {
  Sessions(groups~ : Array[SessionGroup])
  SessionsError(String)
}

///|
pub impl ToJson for SessionsReply with fn to_json(self) {
  match self {
    Sessions(groups~) => ToJson::to_json(({ groups, } : SessionsWire))
    SessionsError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for SessionsReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    SessionsError(message)
  } else {
    let reply : SessionsWire = @json.from_json(json)
    Sessions(groups=reply.groups)
  }
}

///|
pub(all) enum LoadSessionReply {
  SessionLoaded(session~ : SessionDocument, watermark~ : Int?)
  SessionLoadError(String)
}

///|
pub impl ToJson for LoadSessionReply with fn to_json(self) {
  match self {
    SessionLoaded(session~, watermark~) =>
      ToJson::to_json(({ session, watermark } : LoadSessionWire))
    SessionLoadError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for LoadSessionReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    SessionLoadError(message)
  } else {
    let reply : LoadSessionWire = @json.from_json(json)
    SessionLoaded(session=reply.session, watermark=reply.watermark)
  }
}

///|
pub(all) enum SettingsStatusReply {
  SettingsStatus(SettingsStatusPayload)
  SettingsError(String)
}

///|
pub impl ToJson for SettingsStatusReply with fn to_json(self) {
  match self {
    SettingsStatus(status) => status.to_json()
    SettingsError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for SettingsStatusReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    SettingsError(message)
  } else {
    SettingsStatus(@json.from_json(json))
  }
}

///|
pub(all) enum AppInfoReply {
  AppInfo(version~ : String)
}

///|
pub impl ToJson for AppInfoReply with fn to_json(self) {
  match self {
    AppInfo(version~) => ToJson::to_json(({ version, } : AppInfoWire))
  }
}

///|
pub impl FromJson for AppInfoReply with fn from_json(json, _path) {
  let reply : AppInfoWire = @json.from_json(json)
  AppInfo(version=reply.version)
}

///|
pub(all) enum WorktreesReply {
  Worktrees(worktrees~ : Array[WorktreeInfo])
  WorktreesError(String)
}

///|
pub impl ToJson for WorktreesReply with fn to_json(self) {
  match self {
    Worktrees(worktrees~) => ToJson::to_json(({ worktrees, } : WorktreesWire))
    WorktreesError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for WorktreesReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    WorktreesError(message)
  } else {
    let reply : WorktreesWire = @json.from_json(json)
    Worktrees(worktrees=reply.worktrees)
  }
}

///|
pub(all) enum WorktreeCreateReply {
  WorktreeCreated(name~ : String, worktrees~ : Array[WorktreeInfo])
  WorktreeCreateError(String)
}

///|
pub impl ToJson for WorktreeCreateReply with fn to_json(self) {
  match self {
    WorktreeCreated(name~, worktrees~) =>
      ToJson::to_json(({ name, worktrees } : WorktreeCreateWire))
    WorktreeCreateError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for WorktreeCreateReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    WorktreeCreateError(message)
  } else {
    let reply : WorktreeCreateWire = @json.from_json(json)
    WorktreeCreated(name=reply.name, worktrees=reply.worktrees)
  }
}

///|
pub(all) enum AuthStatusReply {
  AuthStatus(AuthStatusPayload)
  AuthError(String)
}

///|
pub impl ToJson for AuthStatusReply with fn to_json(self) {
  match self {
    AuthStatus(status) => status.to_json()
    AuthError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for AuthStatusReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    AuthError(message)
  } else {
    AuthStatus(@json.from_json(json))
  }
}

///|
pub(all) enum ReadDirReply {
  DirectoryEntries(entries~ : Array[DirEntry])
  ReadDirectoryError(String)
}

///|
pub impl ToJson for ReadDirReply with fn to_json(self) {
  match self {
    DirectoryEntries(entries~) => ToJson::to_json(({ entries, } : ReadDirWire))
    ReadDirectoryError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for ReadDirReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    ReadDirectoryError(message)
  } else {
    let reply : ReadDirWire = @json.from_json(json)
    DirectoryEntries(entries=reply.entries)
  }
}

///|
pub(all) enum SearchFilesReply {
  SearchResults(
    files~ : Array[String],
    from_cache~ : Bool,
    limit_hit~ : Bool,
    cancelled~ : Bool
  )
  SearchFilesError(String)
}

///|
pub impl ToJson for SearchFilesReply with fn to_json(self) {
  match self {
    SearchResults(files~, from_cache~, limit_hit~, cancelled~) =>
      ToJson::to_json(
        ({ files, from_cache, limit_hit, cancelled } : SearchFilesWire),
      )
    SearchFilesError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for SearchFilesReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    SearchFilesError(message)
  } else {
    let reply : SearchFilesWire = @json.from_json(json)
    SearchResults(
      files=reply.files,
      from_cache=reply.from_cache,
      limit_hit=reply.limit_hit,
      cancelled=reply.cancelled,
    )
  }
}

///|
pub(all) enum StatFilesReply {
  FileStats(stats~ : Array[FileStat])
  StatFilesError(String)
}

///|
pub impl ToJson for StatFilesReply with fn to_json(self) {
  match self {
    FileStats(stats~) => ToJson::to_json(({ stats, } : StatFilesWire))
    StatFilesError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for StatFilesReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    StatFilesError(message)
  } else {
    let reply : StatFilesWire = @json.from_json(json)
    FileStats(stats=reply.stats)
  }
}

///|
pub(all) enum TerminalOpenReply {
  TerminalOpened(id~ : Int)
  TerminalOpenError(String)
}

///|
pub impl ToJson for TerminalOpenReply with fn to_json(self) {
  match self {
    TerminalOpened(id~) => ToJson::to_json(({ id, } : TerminalOpenWire))
    TerminalOpenError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for TerminalOpenReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    TerminalOpenError(message)
  } else {
    let reply : TerminalOpenWire = @json.from_json(json)
    TerminalOpened(id=reply.id)
  }
}

///|
pub(all) enum LspDiagnosticsReply {
  Diagnostics(diagnostics~ : Array[LspDiagnostic]?)
  DiagnosticsError(String)
}

///|
pub impl ToJson for LspDiagnosticsReply with fn to_json(self) {
  match self {
    Diagnostics(diagnostics~) =>
      ToJson::to_json(({ diagnostics, } : LspDiagnosticsWire))
    DiagnosticsError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for LspDiagnosticsReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    DiagnosticsError(message)
  } else {
    let reply : LspDiagnosticsWire = @json.from_json(json)
    Diagnostics(diagnostics=reply.diagnostics)
  }
}

///|
pub(all) enum LspHoverReply {
  Hover(
    value~ : String,
    markdown~ : Bool,
    has_range~ : Bool,
    start_line~ : Int,
    start_character~ : Int,
    end_line~ : Int,
    end_character~ : Int
  )
  HoverError(String)
}

///|
pub impl ToJson for LspHoverReply with fn to_json(self) {
  match self {
    Hover(
      value~,
      markdown~,
      has_range~,
      start_line~,
      start_character~,
      end_line~,
      end_character~
    ) =>
      ToJson::to_json(
        (
          {
            value,
            markdown,
            has_range,
            start_line,
            start_character,
            end_line,
            end_character,
          } : LspHoverWire),
      )
    HoverError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for LspHoverReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    return HoverError(message)
  }
  let reply : LspHoverWire = @json.from_json(json)
  Hover(
    value=reply.value,
    markdown=reply.markdown,
    has_range=reply.has_range,
    start_line=reply.start_line,
    start_character=reply.start_character,
    end_line=reply.end_line,
    end_character=reply.end_character,
  )
}

///|
pub(all) enum WorkspaceSymbolsReply {
  WorkspaceSymbols(symbols~ : Array[SymbolItem])
  WorkspaceSymbolsError(String)
}

///|
pub impl ToJson for WorkspaceSymbolsReply with fn to_json(self) {
  match self {
    WorkspaceSymbols(symbols~) =>
      ToJson::to_json(({ symbols, } : WorkspaceSymbolsWire))
    WorkspaceSymbolsError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for WorkspaceSymbolsReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    WorkspaceSymbolsError(message)
  } else {
    let reply : WorkspaceSymbolsWire = @json.from_json(json)
    WorkspaceSymbols(symbols=reply.symbols)
  }
}

///|
pub(all) enum MoonIdeLocationsReply {
  Locations(locations~ : Array[MoonIdeLocation])
  NavigationError(String)
}

///|
pub impl ToJson for MoonIdeLocationsReply with fn to_json(self) {
  match self {
    Locations(locations~) =>
      ToJson::to_json(({ locations, } : MoonIdeLocationsWire))
    NavigationError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for MoonIdeLocationsReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    NavigationError(message)
  } else {
    let reply : MoonIdeLocationsWire = @json.from_json(json)
    Locations(locations=reply.locations)
  }
}

///|
pub(all) enum SkillsCatalogReply {
  SkillsCatalog(skills~ : Array[MarketSkill])
  SkillsCatalogError(String)
}

///|
pub impl ToJson for SkillsCatalogReply with fn to_json(self) {
  match self {
    SkillsCatalog(skills~) => ToJson::to_json(({ skills, } : SkillsCatalogWire))
    SkillsCatalogError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for SkillsCatalogReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    SkillsCatalogError(message)
  } else {
    let reply : SkillsCatalogWire = @json.from_json(json)
    SkillsCatalog(skills=reply.skills)
  }
}

///|
pub(all) enum InstalledSkillsReply {
  InstalledSkills(skills~ : Array[InstalledSkill])
  InstalledSkillsError(String)
}

///|
pub impl ToJson for InstalledSkillsReply with fn to_json(self) {
  match self {
    InstalledSkills(skills~) =>
      ToJson::to_json(({ skills, } : InstalledSkillsWire))
    InstalledSkillsError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for InstalledSkillsReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    InstalledSkillsError(message)
  } else {
    let reply : InstalledSkillsWire = @json.from_json(json)
    InstalledSkills(skills=reply.skills)
  }
}

///|
pub(all) enum InstallSkillReply {
  SkillInstalled(installed~ : InstalledSkill)
  SkillInstallError(String)
}

///|
pub impl ToJson for InstallSkillReply with fn to_json(self) {
  match self {
    SkillInstalled(installed~) =>
      ToJson::to_json(({ installed, } : InstallSkillWire))
    SkillInstallError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for InstallSkillReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    SkillInstallError(message)
  } else {
    let reply : InstallSkillWire = @json.from_json(json)
    SkillInstalled(installed=reply.installed)
  }
}

///|
pub(all) enum UninstallSkillReply {
  SkillRemoved
  SkillUninstallError(String)
}

///|
pub impl ToJson for UninstallSkillReply with fn to_json(self) {
  match self {
    SkillRemoved => ToJson::to_json(({ removed: true } : UninstallSkillWire))
    SkillUninstallError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for UninstallSkillReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    SkillUninstallError(message)
  } else {
    let _reply : UninstallSkillWire = @json.from_json(json)
    SkillRemoved
  }
}

///|
pub(all) enum DownloadUpdateReply {
  DownloadAccepted
  DownloadError(String)
}

///|
pub impl ToJson for DownloadUpdateReply with fn to_json(self) {
  match self {
    DownloadAccepted =>
      ToJson::to_json(({ accepted: true } : DownloadUpdateWire))
    DownloadError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for DownloadUpdateReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    DownloadError(message)
  } else {
    let _reply : DownloadUpdateWire = @json.from_json(json)
    DownloadAccepted
  }
}

///|
pub(all) enum ApplyUpdateReply {
  UpdateApplied
  UpdateApplyError(String)
}

///|
pub impl ToJson for ApplyUpdateReply with fn to_json(self) {
  match self {
    UpdateApplied => ToJson::to_json(({ applied: true } : ApplyUpdateWire))
    UpdateApplyError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for ApplyUpdateReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    UpdateApplyError(message)
  } else {
    let _reply : ApplyUpdateWire = @json.from_json(json)
    UpdateApplied
  }
}

///|
pub(all) enum ListAppsReply {
  Apps(apps~ : Array[AppEntry])
  AppListError(String)
}

///|
pub impl ToJson for ListAppsReply with fn to_json(self) {
  match self {
    Apps(apps~) => ToJson::to_json(({ apps, } : ListAppsWire))
    AppListError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for ListAppsReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    AppListError(message)
  } else {
    let reply : ListAppsWire = @json.from_json(json)
    Apps(apps=reply.apps)
  }
}

///|
pub(all) enum LaunchAppReply {
  AppLaunched
  AppLaunchError(String)
}

///|
pub impl ToJson for LaunchAppReply with fn to_json(self) {
  match self {
    AppLaunched => ToJson::to_json(({ launched: true } : LaunchAppWire))
    AppLaunchError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for LaunchAppReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    AppLaunchError(message)
  } else {
    let _reply : LaunchAppWire = @json.from_json(json)
    AppLaunched
  }
}

///|
pub(all) enum GitBranchReply {
  GitBranch(branch~ : String?, diffstat~ : GitDiffStat?)
  GitBranchError(String)
}

///|
pub impl ToJson for GitBranchReply with fn to_json(self) {
  match self {
    GitBranch(branch~, diffstat~) =>
      ToJson::to_json(({ branch, diffstat } : GitBranchWire))
    GitBranchError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for GitBranchReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    GitBranchError(message)
  } else {
    let reply : GitBranchWire = @json.from_json(json)
    GitBranch(branch=reply.branch, diffstat=reply.diffstat)
  }
}

///|
pub(all) enum GitPullRequestReply {
  GitPullRequest(
    pull_request~ : GitPullRequest?,
    compare_url~ : String?,
    branch~ : String?
  )
  GitPullRequestError(String)
}

///|
pub impl ToJson for GitPullRequestReply with fn to_json(self) {
  match self {
    GitPullRequest(pull_request~, compare_url~, branch~) =>
      ToJson::to_json(
        ({ pull_request, compare_url, branch } : GitPullRequestWire),
      )
    GitPullRequestError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for GitPullRequestReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    GitPullRequestError(message)
  } else {
    let reply : GitPullRequestWire = @json.from_json(json)
    GitPullRequest(
      pull_request=reply.pull_request,
      compare_url=reply.compare_url,
      branch=reply.branch,
    )
  }
}

///|
pub(all) enum GitChangesReply {
  // The active checkout's inventory and immutable comparison identities.
  // Older hosts can omit either identity; callers fall back from `baseline`
  // to `head` when choosing the review revision.
  GitChanges(head~ : String?, baseline~ : String?, changes~ : Array[GitChange])
  // Git is unavailable or the workspace is not inside a repository.
  NotRepository
  GitChangesError(String)
}

///|
pub impl ToJson for GitChangesReply with fn to_json(self) {
  match self {
    GitChanges(head~, baseline~, changes~) => {
      let fields : Map[String, Json] = Map::from_array([
        ("repository", Json::boolean(true)),
        ("changes", changes.to_json()),
      ])
      fields["head"] = match head {
        Some(head) => Json::string(head)
        None => Json::null()
      }
      fields["baseline"] = match baseline {
        Some(baseline) => Json::string(baseline)
        None => Json::null()
      }
      Json::object(fields)
    }
    NotRepository =>
      {
        "repository": false,
        "head": Json::null(),
        "baseline": Json::null(),
        "changes": [],
      }
    GitChangesError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for GitChangesReply with fn from_json(json, path) {
  if json.command_reply_error() is Some(message) {
    return GitChangesError(message)
  }
  guard json is Object(fields) else {
    raise JsonDecodeError((path, "expected Git changes reply"))
  }
  match fields.get("repository") {
    Some(False) => NotRepository
    Some(True) => {
      let head = match fields.get("head") {
        Some(String(head)) => Some(head)
        _ => None
      }
      let baseline = match fields.get("baseline") {
        Some(String(baseline)) => Some(baseline)
        _ => None
      }
      guard fields.get("changes") is Some(changes) else {
        raise JsonDecodeError(
          (path.add_key("changes"), "expected Git change inventory"),
        )
      }
      GitChanges(
        head~,
        baseline~,
        changes=@json.from_json(changes, path=path.add_key("changes")),
      )
    }
    _ => raise JsonDecodeError((path, "expected Git changes reply"))
  }
}

///|
pub(all) enum OpenPathReply {
  PathOpened
  OpenPathError(String)
}

///|
pub impl ToJson for OpenPathReply with fn to_json(self) {
  match self {
    PathOpened => ToJson::to_json(({ opened: true } : OpenPathWire))
    OpenPathError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for OpenPathReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    OpenPathError(message)
  } else {
    let _reply : OpenPathWire = @json.from_json(json)
    PathOpened
  }
}

///|
pub(all) enum OpenExternalReply {
  ExternalOpened
  OpenExternalError(String)
}

///|
pub impl ToJson for OpenExternalReply with fn to_json(self) {
  match self {
    ExternalOpened => ToJson::to_json(({ opened: true } : OpenExternalWire))
    OpenExternalError(message) => Json::failed_command_reply(message)
  }
}

///|
pub impl FromJson for OpenExternalReply with fn from_json(json, _path) {
  if json.command_reply_error() is Some(message) {
    OpenExternalError(message)
  } else {
    let _reply : OpenExternalWire = @json.from_json(json)
    ExternalOpened
  }
}
