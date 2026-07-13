// Hand-written JSON codecs for the file editor and language-server bridge
// contract. Payload optionals are omitted on encode; tolerant batch replies
// keep a strict outer shape while dropping malformed rows.

///|
pub impl ToJson for ReadDirPayload with fn to_json(self) {
  let fields : Map[String, Json] = Map([
    ("session", self.session.to_json()),
    ("path", self.path.to_json()),
  ])
  @jsonx.put_optional(fields, "workspace", self.workspace)
  Json::object(fields)
}

///|
pub impl FromJson for ReadDirPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    session: @jsonx.required_string(fields, path, "session"),
    path: @jsonx.required_string(fields, path, "path"),
    workspace: @jsonx.optional(fields, path, "workspace"),
  }
}

///|
pub impl ToJson for DirEntry with fn to_json(self) {
  @jsonx.object([
    ("name", self.name.to_json()),
    ("is_dir", self.is_dir.to_json()),
  ])
}

///|
pub impl FromJson for DirEntry with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    name: @jsonx.required_string(fields, path, "name"),
    is_dir: @jsonx.required_bool(fields, path, "is_dir"),
  }
}

///|
pub impl ToJson for ReadDirReply with fn to_json(self) {
  @jsonx.object([("entries", self.entries.to_json())])
}

///|
pub impl FromJson for ReadDirReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  let decoded : Array[DirEntry] = @jsonx.tolerant_rows(fields, path, "entries")
  { entries: decoded.filter(entry => !entry.name.is_empty()) }
}

///|
pub impl ToJson for ListFilesPayload with fn to_json(self) {
  let fields : Map[String, Json] = Map([("session", self.session.to_json())])
  @jsonx.put_optional(fields, "workspace", self.workspace)
  Json::object(fields)
}

///|
pub impl FromJson for ListFilesPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    session: @jsonx.required_string(fields, path, "session"),
    workspace: @jsonx.optional(fields, path, "workspace"),
  }
}

///|
pub impl ToJson for ListFilesReply with fn to_json(self) {
  @jsonx.object([
    ("files", self.files.to_json()),
    ("truncated", self.truncated.to_json()),
  ])
}

///|
pub impl FromJson for ListFilesReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  guard fields.get("files") is Some(Array(values)) else {
    return @jsonx.decode_error(path.add_key("files"), "expected array")
  }
  let files : Array[String] = []
  for value in values {
    if value is String(file) && !file.is_empty() {
      files.push(file)
    }
  }
  { files, truncated: fields.get("truncated") is Some(True) }
}

///|
pub impl ToJson for ReadFilePayload with fn to_json(self) {
  let fields : Map[String, Json] = Map([
    ("session", self.session.to_json()),
    ("path", self.path.to_json()),
  ])
  @jsonx.put_optional(fields, "workspace", self.workspace)
  Json::object(fields)
}

///|
pub impl FromJson for ReadFilePayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    session: @jsonx.required_string(fields, path, "session"),
    path: @jsonx.required_string(fields, path, "path"),
    workspace: @jsonx.optional(fields, path, "workspace"),
  }
}

///|
pub impl ToJson for ReadFileReply with fn to_json(self) {
  match self {
    Binary => @jsonx.object([("kind", "binary".to_json())])
    Oversized => @jsonx.object([("kind", "oversized".to_json())])
    Content(content~, absolute~, sig~) =>
      @jsonx.object([
        ("kind", "content".to_json()),
        ("content", content.to_json()),
        ("absolute", absolute.to_json()),
        ("sig", sig.to_json()),
      ])
  }
}

///|
pub impl FromJson for ReadFileReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  match @jsonx.required_string(fields, path, "kind") {
    "binary" => Binary
    "oversized" => Oversized
    "content" => {
      let absolute = @jsonx.required_string(fields, path, "absolute")
      guard !absolute.is_empty() else {
        return @jsonx.decode_error(path.add_key("absolute"), "expected path")
      }
      Content(
        content=@jsonx.required_string(fields, path, "content"),
        absolute~,
        sig=@jsonx.required_string(fields, path, "sig"),
      )
    }
    kind => @jsonx.decode_error(path.add_key("kind"), "unknown kind: \{kind}")
  }
}

///|
pub impl ToJson for StatFilesPayload with fn to_json(self) {
  let fields : Map[String, Json] = Map([
    ("session", self.session.to_json()),
    ("paths", self.paths.to_json()),
  ])
  @jsonx.put_optional(fields, "workspace", self.workspace)
  Json::object(fields)
}

///|
pub impl FromJson for StatFilesPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    session: @jsonx.required_string(fields, path, "session"),
    paths: @jsonx.required(fields, path, "paths"),
    workspace: @jsonx.optional(fields, path, "workspace"),
  }
}

///|
pub impl ToJson for FileStat with fn to_json(self) {
  @jsonx.object([("path", self.path.to_json()), ("sig", self.sig.to_json())])
}

///|
pub impl FromJson for FileStat with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    path: @jsonx.required_string(fields, path, "path"),
    sig: @jsonx.required_string(fields, path, "sig"),
  }
}

///|
pub impl ToJson for StatFilesReply with fn to_json(self) {
  @jsonx.object([("stats", self.stats.to_json())])
}

///|
pub impl FromJson for StatFilesReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  let decoded : Array[FileStat] = @jsonx.tolerant_rows(fields, path, "stats")
  { stats: decoded.filter(stat => !stat.path.is_empty()) }
}

///|
pub impl ToJson for WatchWorkspacePayload with fn to_json(self) {
  let fields : Map[String, Json] = Map([("session", self.session.to_json())])
  @jsonx.put_optional(fields, "workspace", self.workspace)
  Json::object(fields)
}

///|
pub impl FromJson for WatchWorkspacePayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    session: @jsonx.required_string(fields, path, "session"),
    workspace: @jsonx.optional(fields, path, "workspace"),
  }
}

///|
pub impl ToJson for FsChangedPayload with fn to_json(self) {
  @jsonx.object([("root", self.root.to_json())])
}

///|
pub impl FromJson for FsChangedPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  // The frontend deliberately ignores `root` and refreshes the conversation
  // that is current when the event arrives. Preserve its previous decoder's
  // tolerance for a missing or malformed field.
  { root: @jsonx.json_text(fields, "root").unwrap_or("") }
}

///|
pub impl ToJson for LspHoverPayload with fn to_json(self) {
  @jsonx.object([
    ("path", self.path.to_json()),
    ("line", self.line.to_json()),
    ("character", self.character.to_json()),
  ])
}

///|
pub impl FromJson for LspHoverPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    path: @jsonx.required_string(fields, path, "path"),
    line: @jsonx.required(fields, path, "line"),
    character: @jsonx.required(fields, path, "character"),
  }
}

///|
pub impl ToJson for LspHoverReply with fn to_json(self) {
  @jsonx.object([
    ("value", self.value.to_json()),
    ("markdown", self.markdown.to_json()),
    ("has_range", self.has_range.to_json()),
    ("start_line", self.start_line.to_json()),
    ("start_character", self.start_character.to_json()),
    ("end_line", self.end_line.to_json()),
    ("end_character", self.end_character.to_json()),
  ])
}

///|
pub impl FromJson for LspHoverReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  let start_line = @jsonx.json_int(fields, "start_line")
  let start_character = @jsonx.json_int(fields, "start_character")
  let end_line = @jsonx.json_int(fields, "end_line")
  let end_character = @jsonx.json_int(fields, "end_character")
  let has_range = fields.get("has_range") is Some(True) &&
    start_line is Some(_) &&
    start_character is Some(_) &&
    end_line is Some(_) &&
    end_character is Some(_)
  {
    value: @jsonx.required_string(fields, path, "value"),
    markdown: fields.get("markdown") is Some(True),
    has_range,
    start_line: start_line.unwrap_or(0),
    start_character: start_character.unwrap_or(0),
    end_line: end_line.unwrap_or(0),
    end_character: end_character.unwrap_or(0),
  }
}

///|
pub impl ToJson for LspOpenPayload with fn to_json(self) {
  @jsonx.object([("path", self.path.to_json())])
}

///|
pub impl FromJson for LspOpenPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { path: @jsonx.required_string(fields, path, "path") }
}

///|
pub impl ToJson for LspDiagnosticsReply with fn to_json(self) {
  @jsonx.object([("diagnostics", self.diagnostics)])
}

///|
pub impl FromJson for LspDiagnosticsReply with fn from_json(json, _path) {
  let diagnostics = if json is Object(fields) &&
    fields.get("diagnostics") is Some(diagnostics) {
    diagnostics
  } else {
    []
  }
  { diagnostics, }
}

///|
pub impl ToJson for DiagnosticsPush with fn to_json(self) {
  @jsonx.object([
    ("path", self.path.to_json()),
    ("diagnostics", self.diagnostics),
  ])
}

///|
pub impl FromJson for DiagnosticsPush with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  let diagnostics = fields.get("diagnostics").unwrap_or([])
  let file = @jsonx.required_string(fields, path, "path")
  guard !file.is_empty() else {
    return @jsonx.decode_error(
      path.add_key("path"),
      "expected non-empty string",
    )
  }
  { path: file, diagnostics }
}

///|
pub impl ToJson for WorkspaceSymbolsPayload with fn to_json(self) {
  let fields : Map[String, Json] = Map([
    ("session", self.session.to_json()),
    ("query", self.query.to_json()),
  ])
  @jsonx.put_optional(fields, "workspace", self.workspace)
  Json::object(fields)
}

///|
pub impl FromJson for WorkspaceSymbolsPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    session: @jsonx.required_string(fields, path, "session"),
    query: @jsonx.required_string(fields, path, "query"),
    workspace: @jsonx.optional(fields, path, "workspace"),
  }
}

///|
pub impl ToJson for SymbolPosition with fn to_json(self) {
  @jsonx.object([("line", self.line.to_json()), ("col", self.col.to_json())])
}

///|
pub impl FromJson for SymbolPosition with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  guard @jsonx.json_int(fields, "line") is Some(line) else {
    return @jsonx.decode_error(path.add_key("line"), "expected number")
  }
  guard @jsonx.json_int(fields, "col") is Some(col) else {
    return @jsonx.decode_error(path.add_key("col"), "expected number")
  }
  { line, col }
}

///|
pub impl ToJson for SymbolRange with fn to_json(self) {
  @jsonx.object([("start", self.start.to_json()), ("end", self.end.to_json())])
}

///|
pub impl FromJson for SymbolRange with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    start: @jsonx.required(fields, path, "start"),
    end: @jsonx.required(fields, path, "end"),
  }
}

///|
pub impl ToJson for SymbolItem with fn to_json(self) {
  let fields : Map[String, Json] = Map([
    ("name", self.name.to_json()),
    ("path", self.path.to_json()),
    ("range", self.range.to_json()),
  ])
  @jsonx.put_optional(fields, "kind", self.kind)
  @jsonx.put_optional(fields, "container", self.container)
  Json::object(fields)
}

///|
pub impl FromJson for SymbolItem with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    name: @jsonx.required_string(fields, path, "name"),
    // Both fields were tolerant in the frontend decoder: a malformed
    // optional value is the same as an omitted one and must not discard an
    // otherwise usable symbol row.
    kind: @jsonx.json_int(fields, "kind"),
    container: @jsonx.json_text(fields, "container"),
    path: @jsonx.required_string(fields, path, "path"),
    range: @jsonx.required(fields, path, "range"),
  }
}

///|
pub impl ToJson for WorkspaceSymbolsReply with fn to_json(self) {
  @jsonx.object([("symbols", self.symbols.to_json())])
}

///|
pub impl FromJson for WorkspaceSymbolsReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  let decoded : Array[SymbolItem] = @jsonx.tolerant_rows(
    fields, path, "symbols",
  )
  { symbols: decoded.filter(symbol => !symbol.name.is_empty()) }
}
