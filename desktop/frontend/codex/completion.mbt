// Codex composer completion. Slash commands call dedicated app-server
// methods; `#` searches files through app-server and sends selected entries as
// native `UserInput::Mention` values. OpenSeek's symbol/skill envelope is a
// different protocol and stays in the parent frontend package.

///|
priv enum CodexCompletionKind {
  CodexCommands
  CodexFiles
} derive(Eq)

///|
priv struct CodexCompletionItem {
  label : String
  detail : String
  command : String
  name : String
  path : String
} derive(Eq)

///|
priv enum CodexMention {
  CodexFileMention(name~ : String, path~ : String)
  CodexEditorAnnotation(
    file~ : String,
    range~ : @common.Range,
    quote~ : String,
    comment~ : String
  )
} derive(Eq)

///|
priv struct CodexCompletion {
  kind : CodexCompletionKind
  items : Array[CodexCompletionItem]
  selected : Int
  loading : Bool
  draft_without_token : String
} derive(Eq)

///|
priv struct CodexCompletionTrigger {
  kind : CodexCompletionKind
  query : String
  draft_without_token : String
}

///|
priv struct CodexFileSearchOwner {
  thread_id : String
  cwd : String
  query : String
} derive(Eq)

///|
priv struct CodexFileSearchCache {
  owner : CodexFileSearchOwner?
  items : Array[CodexCompletionItem]
} derive(Eq)

///|
fn CodexFileSearchCache::empty() -> CodexFileSearchCache {
  { owner: None, items: [] }
}

///|
fn CodexCompletionItem::commands() -> Array[CodexCompletionItem] {
  [
    {
      label: "/compact",
      detail: "Summarize and shrink this conversation's context",
      command: "compact",
      name: "",
      path: "",
    },
    {
      label: "/review",
      detail: "Review staged, unstaged, and untracked changes",
      command: "review",
      name: "",
      path: "",
    },
  ]
}

///|
fn CodexCompletionItem::decode_file(value : Json) -> CodexCompletionItem? {
  guard value is Object(fields) &&
    @jsonx.json_text(fields, "match_type") is Some("file") &&
    @jsonx.json_text(fields, "file_name") is Some(name) &&
    @jsonx.json_text(fields, "path") is Some(path) else {
    return None
  }
  Some({ label: name, detail: path, command: "", name, path })
}

///|
fn CodexCompletionTrigger::parse(text : String) -> CodexCompletionTrigger? {
  if text =~ (re"^/", after=query) && query =~ re"^[^[:space:]]*$" {
    return Some({
      kind: CodexCommands,
      query: query.to_owned(),
      draft_without_token: "",
    })
  }
  guard text =~ (re"#[^[:space:]]*$" as token, before=draft) &&
    (draft.is_empty() || draft =~ re"[[:space:]]$") &&
    token =~ (re"^#", after=query) else {
    return None
  }
  Some({
    kind: CodexFiles,
    query: query.to_owned(),
    draft_without_token: draft.to_owned(),
  })
}

///|
fn CodexCompletionTrigger::matches(
  self : CodexCompletionTrigger,
  fields : Array[String],
) -> Bool {
  let query = self.query.trim().to_owned().to_lower()
  if query.is_empty() {
    return true
  }
  for field in fields {
    if field.to_lower().contains(query) {
      return true
    }
  }
  false
}

///|
fn State::file_search_owner(
  self : State,
  query : String,
) -> CodexFileSearchOwner? {
  guard self.active is Some(active) &&
    active.cwd is Some(cwd) &&
    !cwd.trim().is_empty() else {
    return None
  }
  Some({ thread_id: active.id, cwd, query })
}

///|
fn CodexCompletion::for_draft(state : State, text : String) -> CodexCompletion? {
  guard CodexCompletionTrigger::parse(text) is Some(trigger) else {
    return None
  }
  match trigger.kind {
    CodexCommands => {
      let items = CodexCompletionItem::commands().filter(item => {
        trigger.matches([item.label, item.detail])
      })
      if items.is_empty() {
        None
      } else {
        Some({
          kind: CodexCommands,
          items,
          selected: 0,
          loading: false,
          draft_without_token: trigger.draft_without_token,
        })
      }
    }
    CodexFiles => {
      let owner = state.file_search_owner(trigger.query)
      // Never offer a row cached for another task/cwd: Enter may accept while
      // the new search is still in flight, and a relative path only has meaning
      // under the exact root that produced it.
      let items = if owner is Some(_) && state.file_search.owner == owner {
        state.file_search.items.filter(item => {
          trigger.matches([item.name, item.path])
        })
      } else {
        []
      }
      Some({
        kind: CodexFiles,
        items,
        selected: 0,
        loading: owner is Some(_) && state.file_search.owner != owner,
        draft_without_token: trigger.draft_without_token,
      })
    }
  }
}

///|
fn CodexCompletion::shifted(
  self : CodexCompletion,
  delta : Int,
) -> CodexCompletion {
  let count = self.items.length()
  if count == 0 {
    return self
  }
  { ..self, selected: (self.selected + delta + count) % count }
}

///|
fn CodexCompletion::current(self : CodexCompletion) -> CodexCompletionItem? {
  self.items.get(self.selected)
}

///|
fn State::with_mention(self : State, item : CodexCompletionItem) -> State {
  let mentions = self.mentions.copy()
  let mention = CodexFileMention(name=item.name, path=item.path)
  if !mentions.contains(mention) {
    mentions.push(mention)
  }
  guard self.completion is Some(completion) else {
    return { ..self, mentions, completion: None }
  }
  { ..self, draft: completion.draft_without_token, mentions, completion: None }
}

///|
fn State::without_mention(self : State, index : Int) -> State {
  guard self.mentions.get(index) is Some(_) else { return self }
  let mentions = self.mentions.copy()
  let _ = mentions.remove(index)
  { ..self, mentions, }
}

///|
fn State::input_empty(self : State) -> Bool {
  self.draft.trim().is_empty() && self.mentions.is_empty()
}

///|
fn State::with_files(
  self : State,
  owner : CodexFileSearchOwner,
  items : Array[CodexCompletionItem],
) -> State {
  guard self.active is Some(active) &&
    active.id == owner.thread_id &&
    active.cwd == Some(owner.cwd) &&
    CodexCompletionTrigger::parse(self.draft) is Some(trigger) &&
    trigger.kind is CodexFiles &&
    trigger.query == owner.query else {
    return self
  }
  let next = { ..self, file_search: { owner: Some(owner), items } }
  { ..next, completion: CodexCompletion::for_draft(next, next.draft) }
}

///|
fn State::change_draft(
  self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  value : String,
) -> (@cmd.Cmd, State) {
  let next = { ..self, draft: value }
  let completion = CodexCompletion::for_draft(next, value)
  let command = if CodexCompletionTrigger::parse(value) is Some(trigger) &&
    trigger.kind is CodexFiles &&
    next.file_search_owner(trigger.query) is Some(owner) &&
    next.file_search.owner != Some(owner) {
    next.search_files(dispatch, channel, owner)
  } else {
    @cmd.none
  }
  (command, { ..next, completion, })
}

///|
fn State::accept_completion(
  self : State,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  item : CodexCompletionItem,
) -> (@cmd.Cmd, State) {
  guard self.completion is Some(completion) else { return (@cmd.none, self) }
  match completion.kind {
    CodexFiles => (@cmd.none, self.with_mention(item))
    CodexCommands => {
      let original = self.draft
      let command = match item.command {
        "compact" => self.compact(dispatch, channel, original)
        "review" => self.review(dispatch, channel, original)
        _ => @cmd.none
      }
      (
        command,
        {
          ..self,
          completion: None,
          loading: item.command == "compact" || item.command == "review",
          notice: "",
        },
      )
    }
  }
}
