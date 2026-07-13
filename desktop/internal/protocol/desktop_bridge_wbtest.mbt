///|
test "desktop payloads round-trip and omit absent fields" {
  let payload : StartPayload = {
    task: "ship it",
    api_key: None,
    api_url: Some("https://example.test"),
    model: None,
    max_steps: Some(12),
    session: Some("session-1"),
    session_root: None,
    workspace: None,
    wsl: Some({ distro: None, engine: None }),
  }
  let decoded : StartPayload = @json.from_json(payload.to_json())
  assert_eq(decoded, payload)
  guard payload.to_json() is Object(fields) else {
    fail("start payload did not encode as an object")
  }
  assert_true(fields.get("api_key") is None)
  assert_true(fields.get("model") is None)
  assert_true(fields.get("session_root") is None)
  assert_true(fields.get("workspace") is None)
  guard fields.get("wsl") is Some(Object(wsl)) else {
    fail("enabled WSL payload was omitted")
  }
  assert_eq(wsl.length(), 0)

  let empty = EmptyPayload::{  }
  guard empty.to_json() is Object(empty_fields) else {
    fail("empty payload did not encode as an object")
  }
  assert_eq(empty_fields.length(), 0)
  let decoded_empty : EmptyPayload = @json.from_json(null)
  assert_eq(decoded_empty, empty)
}

///|
test "custom tagged replies round-trip their stable wire shape" {
  let update_cases : Array[CheckUpdateReply] = [
    UpToDate,
    Available(version="1.2.3", installable=true),
    Unreachable(reason="offline"),
    Malformed(reason="not json"),
    Broken(version="2.0.0", reason="bad signature"),
  ]
  for reply in update_cases {
    let decoded : CheckUpdateReply = @json.from_json(reply.to_json())
    assert_eq(decoded, reply)
  }
  assert_true(UpToDate.to_json() is { "kind": String("up_to_date"), .. })
  assert_true(
    Available(version="1.2.3", installable=true).to_json()
    is {
      "kind": String("available"),
      "version": String("1.2.3"),
      "installable": True,
      ..
    },
  )

  let file_cases : Array[ReadFileReply] = [
    Binary,
    Oversized,
    Content(content="hello", absolute="/tmp/main.mbt", sig="1:2"),
  ]
  for reply in file_cases {
    let decoded : ReadFileReply = @json.from_json(reply.to_json())
    assert_eq(decoded, reply)
  }
}

///|
test "batch replies retain tolerant row decoding" {
  let apps : ListAppsReply = @json.from_json({
    "apps": [
      { "id": "editor", "name": "", "icon": "data:image/png;base64,x" },
      { "id": "", "name": "missing", "icon": "" },
      { "id": "broken" },
      "not an object",
    ],
  })
  assert_eq(apps.apps.length(), 1)
  assert_eq(apps.apps[0].id, "editor")
  assert_eq(apps.apps[0].name, "")

  let workspaces : WorkspacesReply = @json.from_json({
    "workspaces": ["/work/a", 7, "", "/work/b"],
  })
  assert_eq(workspaces.workspaces, ["/work/a", "/work/b"])

  let files : ListFilesReply = @json.from_json({
    "files": ["src/main.mbt", 1, ""],
  })
  assert_eq(files.files, ["src/main.mbt"])
  assert_false(files.truncated)

  let sessions : SessionsReply = @json.from_json({
    "groups": [
      { "workspace": "/work/a", "name": "a", "sessions": [] },
      { "workspace": "/work/b", "name": "b", "sessions": 42 },
      { "workspace": "/work/c", "sessions": [] },
    ],
  })
  assert_eq(sessions.groups.length(), 1)
  assert_eq(sessions.groups[0].workspace, "/work/a")
  assert_eq(sessions.groups[0].session_root, "")
  assert_eq(sessions.groups[0].error, "")
}

///|
test "LSP replies preserve frontend fallback semantics" {
  let hover : LspHoverReply = @json.from_json({
    "value": "symbol docs",
    "has_range": true,
    "start_line": 1,
    "start_character": 2,
    "end_line": 3,
  })
  assert_false(hover.markdown)
  assert_false(hover.has_range)
  assert_eq(hover.start_line, 1)
  assert_eq(hover.end_character, 0)

  let diagnostics : LspDiagnosticsReply = @json.from_json({ "unexpected": true })
  assert_true(diagnostics.diagnostics is Array([]))

  let symbols : WorkspaceSymbolsReply = @json.from_json({
    "symbols": [
      {
        "name": "parse_hover",
        "kind": "not a number",
        "container": null,
        "path": "src/main.mbt",
        "range": {
          "start": { "line": 1, "col": 2 },
          "end": { "line": 1, "col": 8 },
        },
      },
    ],
  })
  assert_eq(symbols.symbols.length(), 1)
  assert_true(symbols.symbols[0].kind is None)
  assert_true(symbols.symbols[0].container is None)
}

///|
test "pushes and command replies preserve malformed-field tolerance" {
  let steer : SteerReply = @json.from_json({
    "steered": true,
    "run_id": "not a number",
  })
  assert_true(steer.steered)
  assert_true(steer.run_id is None)

  let diagnostics : DiagnosticsPush = @json.from_json({ "path": "/tmp/a.mbt" })
  assert_true(diagnostics.diagnostics is Array([]))

  let changed : FsChangedPayload = @json.from_json({ "root": null })
  assert_eq(changed.root, "")

  let position : SymbolPosition = @json.from_json({
    "line": Json::number(2147483648.0),
    "col": 2,
  })
  assert_eq(position.col, 2)
}
