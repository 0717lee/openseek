# OpenSeek Architecture

How the pieces fit together: the module map, the core data model, and the
life of one agent turn. Package-level details live in each package's README
(see the table in the [root README](../README.md)); this page is the map, not
the territory. Diagrams are [Mermaid](https://mermaid.js.org/), rendered
natively by GitHub.

## System overview

One binary, three frontends. `cmd/openseek` is the engine: its `serve` mode
reads JSONL commands on stdin and streams typed JSONL events
(`bobzhang/openseek_protocol`) on stdout. The terminal UI, the desktop app,
and headless `run` all drive that same engine and event stream. Durable state
lives in append-only session files that the visualizer reads directly.

```mermaid
flowchart LR
  subgraph frontends [Frontends]
    TUI["cmd/tui — terminal UI<br/>(built on the tui framework)"]
    DESKTOP["openseek_desktop — desktop app<br/>(CEF shell + JS frontend)"]
    VIZ["cmd/viz_server + viz —<br/>session visualizer (browser)"]
  end

  subgraph engine ["openseek engine (cmd/openseek)"]
    SERVE["serve / run / review / sessions / mcp"]
    AGENT["agent — turn loop"]
    TOOLS["agent_tool — registry:<br/>shell·read·edit·multi_edit·write<br/>remove·plan·goal·finish"]
    MCP["mcp — client + tool bridge<br/>(mcp__server__tool)"]
    PROMPT["prompt + agent_skill —<br/>system prompt & skills"]
    SESSION["agent_session (+ store) —<br/>durable event log"]
  end

  subgraph outside [Outside]
    API["DeepSeek / Kimi chat API"]
    MCPSRV["MCP servers<br/>(stdio & Streamable HTTP)"]
    FILES[("openseek_session-&lt;id&gt;.jsonl<br/>under .openseek/")]
  end

  TUI -- "JSONL commands (stdin)" --> SERVE
  DESKTOP -- "JSONL commands" --> SERVE
  SERVE -- "protocol events (stdout)" --> TUI
  SERVE -- "protocol events" --> DESKTOP
  SERVE --> AGENT
  PROMPT --> AGENT
  AGENT -- "chat + tool schemas" --> API
  AGENT -- dispatch --> TOOLS
  AGENT -- dispatch --> MCP
  MCP --> MCPSRV
  AGENT -- append --> SESSION
  SESSION --> FILES
  FILES --> VIZ
```

The engine ↔ frontend wire contract is `bobzhang/openseek_protocol`: commands
in (`prompt`, `steer`, `cancel`, `compact`, `goal`), events out (steps,
deltas, tool results, goal/plan reminders, compaction, terminals). The
protocol module is backend-neutral so any frontend — including the JS ones —
can decode it; only `protocol/emit` (the writer) is native-only.

## Core data model

The durable log and the tool boundary are the two type families everything
else leans on.

```mermaid
classDiagram
  class Session {
    id: SessionId
    system_prompt: String
    events: Vector~SessionEvent~
    append(SessionItem) Session
    chat_messages() Array~ChatMessage~
    compact(content, from, to) Session
    current_goal() StandingGoal?
  }
  class SessionEvent {
    sequence: Int
    unix_ms: Int64
    item: SessionItem
  }
  class SessionItem {
    <<enumeration>>
    User(UserMessage)
    Assistant(AssistantMessage)
    Tool(ToolResult)
    Runtime(RuntimeNotice)
    Summary(SessionSummary)
    Terminal(TurnTerminal)
  }
  class TurnTerminal {
    <<enumeration>>
    Finished(String)
    Aborted(String)
    Interrupted(String)
    Failed(String)
  }
  Session "1" *-- "many" SessionEvent
  SessionEvent *-- SessionItem
  SessionItem ..> TurnTerminal

  class Tools {
    find(name) AgentToolDefinition?
    function_tools() Array~ToolDefinition~
  }
  class AgentToolDefinition {
    name: String
    description: String
    schema: JsonSchema
    execute: ToolExecutor
    control: Bool
  }
  class ToolExecutor {
    <<enumeration>>
    Sync(fn)
    Async(async fn)
  }
  class ToolAction {
    <<enumeration>>
    Respond(ToolOutput)
    Control(Finish | Abort)
  }
  class AgentRuntime {
    workspace_root() String
    queue_steer(SteerInput)
    drain_steers() Array~SteerInput~
  }
  Tools "1" *-- "many" AgentToolDefinition
  AgentToolDefinition *-- ToolExecutor
  ToolExecutor ..> ToolAction : returns
```

Key invariants:

- **The session is the only memory.** `Session::chat_messages()` projects the
  event log into the provider's chat shape each turn; nothing conversational
  lives outside the log. Compaction rewrites a `[from, to]` range into one
  `Summary` item, and the projection starts from the latest summary.
- **Events are append-only and sequenced.** `SessionEvent.sequence` is
  contiguous; the store (`agent_session/store`) persists a header line plus
  one JSON event per line, so a torn final line is recoverable
  (`agent_session/log` reads leniently).
- **Tools are data.** A tool is a name, a JSON schema, and an executor.
  Normal tools return `Respond(ToolOutput)`; control tools (`finish`) end the
  turn via `Control`. MCP tools enter the same registry namespaced as
  `mcp__<server>__<tool>`, so the loop dispatches them identically.

## One turn, end to end

A `serve` turn as driven by the TUI (headless `run` is the same loop without
the stdin command pump):

```mermaid
sequenceDiagram
  participant UI as TUI / desktop
  participant Serve as openseek serve
  participant Turn as agent turn loop
  participant DS as DeepSeek/Kimi API
  participant Tool as agent_tool / mcp
  participant Store as session store

  UI->>Serve: {"command":"prompt","text":…}
  Serve->>Turn: run_turn_in_scope(session, task)
  Turn->>Store: append User(task)
  loop until a control tool or the context ceiling
    Turn->>DS: chat(messages, tool schemas)
    DS-->>Turn: assistant delta / tool_calls
    Turn-->>UI: AssistantDelta · ReasoningMessage · AgentStep
    Turn->>Tool: execute_tool_call(name, args)
    Tool-->>Turn: ToolAction (Respond / Control)
    Turn->>Store: append Assistant + Tool items
    Turn-->>UI: ToolResult event
    Note over Turn: queued steers/notices are folded in between steps
  end
  Turn->>Store: append Terminal(Finished(answer))
  Turn-->>UI: AgentFinished(answer)
```

Two pressure valves shape long turns:

- **Steps**: with `--max-steps` unset, a turn is bounded by the model's
  context window instead of a step count — when the window fills, the loop
  checkpoints (auto-compaction) and yields a `[context ceiling]` answer that
  the next turn continues from.
- **Steering**: `steer` commands and background-job completion notices are
  queued losslessly in `AgentRuntime` and surfaced to the model at the next
  step boundary, so a running turn can absorb new instructions without
  restarting.

## Where things live on disk

```text
.openseek/                       # per-workspace session root (--session-root)
  openseek_session-<id>.jsonl    # header line + append-only events
.openseek/skills/<name>.md       # workspace skills (shadow global ones)
~/.openseek/skills/              # global skill library (--global-skills-dir)
```

The visualizer (`openseek` sessions in a browser: `cmd/viz_server`) and
`sessions list` both read these files directly; nothing else is persisted.
