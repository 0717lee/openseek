// Workspace Search is one file-editor Explorer inventory. This package owns
// its query reducer, request, and view; fileeditor owns the active checkout and
// resets the inventory at the same owner/root boundaries as Files and Changes.

///|
/// Keep the initial DOM comfortably below the Host's 20,000-occurrence result
/// ceiling. The full reply and counts stay available; users reveal additional
/// matching lines explicitly instead of constructing tens of thousands of
/// nodes in one render.
const InitialVisibleSearchLines : Int = 500

///|
const VisibleSearchLineStep : Int = 500

///|
enum Phase {
  Idle
  Debouncing
  Loading
  Ready
  Failed(code~ : String, message~ : String)
} derive(Eq, Debug)

///|
/// One of the two Search engines, modeled on semgrep's search modes: plain
/// text search runs the Host's bundled ripgrep; semantic search runs
/// moongrep's structural MoonBit code patterns.
enum Mode {
  Text
  Semantic
} derive(Eq, Debug)

///|
struct State {
  mode : Mode
  query : String
  regex : Bool
  case_sensitive : Bool
  whole_word : Bool
  details_open : Bool
  include_glob : String
  exclude_glob : String
  patterns : Array[String]
  matches : Array[@protocol.TextSearchMatch]
  semantic_hits : Array[@protocol.SemanticSearchHit]
  match_count : Int
  file_count : Int
  limit_hit : Bool
  partial : Bool
  collapsed : Map[String, Bool]
  visible_lines : Int
  phase : Phase
  request_id : String
  delay_ms : Int
} derive(Eq)

///|
/// The workspace-search matches that belong on one open editor model. The
/// ranges are the complete retained result set for the file.
struct EditorHighlights {
  ranges : Array[@common.Range]
} derive(Eq, Debug)

///|
pub fn EditorHighlights::ranges(
  self : EditorHighlights,
) -> Array[@common.Range] {
  self.ranges
}

///|
pub fn State::empty() -> State {
  {
    mode: Text,
    query: "",
    regex: false,
    case_sensitive: false,
    whole_word: false,
    details_open: false,
    include_glob: "",
    exclude_glob: "",
    patterns: [""],
    matches: [],
    semantic_hits: [],
    match_count: 0,
    file_count: 0,
    limit_hit: false,
    partial: false,
    collapsed: Map([]),
    visible_lines: InitialVisibleSearchLines,
    phase: Idle,
    request_id: @uuid.mint(),
    delay_ms: SearchDebounceMs,
  }
}

///|
/// The UUID the next reply must carry. Production replies arrive through
/// `subscription`; this exists so the owning file-editor package's tests can
/// hand the state a `Loaded` reply without reaching into it.
pub fn State::request_id(self : State) -> String {
  self.request_id
}

///|
pub(all) struct Input {
  owner : @interop.ConversationKey
  root : @common.Uri?
} derive(Eq)

///|
pub fn Input::Input(
  owner~ : @interop.ConversationKey,
  root~ : @common.Uri?,
) -> Input {
  { owner, root, }
}

///|
pub(all) enum Msg {
  QueryChanged(String)
  ModeChanged(Mode)
  ToggleCaseSensitive
  ToggleWholeWord
  ToggleRegex
  ToggleDetails
  IncludeChanged(String)
  ExcludeChanged(String)
  // Semantic-mode settings, mirroring the text-mode toggles.
  PatternChanged(Int, String)
  AddPattern
  RemovePattern(Int)
  Submit
  Refresh
  ClearResults
  CollapseAll
  ShowMore
  ToggleFile(String)
  RequestStarted(request_id~ : String)
  // The Host echoes the request UUID it answers inside the reply.
  Loaded(reply~ : @protocol.SearchTextReply)
  SemanticLoaded(reply~ : @protocol.SearchSemanticReply)
  // One partial batch of a semantic search still in flight. The Host pushes
  // these through the notification channel so a long scan paints hits early;
  // the final `SemanticLoaded` reply replaces them. The request UUID fences
  // the stream exactly like the reply does.
  SemanticProgress(
    request_id~ : String,
    matches~ : Array[@protocol.SemanticSearchHit],
    match_count~ : Int,
    file_count~ : Int
  )
  RequestFailed(request_id~ : String, code~ : String, message~ : String)
}

///|
pub extend EditorHighlights with Debug::{to_repr}

///|
pub extend EditorHighlights with Eq::{equal, not_equal}

///|
pub extend Input with Eq::{equal, not_equal}

///|
pub extend Mode with Debug::{to_repr}

///|
pub extend Mode with Eq::{equal, not_equal}

///|
pub extend Phase with Debug::{to_repr}

///|
pub extend Phase with Eq::{equal, not_equal}

///|
pub extend State with Eq::{equal, not_equal}
