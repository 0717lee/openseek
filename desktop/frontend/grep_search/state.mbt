///|
const SearchDebounceMs : Int = 250

///|
const MaxSearchResults : Int = 20000

///|
/// Retire every query/result derived from the outgoing checkout. A fresh UUID
/// keeps an A -> B -> A transition from making an old reply current again,
/// while the armed Search mode and semantic settings survive the switch.
pub fn State::reset_checkout(self : State) -> State {
  { ..State::empty(), mode: self.mode, patterns: self.patterns }
}

///|
fn Input::root_text(self : Input) -> String {
  self.root.map(root => root.path).unwrap_or("")
}

///|
fn State::schedule(self : State, input : Input, immediate~ : Bool) -> State {
  let request_id = @uuid.mint()
  let has_query = match self.mode {
    Text => !self.query.is_empty()
    Semantic => self.patterns.any(pattern => !pattern.trim().is_empty())
  }
  if !has_query || input.root is None {
    {
      ..self,
      matches: [],
      semantic_hits: [],
      match_count: 0,
      file_count: 0,
      limit_hit: false,
      partial: false,
      visible_lines: InitialVisibleSearchLines,
      phase: Idle,
      request_id,
    }
  } else {
    {
      ..self,
      semantic_hits: if self.mode is Semantic {
        []
      } else {
        self.semantic_hits
      },
      match_count: if self.mode is Semantic {
        0
      } else {
        self.match_count
      },
      file_count: if self.mode is Semantic {
        0
      } else {
        self.file_count
      },
      visible_lines: InitialVisibleSearchLines,
      phase: if immediate {
        Loading
      } else {
        Debouncing
      },
      request_id,
      delay_ms: if immediate {
        0
      } else {
        SearchDebounceMs
      },
    }
  }
}

///|
/// Park host work because the current checkout disappeared. Ordinary UI
/// visibility changes intentionally do not call this: a search already issued
/// from the Explorer may settle while another inventory or tab is visible.
pub fn State::park(self : State) -> State {
  guard self.phase is Debouncing || self.phase is Loading else { return self }
  { ..self, phase: Idle, request_id: @uuid.mint() }
}

///|
pub fn State::handle(self : State, msg : Msg, input : Input) -> State {
  match msg {
    QueryChanged(query) => { ..self, query, }.schedule(input, immediate=false)
    ModeChanged(mode) =>
      {
        ..self,
        mode,
        details_open: self.details_open,
        matches: [],
        semantic_hits: [],
        match_count: 0,
        file_count: 0,
        partial: false,
        collapsed: Map([]),
      }.schedule(input, immediate=false)
    ToggleCaseSensitive =>
      { ..self, case_sensitive: !self.case_sensitive }.schedule(
        input,
        immediate=false,
      )
    ToggleWholeWord =>
      { ..self, whole_word: !self.whole_word }.schedule(input, immediate=false)
    ToggleRegex =>
      { ..self, regex: !self.regex }.schedule(input, immediate=false)
    ToggleDetails => { ..self, details_open: !self.details_open }
    IncludeChanged(include_glob) =>
      { ..self, include_glob, }.schedule(input, immediate=false)
    ExcludeChanged(exclude_glob) =>
      { ..self, exclude_glob, }.schedule(input, immediate=false)
    PatternChanged(index, value) => {
      let patterns = self.patterns.copy()
      if index < patterns.length() {
        patterns[index] = value
      }
      { ..self, patterns, }.schedule(input, immediate=false)
    }
    AddPattern => { ..self, patterns: self.patterns + [""] }
    RemovePattern(index) => {
      let patterns = self.patterns.copy()
      if index < patterns.length() && patterns.length() > 1 {
        let _ = patterns.remove(index)
      }
      { ..self, patterns, }.schedule(input, immediate=false)
    }
    Submit | Refresh => self.schedule(input, immediate=true)
    ClearResults => {
      let request_id = @uuid.mint()
      {
        ..self,
        matches: [],
        semantic_hits: [],
        match_count: 0,
        file_count: 0,
        limit_hit: false,
        partial: false,
        visible_lines: InitialVisibleSearchLines,
        phase: Idle,
        request_id,
      }
    }
    CollapseAll => {
      let collapsed : Map[String, Bool] = Map([])
      let active = match self.mode {
        Text => self.matches.map(result => result.path)
        Semantic => self.semantic_hits.map(hit => hit.path)
      }
      for path in active {
        collapsed[path] = true
      }
      { ..self, collapsed, }
    }
    ShowMore =>
      {
        ..self,
        visible_lines: (self.visible_lines + VisibleSearchLineStep).min(
          self.active_result_count(),
        ),
      }
    ToggleFile(path) => {
      let collapsed = self.collapsed.copy()
      if collapsed.get(path).unwrap_or(false) {
        collapsed.remove(path)
      } else {
        collapsed[path] = true
      }
      { ..self, collapsed, }
    }
    RequestStarted(request_id~) =>
      if self.request_id == request_id && self.phase is Debouncing {
        { ..self, phase: Loading }
      } else {
        self
      }
    Loaded(reply~) => {
      guard self.request_id == reply.request_id &&
        self.mode is Text &&
        reply.root == input.root_text() else {
        return self
      }
      if reply.cancelled {
        return { ..self, phase: Idle }
      }
      let phase = match reply.error {
        None => Ready
        Some(error) => Failed(code=error.code, message=error.message)
      }
      {
        ..self,
        matches: reply.matches,
        semantic_hits: [],
        match_count: reply.match_count,
        file_count: reply.file_count,
        limit_hit: reply.limit_hit,
        partial: false,
        visible_lines: InitialVisibleSearchLines.min(reply.matches.length()),
        phase,
      }
    }
    SemanticLoaded(reply~) => {
      guard self.request_id == reply.request_id &&
        self.mode is Semantic &&
        reply.root == input.root_text() else {
        return self
      }
      if reply.cancelled {
        return {
          ..self,
          semantic_hits: [],
          match_count: 0,
          file_count: 0,
          phase: Idle,
        }
      }
      let phase = match reply.error {
        None => Ready
        Some(error) => Failed(code=error.code, message=error.message)
      }
      {
        ..self,
        matches: [],
        semantic_hits: reply.matches,
        match_count: reply.match_count,
        file_count: reply.file_count,
        limit_hit: reply.limit_hit,
        partial: reply.partial,
        visible_lines: InitialVisibleSearchLines.min(reply.matches.length()),
        phase,
      }
    }
    SemanticProgress(
      request_id~,
      matches~,
      match_count~,
      file_count~
    ) => {
      // Partial rows are only meaningful for the search that is currently
      // in flight: once the final reply landed (Ready/Failed) or a newer
      // request started, late progress is stale and must not touch the
      // authoritative result set.
      guard self.request_id == request_id &&
        self.mode is Semantic &&
        self.phase is Loading else {
        return self
      }
      {
        ..self,
        semantic_hits: self.semantic_hits + matches,
        match_count,
        file_count,
      }
    }
    RequestFailed(request_id~, code~, message~) =>
      if self.request_id == request_id {
        {
          ..self,
          matches: [],
          semantic_hits: [],
          match_count: 0,
          file_count: 0,
          limit_hit: false,
          partial: false,
          visible_lines: InitialVisibleSearchLines,
          phase: Failed(code~, message~),
        }
      } else {
        self
      }
  }
}

///|
/// Project the retained Host results for `path` into the editor's one-based
/// UTF-16 coordinate space. OpenSeek's source viewer is read-only, so these
/// ranges stay authoritative for the search snapshot without duplicating
/// ripgrep's regex, case, and whole-word semantics in the frontend.
pub fn State::editor_highlights(
  self : State,
  path : String,
) -> EditorHighlights? {
  guard self.phase is Ready else { return None }
  let ranges : Array[@common.Range] = []
  match self.mode {
    Text =>
      for result in self.matches {
        if result.path == path {
          for range in result.ranges {
            ranges.push(
              @common.Range(
                result.line_number,
                range.start_column,
                result.line_number,
                range.end_column,
              ),
            )
          }
        }
      }
    Semantic =>
      for hit in self.semantic_hits {
        if hit.path == path {
          ranges.push(
            @common.Range(
              hit.start_line,
              hit.start_column,
              hit.end_line,
              hit.end_column,
            ),
          )
        }
      }
  }
  guard !ranges.is_empty() else { return None }
  Some({ ranges, })
}

///|
fn State::active_result_count(self : State) -> Int {
  match self.mode {
    Text => self.matches.length()
    Semantic => self.semantic_hits.length()
  }
}

///|
fn State::text_request_payload(
  self : State,
  input : Input,
) -> @protocol.SearchTextPayload? {
  guard self.mode is Text else { return None }
  guard input.root is Some(root) && !self.query.is_empty() else { return None }
  Some({
    root: root.path,
    query: self.query,
    regex: self.regex,
    case_sensitive: self.case_sensitive,
    whole_word: self.whole_word,
    include_glob: self.include_glob,
    exclude_glob: self.exclude_glob,
    request_id: self.request_id,
    max_results: MaxSearchResults,
  })
}

///|
fn State::semantic_request_payload(
  self : State,
  input : Input,
) -> @protocol.SearchSemanticPayload? {
  guard self.mode is Semantic else { return None }
  guard input.root is Some(root) else { return None }
  let patterns = self.patterns.filter(pattern => !pattern.trim().is_empty())
  guard !patterns.is_empty() else { return None }
  Some({
    root: root.path,
    patterns,
    include_glob: self.include_glob,
    exclude_glob: self.exclude_glob,
    request_id: self.request_id,
    max_results: MaxSearchResults,
  })
}

///|
test "checkout reset clears results while preserving the request UUID fence" {
  let input : Input = {
    owner: { channel: @interop.ChannelId::Local, session: "first", },
    root: Some(@common.Uri::parse("file:///work/a")),
  }
  let state = State::empty().handle(QueryChanged("moon"), input)
  let old_request_id = state.request_id
  let reset = state.reset_checkout()
  assert_eq(reset.query, "")
  assert_true(reset.matches.is_empty())
  assert_true(reset.phase is Idle)
  assert_true(reset.request_id != old_request_id)
}

///|
test "mode changes preserve each search input and shared details" {
  let input : Input = {
    owner: { channel: @interop.ChannelId::Local, session: "mode-state", },
    root: Some(@common.Uri::parse("file:///work")),
  }
  let state = State::empty()
    .handle(QueryChanged("text query"), input)
    .handle(IncludeChanged("src/**"), input)
    .handle(ExcludeChanged("generated/**"), input)
    .handle(ModeChanged(Semantic), input)
    .handle(PatternChanged(0, "inspect($(x:arg))"), input)
    .handle(AddPattern, input)
    .handle(PatternChanged(1, "match($x)"), input)
  let switched_back = state.handle(ModeChanged(Text), input)
  assert_eq(switched_back.query, "text query")
  assert_eq(switched_back.patterns, ["inspect($(x:arg))", "match($x)"])
  assert_eq(switched_back.include_glob, "src/**")
  assert_eq(switched_back.exclude_glob, "generated/**")
  assert_false(switched_back.details_open)
}

///|
test "query changes debounce and stale replies cannot replace the page" {
  let owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "one",
  }
  let root = @common.Uri::parse("file:///work")
  let input : Input = { owner, root: Some(root), }
  let state = State::empty().handle(QueryChanged("moon"), input)
  assert_true(state.phase is Debouncing)
  assert_eq(state.delay_ms, 250)
  let stale : @protocol.SearchTextReply = {
    root: root.path,
    request_id: "stale-request",
    matches: [],
    match_count: 0,
    file_count: 0,
    limit_hit: false,
    cancelled: false,
    error: None,
  }
  let unchanged = state.handle(Loaded(reply=stale), input)
  assert_true(unchanged == state)
}

///|
test "semantic progress streams partial hits and late progress is fenced" {
  let owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "semantic-progress",
  }
  let root = @common.Uri::parse("file:///work")
  let input : Input = { owner, root: Some(root), }
  let state = State::empty()
    .handle(ModeChanged(Semantic), input)
    .handle(PatternChanged(0, "inspect($(x:arg))"), input)
    .handle(Submit, input)
  let page = state
  assert_true(page.phase is Loading)
  let hit : @protocol.SemanticSearchHit = {
    path: "src/main.mbt",
    rule_id: "inspect",
    description: None,
    start_line: 1,
    start_column: 1,
    end_line: 1,
    end_column: 5,
    matched_source: "inspect(x)",
    source_context: [{ line: 1, text: "inspect(x)", is_match: true, }],
  }
  let streamed = state.handle(
    SemanticProgress(
      request_id=page.request_id,
      matches=[hit],
      match_count=1,
      file_count=1,
    ),
    input,
  )
  assert_eq(streamed.semantic_hits, [hit])
  assert_eq(streamed.match_count, 1)
  assert_eq(streamed.file_count, 1)
  // A progress frame for a previous request must not touch the page.
  let stale = state.handle(
    SemanticProgress(
      request_id="semantic-request-stale",
      matches=[hit],
      match_count=1,
      file_count=1,
    ),
    input,
  )
  assert_true(stale.semantic_hits.is_empty())
}

///|
test "semantic progress batches append only new hits" {
  let owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "semantic-batches",
  }
  let root = @common.Uri::parse("file:///work")
  let input : Input = { owner, root: Some(root), }
  let state = State::empty()
    .handle(ModeChanged(Semantic), input)
    .handle(PatternChanged(0, "inspect($(x:arg))"), input)
    .handle(Submit, input)
  let page = state
  let hit : @protocol.SemanticSearchHit = {
    path: "src/main.mbt",
    rule_id: "inspect",
    description: None,
    start_line: 1,
    start_column: 1,
    end_line: 1,
    end_column: 5,
    matched_source: "inspect(x)",
    source_context: [{ line: 1, text: "inspect(x)", is_match: true, }],
  }
  let second = { ..hit, start_line: 2, end_line: 2 }
  let first = state.handle(
    SemanticProgress(
      request_id=page.request_id,
      matches=[hit],
      match_count=1,
      file_count=1,
    ),
    input,
  )
  let streamed = first.handle(
    SemanticProgress(
      request_id=page.request_id,
      matches=[second],
      match_count=2,
      file_count=1,
    ),
    input,
  )
  assert_eq(streamed.semantic_hits, [hit, second])
}

///|
test "new semantic search clears partial results and cancellation clears them" {
  let owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "semantic-clear",
  }
  let root = @common.Uri::parse("file:///work")
  let input : Input = { owner, root: Some(root), }
  let state = State::empty()
    .handle(ModeChanged(Semantic), input)
    .handle(PatternChanged(0, "inspect($(x:arg))"), input)
    .handle(Submit, input)
  let page = state
  let hit : @protocol.SemanticSearchHit = {
    path: "src/main.mbt",
    rule_id: "inspect",
    description: None,
    start_line: 1,
    start_column: 1,
    end_line: 1,
    end_column: 5,
    matched_source: "inspect(x)",
    source_context: [{ line: 1, text: "inspect(x)", is_match: true, }],
  }
  let streamed = state.handle(
    SemanticProgress(
      request_id=page.request_id,
      matches=[hit],
      match_count=1,
      file_count=1,
    ),
    input,
  )
  let next = streamed.handle(PatternChanged(0, "match($x)"), input)
  assert_true(next.semantic_hits.is_empty())
  assert_eq(next.match_count, 0)
  let cancelled = streamed.handle(
    SemanticLoaded(reply={
      root: root.path,
      request_id: page.request_id,
      matches: [],
      match_count: 0,
      file_count: 0,
      limit_hit: false,
      cancelled: true,
      partial: false,
      error: None,
    }),
    input,
  )
  assert_true(cancelled.semantic_hits.is_empty())
  assert_eq(cancelled.match_count, 0)
}

///|
test "parking a checkout keeps its draft and fences the in-flight reply" {
  let owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "suspend",
  }
  let root = @common.Uri::parse("file:///work")
  let input : Input = { owner, root: Some(root), }
  let running = State::empty()
    .handle(QueryChanged("moon"), input)
    .handle(Submit, input)
  let old_request_id = running.request_id
  assert_true(running.phase is Loading)
  let suspended = running.park()
  assert_true(suspended.phase is Idle)
  assert_eq(suspended.query, "moon")
  assert_true(suspended.request_id != old_request_id)
  let stale : @protocol.SearchTextReply = {
    root: root.path,
    request_id: old_request_id,
    matches: [],
    match_count: 0,
    file_count: 0,
    limit_hit: false,
    cancelled: false,
    error: None,
  }
  let after_stale = suspended.handle(Loaded(reply=stale), input)
  assert_true(after_stale == suspended)
}

///|
test "refresh is immediate and loaded file groups can collapse and clear" {
  let owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "one",
  }
  let root = @common.Uri::parse("file:///work")
  let input : Input = { owner, root: Some(root), }
  let state = State::empty()
    .handle(QueryChanged("moon"), input)
    .handle(Refresh, input)
  let loading = state
  assert_true(loading.phase is Loading)
  assert_eq(loading.delay_ms, 0)
  let result : @protocol.TextSearchMatch = {
    path: "src/main.mbt",
    line_number: 2,
    preview: "moon moon",
    preview_start_column: 1,
    ranges: [
      { start_column: 1, end_column: 5, },
      { start_column: 6, end_column: 10, },
    ],
  }
  let reply : @protocol.SearchTextReply = {
    root: root.path,
    request_id: loading.request_id,
    matches: [result],
    match_count: 2,
    file_count: 1,
    limit_hit: false,
    cancelled: false,
    error: None,
  }
  let ready = state.handle(Loaded(reply~), input)
  assert_true(ready.phase is Ready)
  assert_eq(ready.match_count, 2)
  let collapsed = ready.handle(CollapseAll, input)
  assert_true(collapsed.collapsed.get("src/main.mbt").unwrap_or(false))
  let expanded = collapsed.handle(ToggleFile("src/main.mbt"), input)
  assert_false(expanded.collapsed.get("src/main.mbt").unwrap_or(false))
  let cleared = expanded.handle(ClearResults, input)
  assert_eq(cleared.query, "moon")
  assert_true(cleared.matches.is_empty())
  assert_true(cleared.phase is Idle)
}

///|
test "editor highlights include every retained match for the file" {
  let owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "editor-highlights",
  }
  let root = @common.Uri::parse("file:///work")
  let input : Input = { owner, root: Some(root), }
  let state = State::empty()
    .handle(QueryChanged("moon"), input)
    .handle(Submit, input)
  let reply : @protocol.SearchTextReply = {
    root: root.path,
    request_id: state.request_id,
    matches: [
      {
        path: "src/main.mbt",
        line_number: 2,
        preview: "moon moon",
        preview_start_column: 1,
        ranges: [
          { start_column: 1, end_column: 5, },
          { start_column: 6, end_column: 10, },
        ],
      },
      {
        path: "src/main.mbt",
        line_number: 7,
        preview: "moon",
        preview_start_column: 1,
        ranges: [{ start_column: 1, end_column: 5, }],
      },
      {
        path: "src/other.mbt",
        line_number: 1,
        preview: "moon",
        preview_start_column: 1,
        ranges: [{ start_column: 1, end_column: 5, }],
      },
    ],
    match_count: 4,
    file_count: 2,
    limit_hit: false,
    cancelled: false,
    error: None,
  }
  let ready = state.handle(Loaded(reply~), input)
  guard ready.editor_highlights("src/main.mbt") is Some(highlights) else {
    fail("main file should have editor highlights")
  }
  assert_eq(highlights.ranges(), [
    @common.Range(2, 1, 2, 5),
    @common.Range(2, 6, 2, 10),
    @common.Range(7, 1, 7, 5),
  ])
  assert_true(ready.editor_highlights("missing.mbt") is None)
  assert_true(
    ready
    .handle(QueryChanged("new query"), input)
    .editor_highlights("src/main.mbt")
    is None,
  )
}

///|
test "invalid regex replies retain their actionable Host error" {
  let owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "regex",
  }
  let root = @common.Uri::parse("file:///work")
  let input : Input = { owner, root: Some(root), }
  let state = State::empty()
    .handle(QueryChanged("("), input)
    .handle(ToggleRegex, input)
    .handle(Submit, input)
  let reply : @protocol.SearchTextReply = {
    root: root.path,
    request_id: state.request_id,
    matches: [],
    match_count: 0,
    file_count: 0,
    limit_hit: false,
    cancelled: false,
    error: Some({ code: "invalid_regex", message: "regex parse error", }),
  }
  let failed = state.handle(Loaded(reply~), input)
  guard failed.phase is Failed(code~, message~) else {
    fail("expected invalid regex phase")
  }
  assert_eq(code, "invalid_regex")
  assert_eq(message, "regex parse error")
}
