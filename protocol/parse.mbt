///|
/// Read one JSONL line from the engine's stdout stream back into an `Event`.
///
/// The inverse of `emit`: `parse(json) == Some(event)` for every line `emit`
/// writes, which `protocol_test.mbt` pins per variant. Fields are read from the
/// top level, matching the hoisting `@xlog`'s handler performs.
///
/// `None` means "not an event this engine emits" — an unknown `event` name, a
/// missing `event` key, or a payload whose required fields are absent or
/// mistyped. Clients stay tolerant of a newer engine by treating `None` as
/// "ignore this line" rather than as a failure.
pub fn parse(line : Json) -> Event? {
  guard line is Object(fields) else { return None }
  guard text(fields, "event") is Some(name) else { return None }
  match name {
    "agent_setup_failed" =>
      text(fields, "error").map(error => AgentSetupFailed(error~))
    "agent_step" => int(fields, "step").map(step => AgentStep(step~))
    "agent_aborted" =>
      text(fields, "reason").map(reason => AgentAborted(reason~))
    "agent_finished" =>
      text(fields, "answer").map(answer => AgentFinished(answer~))
    "max_steps_exhausted" => Some(MaxStepsExhausted)
    "turn_failed" => text(fields, "error").map(error => TurnFailed(error~))
    "assistant_delta" =>
      text(fields, "content").map(content => AssistantDelta(content~))
    "assistant_message" =>
      text(fields, "content").map(content => AssistantMessage(content~))
    "reasoning_message" =>
      text(fields, "content").map(content => ReasoningMessage(content~))
    "usage" => {
      guard fields.get("usage") is Some(usage) else { return None }
      let usage : Usage = @json.from_json(usage) catch { _ => return None }
      Some(Usage(usage~))
    }
    "tool_result" => {
      guard text(fields, "tool_call_id") is Some(tool_call_id) &&
        text(fields, "tool_name") is Some(tool_name) &&
        bool(fields, "is_error") is Some(is_error) &&
        text(fields, "content") is Some(content) else {
        return None
      }
      Some(
        ToolResult(
          tool_call_id~,
          tool_name~,
          is_error~,
          content~,
          brief=text(fields, "brief"),
        ),
      )
    }
    "tool_call_decode_error" => {
      guard text(fields, "tool_call_id") is Some(tool_call_id) &&
        text(fields, "tool_name") is Some(tool_name) &&
        text(fields, "error") is Some(error) else {
        return None
      }
      Some(ToolCallDecodeError(tool_call_id~, tool_name~, error~))
    }
    // `kind` is defaulted, not required: engines older than 2026-06-25
    // (9b2f6c43, which added it) emit `steer_applied` with only `content`, and
    // the TUI launches whichever `openseek` is on PATH — so a new reader against
    // an old engine is a real pairing. "prompt" reproduces what those engines
    // meant, and is what every client defaulted to before this package existed.
    "steer_applied" =>
      text(fields, "content").map(content => {
        SteerApplied(kind=text(fields, "kind").unwrap_or("prompt"), content~)
      })
    "steer_dropped" =>
      text(fields, "content").map(content => SteerDropped(content~))
    "background_notice" =>
      text(fields, "content").map(content => BackgroundNotice(content~))
    // `goal` is null when the goal was cleared: absent and null are the same
    // value here, so the key's presence is not itself required.
    "goal_updated" => Some(GoalUpdated(goal=text(fields, "goal")))
    "goal_blocked" => text(fields, "reason").map(reason => GoalBlocked(reason~))
    "goal_unblocked" => Some(GoalUnblocked)
    "goal_check" => text(fields, "content").map(content => GoalCheck(content~))
    "goal_reminder" =>
      text(fields, "content").map(content => GoalReminder(content~))
    "goal_continue" =>
      int(fields, "remaining").map(remaining => GoalContinue(remaining~))
    "goal_budget_exhausted" =>
      int(fields, "turns").map(turns => GoalBudgetExhausted(turns~))
    "plan_reminder" =>
      text(fields, "content").map(content => PlanReminder(content~))
    "compaction_started" => {
      guard sequences(fields) is Some((from_sequence, to_sequence)) else {
        return None
      }
      Some(CompactionStarted(from_sequence~, to_sequence~))
    }
    "compaction_finished" => {
      guard sequences(fields) is Some((from_sequence, to_sequence)) &&
        text(fields, "summary") is Some(summary) else {
        return None
      }
      Some(CompactionFinished(from_sequence~, to_sequence~, summary~))
    }
    "compaction_failed" =>
      text(fields, "error").map(error => CompactionFailed(error~))
    "auto_compaction_started" => {
      guard sequences(fields) is Some((from_sequence, to_sequence)) else {
        return None
      }
      Some(AutoCompactionStarted(from_sequence~, to_sequence~))
    }
    "auto_compaction_finished" => {
      guard sequences(fields) is Some((from_sequence, to_sequence)) &&
        text(fields, "summary") is Some(summary) else {
        return None
      }
      Some(AutoCompactionFinished(from_sequence~, to_sequence~, summary~))
    }
    "auto_compaction_failed" =>
      text(fields, "error").map(error => AutoCompactionFailed(error~))
    "context_yield" => {
      guard int(fields, "to_sequence") is Some(to_sequence) &&
        text(fields, "answer") is Some(answer) else {
        return None
      }
      Some(ContextYield(to_sequence~, answer~))
    }
    "session_started" => {
      guard text(fields, "session") is Some(session) &&
        text(fields, "session_root") is Some(session_root) &&
        text(fields, "workspace_root") is Some(workspace_root) else {
        return None
      }
      Some(SessionStarted(session~, session_root~, workspace_root~))
    }
    "session_error" => text(fields, "error").map(error => SessionError(error~))
    "workspace_created" =>
      text(fields, "dir").map(dir => WorkspaceCreated(dir~))
    "command_error" => text(fields, "error").map(error => CommandError(error~))
    "fleet_started" => {
      guard int(fields, "runs") is Some(runs) &&
        text(fields, "task") is Some(task) else {
        return None
      }
      Some(FleetStarted(runs~, task~))
    }
    "mcp_config_ignored" =>
      text(fields, "reason").map(reason => McpConfigIgnored(reason~))
    "mcp_config_unreadable" => {
      guard text(fields, "path") is Some(path) &&
        text(fields, "error") is Some(error) else {
        return None
      }
      Some(McpConfigUnreadable(path~, error~))
    }
    "mcp_config_invalid" => {
      guard text(fields, "path") is Some(path) &&
        text(fields, "error") is Some(error) else {
        return None
      }
      Some(McpConfigInvalid(path~, error~))
    }
    // `names` is defaulted to empty rather than required: it is the one field
    // here no reader uses (the TUI renders only the two counts), so demanding it
    // would let a field nobody reads decide whether the notice appears at all.
    "mcp_tools_registered" => {
      guard int(fields, "servers") is Some(servers) &&
        int(fields, "tools") is Some(tools) else {
        return None
      }
      let decoded = []
      if fields.get("names") is Some(Array(names)) {
        for name in names {
          guard name is String(name) else { return None }
          decoded.push(name)
        }
      }
      Some(McpToolsRegistered(servers~, tools~, names=decoded))
    }
    "mcp_tool_duplicate" => {
      guard text(fields, "server") is Some(server) &&
        text(fields, "tool") is Some(tool) else {
        return None
      }
      Some(McpToolDuplicate(server~, tool~))
    }
    "mcp_tool_renamed" => {
      guard text(fields, "from") is Some(from) && text(fields, "to") is Some(to) else {
        return None
      }
      Some(McpToolRenamed(from~, to~))
    }
    "mcp_tools_capped" => {
      guard text(fields, "server") is Some(server) &&
        int(fields, "kept") is Some(kept) else {
        return None
      }
      Some(McpToolsCapped(server~, kept~))
    }
    "mcp_server_skipped_over_cap" =>
      text(fields, "server").map(server => McpServerSkippedOverCap(server~))
    // `error` is null when the connection yielded no error value.
    "mcp_connect_failed" =>
      text(fields, "server").map(server => {
        McpConnectFailed(server~, error=text(fields, "error"))
      })
    "mcp_list_tools_failed" => {
      guard text(fields, "server") is Some(server) &&
        text(fields, "error") is Some(error) else {
        return None
      }
      Some(McpListToolsFailed(server~, error~))
    }
    "mcp_list_tools_timeout" =>
      text(fields, "server").map(server => McpListToolsTimeout(server~))
    "mcp_no_tools" => text(fields, "server").map(server => McpNoTools(server~))
    _ => None
  }
}

///|
fn text(fields : Map[String, Json], key : String) -> String? {
  guard fields.get(key) is Some(String(value)) else { return None }
  Some(value)
}

///|
/// JSON has one number type, so an `Int` field arrives as a `Number`; reject a
/// fractional value rather than silently truncating it.
fn int(fields : Map[String, Json], key : String) -> Int? {
  guard fields.get(key) is Some(Number(value, ..)) else { return None }
  let rounded = value.to_int()
  guard rounded.to_double() == value else { return None }
  Some(rounded)
}

///|
fn bool(fields : Map[String, Json], key : String) -> Bool? {
  match fields.get(key) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
/// The `from_sequence`/`to_sequence` pair every compaction event carries.
fn sequences(fields : Map[String, Json]) -> (Int, Int)? {
  guard int(fields, "from_sequence") is Some(from_sequence) &&
    int(fields, "to_sequence") is Some(to_sequence) else {
    return None
  }
  Some((from_sequence, to_sequence))
}
