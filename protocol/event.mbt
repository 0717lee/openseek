///|
/// One event on the engine's stdout JSONL stream — the wire contract between
/// `openseek run`/`openseek serve` and every client that reads them (the TUI,
/// the desktop host, and any script consuming `run`'s stdout).
///
/// The stream doubles as the process log: `emit` routes through `@xlog`, whose
/// handler serializes an `Entry` per line as
/// `{"timestamp":…,"level":…,"source":…,<fields>}` — structured fields are
/// hoisted to the top level, so an event's own fields sit alongside the
/// envelope rather than nested under it.
///
/// Every variant owns its log level, so a call site cannot report the same
/// event at two severities. `emit` is the only writer; `parse` is its inverse.
pub(all) enum Event {
  // ── agent loop ─────────────────────────────────────────────────────────
  AgentSetupFailed(error~ : String)
  AgentStep(step~ : Int)
  AgentAborted(reason~ : String)
  AgentFinished(answer~ : String)
  MaxStepsExhausted
  TurnFailed(error~ : String)
  AssistantDelta(content~ : String)
  AssistantMessage(content~ : String)
  ReasoningMessage(content~ : String)
  Usage(usage~ : Usage)
  /// `brief` is always written, `null` when the tool reported none: an absent
  /// key and a null one are indistinguishable to every decoder, so the shape
  /// stays uniform across the three call sites that emit a tool result.
  ToolResult(
    tool_call_id~ : String,
    tool_name~ : String,
    is_error~ : Bool,
    content~ : String,
    brief~ : String?
  )
  ToolCallDecodeError(
    tool_call_id~ : String,
    tool_name~ : String,
    error~ : String
  )

  // ── steering ───────────────────────────────────────────────────────────
  SteerApplied(kind~ : String, content~ : String)
  SteerDropped(content~ : String)
  BackgroundNotice(content~ : String)

  // ── goal ───────────────────────────────────────────────────────────────
  GoalUpdated(goal~ : String?)
  GoalBlocked(reason~ : String)
  GoalUnblocked
  GoalCheck(content~ : String)
  GoalReminder(content~ : String)
  GoalContinue(remaining~ : Int)
  GoalBudgetExhausted(turns~ : Int)

  // ── plan ───────────────────────────────────────────────────────────────
  PlanReminder(content~ : String)

  // ── compaction ─────────────────────────────────────────────────────────
  CompactionStarted(from_sequence~ : Int, to_sequence~ : Int)
  CompactionFinished(
    from_sequence~ : Int,
    to_sequence~ : Int,
    summary~ : String
  )
  /// Reported at `Error` even when the cause was cancellation: no decoder
  /// reads the envelope's level, so one severity per event costs nothing and
  /// keeps the level a property of the event rather than of the call site.
  CompactionFailed(error~ : String)
  AutoCompactionStarted(from_sequence~ : Int, to_sequence~ : Int)
  AutoCompactionFinished(
    from_sequence~ : Int,
    to_sequence~ : Int,
    summary~ : String
  )
  AutoCompactionFailed(error~ : String)
  ContextYield(to_sequence~ : Int, answer~ : String)

  // ── session / workspace ────────────────────────────────────────────────
  SessionStarted(
    session~ : String,
    session_root~ : String,
    workspace_root~ : String
  )
  SessionError(error~ : String)
  WorkspaceCreated(dir~ : String)
  CommandError(error~ : String)
  FleetStarted(runs~ : Int, task~ : String)

  // ── mcp ────────────────────────────────────────────────────────────────
  McpConfigIgnored(reason~ : String)
  McpConfigUnreadable(path~ : String, error~ : String)
  McpConfigInvalid(path~ : String, error~ : String)
  McpToolsRegistered(servers~ : Int, tools~ : Int, names~ : Array[String])
  McpToolDuplicate(server~ : String, tool~ : String)
  McpToolRenamed(from~ : String, to~ : String)
  McpToolsCapped(server~ : String, kept~ : Int)
  McpServerSkippedOverCap(server~ : String)
  /// `error` is always written, `null` when the connection produced no error
  /// value (the server simply yielded nothing) — same uniformity rule as
  /// `ToolResult::brief`.
  McpConnectFailed(server~ : String, error~ : String?)
  McpListToolsFailed(server~ : String, error~ : String)
  McpListToolsTimeout(server~ : String)
  McpNoTools(server~ : String)
} derive(Eq, Debug)

///|
/// The event's `"event"` field — its name on the wire.
pub fn Event::name(self : Event) -> String {
  match self {
    AgentSetupFailed(_) => "agent_setup_failed"
    AgentStep(_) => "agent_step"
    AgentAborted(_) => "agent_aborted"
    AgentFinished(_) => "agent_finished"
    MaxStepsExhausted => "max_steps_exhausted"
    TurnFailed(_) => "turn_failed"
    AssistantDelta(_) => "assistant_delta"
    AssistantMessage(_) => "assistant_message"
    ReasoningMessage(_) => "reasoning_message"
    Usage(_) => "usage"
    ToolResult(_) => "tool_result"
    ToolCallDecodeError(_) => "tool_call_decode_error"
    SteerApplied(_) => "steer_applied"
    SteerDropped(_) => "steer_dropped"
    BackgroundNotice(_) => "background_notice"
    GoalUpdated(_) => "goal_updated"
    GoalBlocked(_) => "goal_blocked"
    GoalUnblocked => "goal_unblocked"
    GoalCheck(_) => "goal_check"
    GoalReminder(_) => "goal_reminder"
    GoalContinue(_) => "goal_continue"
    GoalBudgetExhausted(_) => "goal_budget_exhausted"
    PlanReminder(_) => "plan_reminder"
    CompactionStarted(_) => "compaction_started"
    CompactionFinished(_) => "compaction_finished"
    CompactionFailed(_) => "compaction_failed"
    AutoCompactionStarted(_) => "auto_compaction_started"
    AutoCompactionFinished(_) => "auto_compaction_finished"
    AutoCompactionFailed(_) => "auto_compaction_failed"
    ContextYield(_) => "context_yield"
    SessionStarted(_) => "session_started"
    SessionError(_) => "session_error"
    WorkspaceCreated(_) => "workspace_created"
    CommandError(_) => "command_error"
    FleetStarted(_) => "fleet_started"
    McpConfigIgnored(_) => "mcp_config_ignored"
    McpConfigUnreadable(_) => "mcp_config_unreadable"
    McpConfigInvalid(_) => "mcp_config_invalid"
    McpToolsRegistered(_) => "mcp_tools_registered"
    McpToolDuplicate(_) => "mcp_tool_duplicate"
    McpToolRenamed(_) => "mcp_tool_renamed"
    McpToolsCapped(_) => "mcp_tools_capped"
    McpServerSkippedOverCap(_) => "mcp_server_skipped_over_cap"
    McpConnectFailed(_) => "mcp_connect_failed"
    McpListToolsFailed(_) => "mcp_list_tools_failed"
    McpListToolsTimeout(_) => "mcp_list_tools_timeout"
    McpNoTools(_) => "mcp_no_tools"
  }
}
