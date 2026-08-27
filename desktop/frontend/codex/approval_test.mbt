// Approval cards are tested through the same public state, update, and
// composer projection that the root shell uses. The tests do not reach into
// Codex's private pending-request representation.

///|
#warnings("-alert_unstable")
test "command approval renders facts and advertised decisions" {
  let dispatch : @cmd.Emit[@codex.Msg] = @cmd.Emit(_ => @cmd.none)
  let state = @codex.State::from_thread_snapshot({
    "thread": { "id": "thread-1", "cwd": "/work/project", "turns": [] },
  })
  let (_, requested) = @codex.update(
    dispatch,
    @codex.Msg::server_request(
      Json("approval-1"),
      "item/commandExecution/requestApproval",
      {
        "threadId": "thread-1",
        "turnId": "turn-1",
        "itemId": "command-1",
        "reason": "Generate package interface metadata",
        "command": "/bin/zsh -lc 'moon info'",
        "cwd": "/work/project",
        "proposedExecpolicyAmendment": ["moon", "info"],
        "availableDecisions": [
          "accept",
          {
            "acceptWithExecpolicyAmendment": {
              "execpolicy_amendment": ["moon", "info"],
            },
          },
          "cancel",
        ],
      },
      1,
    ),
    state,
    @interop.ChannelId::Local,
    _ => @cmd.none,
  )
  let input = requested.composer_input({
    channel: @interop.ChannelId::Local,
    model_control: {
      id: "approval-test-model",
      groups: [],
      selected: "",
      disabled: true,
      open: false,
      title: "",
    },
    reasoning_control: None,
    file_candidates: [],
    open_files: [],
    active_file: None,
    file_index: @composer.FileIndexReady(
      checkout_id="checkout-0",
      truncated=false,
    ),
  })
  guard input.presentation.context[0] is @composer.CodexRequests(_) else {
    fail("Codex requests must remain the composer's first typed context slot")
  }
  let action_emit : @cmd.Emit[@composer.Action] = @cmd.Emit(_ => @cmd.none)
  let markup = @rabbita.render_to_string(() => {
    @rabbita.Val::constant(
      input.presentation.context[0].render(input.identity, action_emit),
    )
  })
  assert_true(markup.contains("Command approval"))
  assert_true(markup.contains("Generate package interface metadata"))
  assert_true(markup.contains("codex-request-command"))
  assert_true(markup.contains("/work/project"))
  assert_true(markup.contains("Requested rule"))
  assert_true(markup.contains("Allow by rule: moon info"))
  assert_true(markup.contains("Approve once"))
  assert_true(markup.contains("Cancel"))
  // Each advertised choice remains a real button with component-owned
  // geometry; secondary and cancel actions must not fall back to plain text.
  assert_true(
    markup.contains(
      "class=\"codex-request-action codex-request-action-primary\"",
    ),
  )
  assert_true(markup.contains("class=\"codex-request-action\""))
  assert_true(
    markup.contains(
      "class=\"codex-request-action codex-request-action-danger\"",
    ),
  )
  assert_false(markup.contains("Approve for session"))
  assert_false(markup.contains(">Decline<"))
  assert_true(markup.contains("codex-request-raw-summary"))
  assert_true(markup.contains("Show details"))
}

///|
#warnings("-alert_unstable")
test "network approval uses its destination instead of a command preview" {
  let dispatch : @cmd.Emit[@codex.Msg] = @cmd.Emit(_ => @cmd.none)
  let state = @codex.State::from_thread_snapshot({
    "thread": { "id": "thread-1", "cwd": "/work/project", "turns": [] },
  })
  let (_, requested) = @codex.update(
    dispatch,
    @codex.Msg::server_request(
      Json("approval-2"),
      "item/commandExecution/requestApproval",
      {
        "threadId": "thread-1",
        "command": "internal network request",
        "cwd": "/work/project",
        "networkApprovalContext": {
          "host": "api.example.com",
          "protocol": "https",
          "port": 443,
        },
        "availableDecisions": ["accept", "cancel"],
      },
      1,
    ),
    state,
    @interop.ChannelId::Local,
    _ => @cmd.none,
  )
  let input = requested.composer_input({
    channel: @interop.ChannelId::Local,
    model_control: {
      id: "approval-test-model",
      groups: [],
      selected: "",
      disabled: true,
      open: false,
      title: "",
    },
    reasoning_control: None,
    file_candidates: [],
    open_files: [],
    active_file: None,
    file_index: @composer.FileIndexReady(
      checkout_id="checkout-0",
      truncated=false,
    ),
  })
  guard input.presentation.context[0] is @composer.CodexRequests(_) else {
    fail("Codex requests must remain the composer's first typed context slot")
  }
  let action_emit : @cmd.Emit[@composer.Action] = @cmd.Emit(_ => @cmd.none)
  let markup = @rabbita.render_to_string(() => {
    @rabbita.Val::constant(
      input.presentation.context[0].render(input.identity, action_emit),
    )
  })
  assert_true(markup.contains("Network access approval"))
  assert_true(markup.contains("Network destination"))
  assert_true(markup.contains("https://api.example.com:443"))
  assert_false(markup.contains(">Command</div>"))
}
