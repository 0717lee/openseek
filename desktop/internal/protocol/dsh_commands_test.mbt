///|
test "dsh command envelopes preserve nested versioned JSON" {
  let request : @protocol.DshRequestPayload = @json.from_json({
    "method": "session.prompt",
    "payload": { "content": null },
  })
  assert_eq(request.method_, "session.prompt")
  @debug.assert_eq(request.to_json(), {
    "method": "session.prompt",
    "payload": { "content": null },
  })
  let response : @protocol.DshRespondPayload = @json.from_json({
    "message": { "type": "client-response", "result": { "ok": true } },
  })
  @debug.assert_eq(response.to_json(), {
    "message": { "type": "client-response", "result": { "ok": true } },
  })
  let reply : @protocol.DshValueReply = @json.from_json({
    "value": null,
    "sessionRevision": 7,
    "workspaceAccepted": true,
  })
  assert_true(reply.value is Null)
  assert_eq(reply.session_revision, Some(7))
  assert_eq(reply.workspace_accepted, Some(true))
  @debug.assert_eq(reply.to_json(), {
    "value": null,
    "sessionRevision": 7,
    "workspaceAccepted": true,
  })
}

///|
test "dsh command envelopes reject missing malformed and unknown fields" {
  let missing = try {
    let _ : @protocol.DshRequestPayload = @json.from_json({
      "method": "session.list",
    })
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(missing)
  let malformed = try {
    let _ : @protocol.DshRequestPayload = @json.from_json({
      "method": null,
      "payload": {},
    })
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(malformed)
  let unknown = try {
    let _ : @protocol.DshValueReply = @json.from_json({
      "value": {},
      "future": true,
    })
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(unknown)
  let no_args = try {
    let _ : @protocol.DshEmptyPayload = @json.from_json({ "extra": true })
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(no_args)
}

///|
test "dsh notification envelopes type the Desktop-owned wrapper" {
  let status : @protocol.DshStatusNotification = @json.from_json({
    "status": "unavailable",
    "message": "dsh stopped",
    "revision": 4,
  })
  @debug.assert_eq(status.to_json(), {
    "status": "unavailable",
    "message": "dsh stopped",
    "revision": 4,
  })
  let event : @protocol.DshEventNotification = @json.from_json({
    "stream": "mux",
    "message": null,
    "generation": 3,
    "sessionRevision": 9,
  })
  assert_true(event.message is Null)
  @debug.assert_eq(event.to_json(), {
    "stream": "mux",
    "message": null,
    "generation": 3,
    "sessionRevision": 9,
  })
}

///|
test "dsh notification envelopes reject malformed wrappers" {
  let missing = try {
    let _ : @protocol.DshEventNotification = @json.from_json({
      "stream": "host",
      "message": {},
    })
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(missing)
  let malformed = try {
    let _ : @protocol.DshStatusNotification = @json.from_json({
      "status": "unavailable",
      "message": false,
      "revision": 1,
    })
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(malformed)
  let unknown = try {
    let _ : @protocol.DshEventNotification = @json.from_json({
      "stream": "mux",
      "message": {},
      "generation": 4,
      "sessionRevision": 5,
      "future": true,
    })
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(unknown)
}

///|
test "dsh workspace list decodes every authority field strictly" {
  let list : @protocol.DshWorkspaceList = @json.from_json({
    "items": [
      {
        "workspaceId": "workspace-1",
        "title": "project",
        "path": "/work/project",
        "sessionIds": ["session-1", "session-2"],
        "createdAt": "2026-08-17T00:00:00.000Z",
      },
    ],
    "archivedSessionIds": ["session-2"],
    "futureMetadata": true,
  })
  guard list.items is [workspace] else { fail("expected one Workspace row") }
  assert_eq(workspace.workspace_id, "workspace-1")
  assert_eq(workspace.path, "/work/project")
  assert_eq(workspace.session_ids, ["session-1", "session-2"])
  // An archived session keeps its slot, so only the live one counts.
  assert_eq(
    workspace.live_session_count(
      Set::from_iter(list.archived_session_ids.iter()),
    ),
    1,
  )
  assert_eq(workspace.live_session_count(Set([])), 2)
  @debug.assert_eq(
    (@json.from_json(list.to_json()) : @protocol.DshWorkspaceList),
    list,
  )
  // Every field used to decide native authority is a decode failure rather
  // than a skipped row. In particular, an absent or reshaped archive set must
  // not be read as empty and restore a hidden conversation's grants.
  for
    malformed in [
      (
        {
          "items": [{ "title": "project", "path": "/p", "sessionIds": [] }],
          "archivedSessionIds": [],
        } : Json),
      {
        "items": [{ "workspaceId": "w", "path": "/p", "sessionIds": [] }],
        "archivedSessionIds": [],
      },
      {
        "items": [{ "workspaceId": "w", "title": "p", "sessionIds": [] }],
        "archivedSessionIds": [],
      },
      {
        "items": [
          { "workspaceId": "w", "title": "p", "path": 7, "sessionIds": [] },
        ],
        "archivedSessionIds": [],
      },
      {
        "items": [{ "workspaceId": "w", "title": "p", "path": "/p" }],
        "archivedSessionIds": [],
      },
      {
        "items": [
          { "workspaceId": "w", "title": "p", "path": "/p", "sessionIds": {} },
        ],
        "archivedSessionIds": [],
      },
      {
        "items": [
          { "workspaceId": "w", "title": "p", "path": "/p", "sessionIds": [7] },
        ],
        "archivedSessionIds": [],
      },
      {
        "items": [
          {
            "workspaceId": "w",
            "title": "p",
            "path": "/p",
            "sessionIds": [" "],
          },
        ],
        "archivedSessionIds": [],
      },
      { "items": {}, "archivedSessionIds": [] },
      { "archivedSessionIds": [] },
      { "items": [] },
      {
        "items": [],
        "archivedSessionIds": [{ "id": "session-1", "at": "2026-08-17" }],
      },
      { "items": [], "archived": ["session-1"] },
    ] {
    let rejected = try {
      let _ : @protocol.DshWorkspaceList = @json.from_json(malformed)
    } catch {
      _ => true
    } noraise {
      _ => false
    }
    assert_true(rejected)
  }
}
