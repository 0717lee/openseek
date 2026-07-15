///|
/// An optional string field as the wire carries it: the value itself, or
/// `null`.
///
/// Not the field's own `ToJson` — MoonBit encodes `Some(v)` as the one-element
/// array `[v]`, which every decoder's string lookup rejects, silently turning a
/// present field into an absent one.
fn or_null(value : String?) -> Json {
  match value {
    Some(value) => Json::string(value)
    None => Json::null()
  }
}

///|
/// Write `event` to the process log, which is the engine's stdout JSONL stream.
///
/// `loc` is autofilled from the *caller*, then forwarded to `@xlog`, so each
/// line's `source` still points at the code that reported the event rather than
/// at this function. `@xlog`'s level methods return `None` when the level is
/// disabled, so a filtered event costs one enum construction and no
/// serialization.
#callsite(autofill(loc))
pub fn emit(event : @protocol.Event, loc~ : SourceLoc) -> Unit {
  match event {
    AgentSetupFailed(error~) =>
      @xlog.error(loc~) <? { "event": "agent_setup_failed", "error": error }
    AgentStep(step~) =>
      @xlog.info(loc~) <? { "event": "agent_step", "step": step }
    AgentAborted(reason~) =>
      @xlog.warn(loc~) <? { "event": "agent_aborted", "reason": reason }
    AgentFinished(answer~) =>
      @xlog.info(loc~) <? { "event": "agent_finished", "answer": answer }
    MaxStepsExhausted => @xlog.warn(loc~) <? { "event": "max_steps_exhausted" }
    TurnFailed(error~) =>
      @xlog.error(loc~) <? { "event": "turn_failed", "error": error }
    AssistantDelta(content~) =>
      @xlog.info(loc~) <? { "event": "assistant_delta", "content": content }
    AssistantMessage(content~) =>
      @xlog.info(loc~) <? { "event": "assistant_message", "content": content }
    ReasoningMessage(content~) =>
      @xlog.info(loc~) <? { "event": "reasoning_message", "content": content }
    Usage(usage~) => @xlog.info(loc~) <? { "event": "usage", "usage": usage }
    ToolResult(tool_call_id~, tool_name~, is_error~, content~, brief~) =>
      @xlog.info(loc~) <?
        {
          "event": "tool_result",
          "tool_call_id": tool_call_id,
          "tool_name": tool_name,
          "is_error": is_error,
          "content": content,
          "brief": or_null(brief),
        }
    ToolCallDecodeError(tool_call_id~, tool_name~, error~) =>
      @xlog.error(loc~) <?
        {
          "event": "tool_call_decode_error",
          "tool_call_id": tool_call_id,
          "tool_name": tool_name,
          "error": error,
        }
    SteerApplied(kind~, content~) =>
      @xlog.info(loc~) <?
        { "event": "steer_applied", "kind": kind, "content": content }
    SteerDropped(content~) =>
      @xlog.warn(loc~) <? { "event": "steer_dropped", "content": content }
    BackgroundNotice(content~) =>
      @xlog.info(loc~) <? { "event": "background_notice", "content": content }
    GoalUpdated(goal~) =>
      @xlog.info(loc~) <? { "event": "goal_updated", "goal": or_null(goal) }
    GoalBlocked(reason~) =>
      @xlog.info(loc~) <? { "event": "goal_blocked", "reason": reason }
    GoalUnblocked => @xlog.info(loc~) <? { "event": "goal_unblocked" }
    GoalCheck(content~) =>
      @xlog.info(loc~) <? { "event": "goal_check", "content": content }
    GoalReminder(content~) =>
      @xlog.info(loc~) <? { "event": "goal_reminder", "content": content }
    GoalContinue(remaining~) =>
      @xlog.info(loc~) <? { "event": "goal_continue", "remaining": remaining }
    GoalBudgetExhausted(turns~) =>
      @xlog.warn(loc~) <? { "event": "goal_budget_exhausted", "turns": turns }
    PlanReminder(content~) =>
      @xlog.info(loc~) <? { "event": "plan_reminder", "content": content }
    CompactionStarted(from_sequence~, to_sequence~) =>
      @xlog.info(loc~) <?
        {
          "event": "compaction_started",
          "from_sequence": from_sequence,
          "to_sequence": to_sequence,
        }
    CompactionFinished(from_sequence~, to_sequence~, summary~) =>
      @xlog.info(loc~) <?
        {
          "event": "compaction_finished",
          "from_sequence": from_sequence,
          "to_sequence": to_sequence,
          "summary": summary,
        }
    CompactionFailed(error~) =>
      @xlog.error(loc~) <? { "event": "compaction_failed", "error": error }
    AutoCompactionStarted(from_sequence~, to_sequence~) =>
      @xlog.info(loc~) <?
        {
          "event": "auto_compaction_started",
          "from_sequence": from_sequence,
          "to_sequence": to_sequence,
        }
    AutoCompactionFinished(from_sequence~, to_sequence~, summary~) =>
      @xlog.info(loc~) <?
        {
          "event": "auto_compaction_finished",
          "from_sequence": from_sequence,
          "to_sequence": to_sequence,
          "summary": summary,
        }
    AutoCompactionFailed(error~) =>
      @xlog.warn(loc~) <? { "event": "auto_compaction_failed", "error": error }
    ContextYield(to_sequence~, answer~) =>
      @xlog.info(loc~) <?
        {
          "event": "context_yield",
          "to_sequence": to_sequence,
          "answer": answer,
        }
    SessionStarted(session~, session_root~, workspace_root~) =>
      @xlog.info(loc~) <?
        {
          "event": "session_started",
          "session": session,
          "session_root": session_root,
          "workspace_root": workspace_root,
        }
    SessionError(error~) =>
      @xlog.error(loc~) <? { "event": "session_error", "error": error }
    WorkspaceCreated(dir~) =>
      @xlog.info(loc~) <? { "event": "workspace_created", "dir": dir }
    CommandError(error~) =>
      @xlog.error(loc~) <? { "event": "command_error", "error": error }
    FleetStarted(runs~, task~) =>
      @xlog.info(loc~) <?
        { "event": "fleet_started", "runs": runs, "task": task }
    McpConfigIgnored(reason~) =>
      @xlog.warn(loc~) <? { "event": "mcp_config_ignored", "reason": reason }
    McpConfigUnreadable(path~, error~) =>
      @xlog.warn(loc~) <?
        { "event": "mcp_config_unreadable", "path": path, "error": error }
    McpConfigInvalid(path~, error~) =>
      @xlog.warn(loc~) <?
        { "event": "mcp_config_invalid", "path": path, "error": error }
    McpToolsRegistered(servers~, tools~, names~) =>
      @xlog.info(loc~) <?
        {
          "event": "mcp_tools_registered",
          "servers": servers,
          "tools": tools,
          "names": names,
        }
    McpToolDuplicate(server~, tool~) =>
      @xlog.warn(loc~) <?
        { "event": "mcp_tool_duplicate", "server": server, "tool": tool }
    McpToolRenamed(from~, to~) =>
      @xlog.warn(loc~) <?
        { "event": "mcp_tool_renamed", "from": from, "to": to }
    McpToolsCapped(server~, kept~) =>
      @xlog.warn(loc~) <?
        { "event": "mcp_tools_capped", "server": server, "kept": kept }
    McpServerSkippedOverCap(server~) =>
      @xlog.warn(loc~) <?
        { "event": "mcp_server_skipped_over_cap", "server": server }
    McpConnectFailed(server~, error~) =>
      @xlog.warn(loc~) <?
        {
          "event": "mcp_connect_failed",
          "server": server,
          "error": or_null(error),
        }
    McpListToolsFailed(server~, error~) =>
      @xlog.warn(loc~) <?
        { "event": "mcp_list_tools_failed", "server": server, "error": error }
    McpListToolsTimeout(server~) =>
      @xlog.warn(loc~) <?
        { "event": "mcp_list_tools_timeout", "server": server }
    McpNoTools(server~) =>
      @xlog.warn(loc~) <? { "event": "mcp_no_tools", "server": server }
  }
}
