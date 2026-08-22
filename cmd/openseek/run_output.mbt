///|
/// Display format for the one-shot `openseek run` command. Protocol-oriented
/// commands (`serve` and the internal `subrun`) deliberately do not use this
/// type: their stdout remains JSONL unconditionally.
priv enum RunOutputFormat {
  Human
  Jsonl
}

///|
/// Signals that human `run` output already reported the failure. The process
/// entry point still exits non-zero, but must not duplicate it on stderr.
priv suberror HumanRunFailure {
  HumanRunFailure
}

///|
fn run_output_format(matches : @argparse.Matches) -> RunOutputFormat raise {
  let value = match matches {
    { values: { "format": [value, ..], .. }, .. } => value.trim()
    _ => fail("missing parsed argument: format")
  }
  match value {
    "human" => Human
    "jsonl" => Jsonl
    other =>
      fail("unknown run output format: \{other}; expected human or jsonl")
  }
}

///|
/// Remove terminal-control characters from streamed model text while keeping
/// ordinary layout. A model response is untrusted terminal input just as much
/// as a stored prompt is; ESC/C0/C1 bytes must never become commands.
fn human_content(text : String) -> String {
  let out = StringBuilder()
  for ch in text {
    if ch is ('\n' | '\t') {
      out.write_char(ch)
    } else if !ch.is_control() {
      out.write_char(ch)
    }
  }
  out.to_string()
}

///|
/// A terminal-safe, single-line event detail capped to a compact width.
fn human_brief(text : String, limit? : Int = 120) -> String {
  let out = StringBuilder()
  for ch in text.trim(); spaced = false, count = 0 {
    if count >= limit {
      out.write_char('…')
      break
    }
    if ch.is_whitespace() {
      if !spaced {
        out.write_char(' ')
        continue true, count + 1
      }
      continue true, count
    } else if ch.is_control() {
      continue spaced, count
    } else {
      out.write_char(ch)
      continue false, count + 1
    }
  }
  out.to_string()
}

///|
/// Which kind of provider prose was most recently streamed.
priv enum HumanRunStreamPhase {
  Waiting
  Reasoning
  Answer
}

///|
/// Stateful reduction of typed engine events into compact human output.
/// Returning a chunk rather than writing here keeps the reducer pure with
/// respect to IO and makes duplicate suppression directly testable.
priv struct HumanRunRenderer {
  suppress_events : Bool
  mut step : Int
  mut line_open : Bool
  mut stream_phase : HumanRunStreamPhase
  mut saw_delta : Bool
  mut last_assistant : String?
  mut last_assistant_printed : Bool
  mut prompt_tokens : Int
  mut completion_tokens : Int
}

///|
fn HumanRunRenderer::HumanRunRenderer(
  suppress_events? : Bool = false,
) -> HumanRunRenderer {
  {
    suppress_events,
    step: 0,
    line_open: false,
    stream_phase: Waiting,
    saw_delta: false,
    last_assistant: None,
    last_assistant_printed: false,
    prompt_tokens: 0,
    completion_tokens: 0,
  }
}

///|
fn HumanRunRenderer::break_line(self : HumanRunRenderer) -> String {
  if self.line_open {
    self.line_open = false
    "\n"
  } else {
    ""
  }
}

///|
fn HumanRunRenderer::line(self : HumanRunRenderer, text : String) -> String {
  "\{self.break_line()}\{text}\n"
}

///|
fn HumanRunRenderer::answer(self : HumanRunRenderer, text : String) -> String {
  let safe = human_content(text)
  if safe.is_blank() {
    return self.break_line()
  }
  let prefix = self.break_line()
  self.line_open = !safe.has_suffix("\n")
  "\{prefix}\{safe}"
}

///|
/// Separate streamed reasoning from the next visible answer fragment.
/// Whitespace-only content cannot consume the transition before prose begins.
fn HumanRunRenderer::answer_marker(
  self : HumanRunRenderer,
  text : String,
) -> String {
  if self.stream_phase is Reasoning && !human_content(text).is_blank() {
    self.stream_phase = Answer
    self.line("→ Answer")
  } else {
    if self.stream_phase is Waiting && !human_content(text).is_blank() {
      self.stream_phase = Answer
    }
    ""
  }
}

///|
fn HumanRunRenderer::tool_line(
  self : HumanRunRenderer,
  name : String,
  detail : String,
  failed : Bool,
) -> String {
  let marker = if failed { "✗" } else { "✓" }
  let detail = human_brief(detail)
  if detail == "" {
    self.line("\{marker} \{human_brief(name)}")
  } else {
    self.line("\{marker} \{human_brief(name)} — \{detail}")
  }
}

///|
fn HumanRunRenderer::stats(self : HumanRunRenderer) -> String {
  let steps = if self.step == 1 { "1 step" } else { "\{self.step} steps" }
  if self.prompt_tokens == 0 && self.completion_tokens == 0 {
    steps
  } else {
    "\{steps} · \{self.prompt_tokens} input / \{self.completion_tokens} output tokens"
  }
}

///|
fn HumanRunRenderer::terminal_line(
  self : HumanRunRenderer,
  marker : String,
  status : String,
) -> String {
  self.line("\{marker} \{status} · \{self.stats()}")
}

///|
fn HumanRunRenderer::render(
  self : HumanRunRenderer,
  event : @protocol.Event,
) -> String {
  if self.suppress_events {
    // Fleet attempts share this handler, so their progress would interleave.
    // Parent-owned preflight diagnostics still need to reach the user: an MCP
    // configuration that fleet mode cannot honor must never disappear merely
    // because the compact summary owns the rest of the display.
    match event {
      McpConfigIgnored(..) => ()
      _ => return ""
    }
  }
  match event {
    AgentStep(step~) => {
      self.step = step
      self.stream_phase = Waiting
      self.saw_delta = false
      self.last_assistant = None
      self.last_assistant_printed = false
      self.line("… Thinking (step \{step})")
    }
    ReasoningDelta(content~) => {
      let safe = human_content(content)
      if safe == "" {
        ""
      } else {
        let prefix = if self.stream_phase is Answer {
          self.line("… Thinking (step \{self.step}, continued)")
        } else {
          ""
        }
        self.stream_phase = Reasoning
        self.line_open = !safe.has_suffix("\n")
        "\{prefix}\{safe}"
      }
    }
    AssistantDelta(content~) => {
      let safe = human_content(content)
      if safe == "" {
        ""
      } else {
        let prefix = self.answer_marker(safe)
        self.saw_delta = true
        self.last_assistant_printed = self.last_assistant_printed ||
          !safe.is_blank()
        self.line_open = !safe.has_suffix("\n")
        "\{prefix}\{safe}"
      }
    }
    AssistantMessage(content~) => {
      self.last_assistant = Some(content)
      if self.saw_delta {
        self.break_line()
      } else {
        let prefix = self.answer_marker(content)
        self.last_assistant_printed = !human_content(content).is_blank()
        "\{prefix}\{self.answer(content)}"
      }
    }
    ReasoningMessage(..) => ""
    Usage(usage~) => {
      self.prompt_tokens += usage.prompt_tokens
      self.completion_tokens += usage.completion_tokens
      ""
    }
    ToolResult(tool_name~, is_error~, content~, brief~, ..) =>
      self.tool_line(tool_name, brief.unwrap_or(content), is_error)
    ToolCallDecodeError(tool_name~, error~, ..) =>
      self.tool_line(tool_name, "could not decode call: \{error}", true)
    AgentFinished(answer~) => {
      let out = StringBuilder()
      if !(self.last_assistant is Some(previous) &&
        previous == answer &&
        self.last_assistant_printed) {
        out <+ "\{self.answer_marker(answer)}"
        out <+ "\{self.answer(answer)}"
      } else {
        out <+ "\{self.break_line()}"
      }
      out <+ "\{self.terminal_line("✓", "Finished")}"
      out.to_string()
    }
    AgentSetupFailed(error~) =>
      self.terminal_line("✗", "Agent setup failed: \{human_brief(error)}")
    AgentAborted(reason~) =>
      self.terminal_line("✗", "Aborted: \{human_brief(reason)}")
    MaxStepsExhausted => self.terminal_line("✗", "Maximum steps exhausted")
    TurnFailed(error~) =>
      self.terminal_line("✗", "Turn failed: \{human_brief(error)}")
    SessionError(error~) =>
      self.line("✗ Session error: \{human_brief(error)}")
    CommandError(error~) =>
      self.line("✗ Command error: \{human_brief(error)}")
    SteerApplied(kind~, content~) =>
      self.line("• \{human_brief(kind)}: \{human_brief(content)}")
    SteerDropped(content~) =>
      self.line("⚠ Dropped input: \{human_brief(content)}")
    BackgroundNotice(content~) => self.line("• \{human_brief(content)}")
    GoalUpdated(goal~) =>
      match goal {
        Some(goal) => self.line("• Goal: \{human_brief(goal)}")
        None => self.line("• Goal cleared")
      }
    GoalContinue(remaining~) =>
      self.line("• Continuing goal (\{remaining} turn(s) remaining)")
    GoalBudgetExhausted(turns~) =>
      self.line("⚠ Goal budget exhausted after \{turns} turn(s)")
    CompactionStarted(..) | AutoCompactionStarted(..) =>
      self.line("… Compacting context")
    CompactionFinished(..) | AutoCompactionFinished(..) =>
      self.line("✓ Context compacted")
    CompactionFailed(error~) | AutoCompactionFailed(error~) =>
      self.line("✗ Context compaction failed: \{human_brief(error)}")
    ContextYield(answer~, ..) => {
      let out = StringBuilder()
      out <+ "\{self.answer_marker(answer)}"
      out <+ "\{self.answer(answer)}"
      out <+ "\{self.terminal_line("⚠", "Context limit reached")}"
      out.to_string()
    }
    SubrunStarted(kind~, label~, ..) =>
      self.line("… \{human_brief(kind)} subrun: \{human_brief(label)}")
    SubrunFinished(status~, steps~, prompt_tokens~, completion_tokens~, ..) => {
      // Child usage is reported only on this lifecycle event; it is not
      // duplicated as parent Usage events. Fold it into the run total so the
      // terminal summary reflects the model usage the invocation actually
      // incurred.
      self.prompt_tokens += prompt_tokens
      self.completion_tokens += completion_tokens
      let marker = match status {
        "captured" => "✓"
        "max_steps" | "context_yield" | "no_report" => "⚠"
        _ => "✗"
      }
      self.line("\{marker} Subrun \{human_brief(status)} · \{steps} step(s)")
    }
    SessionStarted(session~, ..) =>
      self.line("• Session: \{human_brief(session)}")
    WorkspaceCreated(dir~) => self.line("• Workspace: \{human_brief(dir)}")
    FleetStarted(runs~, ..) => self.line("… Starting \{runs} run(s)")
    McpConfigIgnored(reason~) =>
      self.line("⚠ MCP ignored: \{human_brief(reason)}")
    McpConfigUnreadable(path~, error~) | McpConfigInvalid(path~, error~) =>
      self.line("⚠ MCP config \{human_brief(path)}: \{human_brief(error)}")
    McpToolsRegistered(servers~, tools~, ..) =>
      self.line("• MCP: \{tools} tool(s) from \{servers} server(s)")
    McpConnectFailed(server~, error~) => {
      let detail = error.map(error => ": \{human_brief(error)}").unwrap_or("")
      self.line("⚠ MCP \{human_brief(server)} failed to connect\{detail}")
    }
    McpListToolsFailed(server~, error~) =>
      self.line(
        "⚠ MCP \{human_brief(server)} could not list tools: \{human_brief(error)}",
      )
    McpListToolsTimeout(server~) =>
      self.line("⚠ MCP \{human_brief(server)} timed out listing tools")
    McpNoTools(server~) =>
      self.line("⚠ MCP \{human_brief(server)} exposed no tools")
    McpToolDuplicate(server~, tool~) =>
      self.line("⚠ MCP duplicate \{human_brief(server)}.\{human_brief(tool)}")
    McpToolRenamed(from~, to~) =>
      self.line("• MCP renamed \{human_brief(from)} to \{human_brief(to)}")
    McpToolsCapped(server~, kept~) =>
      self.line("⚠ MCP \{human_brief(server)} capped at \{kept} tools")
    McpServerSkippedOverCap(server~) =>
      self.line("⚠ MCP \{human_brief(server)} skipped over tool cap")
    GoalBlocked(..)
    | GoalUnblocked
    | GoalCheck(..)
    | GoalReminder(..)
    | PlanReminder(..) => ""
  }
}

///|
/// Synchronous xlog handler feeding exact human chunks to an asynchronous
/// stdout writer. Unlike the JSONL drain, chunks are not newline-delimited:
/// assistant deltas remain a single naturally streamed response.
priv struct HumanRunStdout {
  renderer : HumanRunRenderer
  chunks : @async.Queue[String]
}

///|
fn HumanRunStdout::HumanRunStdout(
  suppress_events? : Bool = false,
) -> HumanRunStdout {
  {
    renderer: HumanRunRenderer(suppress_events~),
    chunks: Queue(kind=Unbounded),
  }
}

///|
impl @xlog.Handler for HumanRunStdout with fn handle(
  self : HumanRunStdout,
  entry : @xlog.Entry,
) -> Unit raise {
  guard @protocol.parse(entry.to_json()) is Some(event) else { return }
  let chunk = self.renderer.render(event)
  if chunk != "" {
    self.chunks.try_put(chunk) |> ignore
  }
}

///|
async fn HumanRunStdout::drain(self : HumanRunStdout) -> Unit {
  for ;; {
    let chunk = self.chunks.get() catch {
      error if @async.is_cancellation_error(error) => raise error
      _ => return
    }
    @stdio.stdout.write(chunk)
  }
}

///|
fn HumanRunStdout::close(self : HumanRunStdout) -> Unit {
  self.chunks.close()
}

///|
/// Finish a partially streamed assistant line before an out-of-band failure is
/// reported after the handler has drained.
fn HumanRunStdout::close_open_line(self : HumanRunStdout) -> Unit {
  let chunk = self.renderer.break_line()
  if chunk != "" {
    ignore(self.chunks.try_put(chunk) catch { _ => false })
  }
}

///|
/// Install the human stdout handler, retaining `OPENSEEK_LOG_FILE` as a raw
/// JSONL mirror for diagnostics and automation.
fn configure_human_run_logging(suppress_events~ : Bool) -> HumanRunStdout {
  let stdout = HumanRunStdout(suppress_events~)
  @xlog.global().set_level(Info)
  guard @env.get_env_var("OPENSEEK_LOG_FILE") is Some(path) && path != "" else {
    @xlog.global().set_handler(stdout)
    return stdout
  }
  let file = @xlog.File::File(path) catch {
    _ => {
      @xlog.global().set_handler(stdout)
      return stdout
    }
  }
  let handlers : Array[&@xlog.Handler] = [stdout, file]
  @xlog.global().set_handler(@xlog.Multi(handlers))
  stdout
}

///|
async fn with_human_run_stdout(
  suppress_events~ : Bool,
  body : async () -> Unit,
) -> Unit {
  let stdout = configure_human_run_logging(suppress_events~)
  @async.with_task_group(group => {
    group.spawn_bg() <| () => { stdout.drain() }
    defer {
      stdout.close_open_line()
      stdout.close()
    }
    body()
  })
}

///|
async fn with_run_stdout(
  format : RunOutputFormat,
  fleet~ : Bool,
  body : async () -> Unit,
) -> Unit {
  match format {
    Human => with_human_run_stdout(suppress_events=fleet, body)
    Jsonl => with_jsonl_stdout(body)
  }
}
