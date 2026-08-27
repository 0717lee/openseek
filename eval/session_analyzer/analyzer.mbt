///|
/// Generic evaluation of one recorded OpenSeek session.
///
/// This deliberately knows nothing about prompt-task manifests, workspaces, or
/// task-specific validation. Callers that own a benchmark can attach their own
/// metadata and probes around this result.
pub struct EvalResult {
  session_id : String
  success : Bool
  reason : String
  warnings : String
  steps : Int
  tool_results : Int
  tool_errors : Int
  shell_uses : Int
  shell_failures : Int
  runtime_notices : Int
  finished : Bool
  finish_message : String
  terminal_status : String
  terminal_message : String
}

///|
priv struct SessionMetrics {
  finished : Bool
  finish_message : String
  steps : Int
  tool_results : Int
  tool_errors : Int
  shell_uses : Int
  shell_failures : Int
  runtime_notices : Int
  terminal_status : String
  terminal_message : String
}

///|
/// Analyze one already-loaded session.
pub fn analyze_session(session : @agent_session.Session) -> EvalResult {
  let metrics = summarize_session(session)
  let reason = if metrics.finished {
    "ok"
  } else if metrics.terminal_status != "" {
    "agent terminal " +
    metrics.terminal_status +
    ": " +
    metrics.terminal_message
  } else {
    "finish marker missing"
  }
  let warnings = if metrics.shell_uses > 0 {
    "shell output observed \{metrics.shell_uses} time(s)"
  } else {
    ""
  }
  {
    session_id: session.id().value(),
    success: metrics.finished,
    reason,
    warnings,
    steps: metrics.steps,
    tool_results: metrics.tool_results,
    tool_errors: metrics.tool_errors,
    shell_uses: metrics.shell_uses,
    shell_failures: metrics.shell_failures,
    runtime_notices: metrics.runtime_notices,
    finished: metrics.finished,
    finish_message: metrics.finish_message,
    terminal_status: metrics.terminal_status,
    terminal_message: metrics.terminal_message,
  }
}

///|
/// Build the transcript text used by analyzers that count prompt-sensitive
/// behavior. User prompts and summaries are intentionally excluded so a task
/// statement cannot inflate model-behavior counters.
pub fn transcript_text(session : @agent_session.Session) -> String {
  let out = StringBuilder()
  let mut previous_assistant_answer : String? = None
  for event in session.events() {
    let item = event.item()
    let repeated_terminal = item is Terminal(Finished(answer)) &&
      previous_assistant_answer is Some(previous) &&
      previous == answer
    let checkpoint_replay = item is Assistant(message) && message.is_replay()
    if !repeated_terminal && !checkpoint_replay {
      append_item_text(out, item)
    }
    previous_assistant_answer = match item {
      Assistant(message) => Some(message.content())
      _ => None
    }
  }
  out.to_string()
}

///|
fn summarize_session(session : @agent_session.Session) -> SessionMetrics {
  let mut finished = false
  let mut finish_message = ""
  let steps = session.events().iter().count_if(event => event.is_agent_step())
  let mut tool_results = 0
  let mut tool_errors = 0
  let mut shell_uses = 0
  let mut shell_failures = 0
  let mut runtime_notices = 0
  let mut terminal_status = ""
  let mut terminal_message = ""
  for event in session.events() {
    match event.item() {
      Assistant(_) => ()
      Tool(result) => {
        tool_results += 1
        if result.tool_name() == "shell" {
          shell_uses += 1
          // Use the recorded `is_error` flag rather than re-parsing the shell
          // output: the tool already decided success/failure, so this stays
          // correct regardless of the output format.
          if result.is_error() {
            shell_failures += 1
          }
        }
        if result.is_error() {
          tool_errors += 1
        }
      }
      Runtime(_) => runtime_notices += 1
      Terminal(Finished(message)) =>
        if message.has_prefix(@agent_session.ContextYieldAnswerPrefix) {
          // A context-ceiling yield is durably Finished (replay/chaining)
          // but NOT task success: the work was checkpointed mid-flight. The
          // synthetic terminal is not a model step either.
          finished = false
          terminal_status = "context_yield"
          terminal_message = message
        } else {
          finished = true
          finish_message = message
          terminal_status = "finished"
          terminal_message = message
        }
      Terminal(Aborted(message)) => {
        finished = false
        terminal_status = "aborted"
        terminal_message = message
      }
      Terminal(Interrupted(message)) => {
        finished = false
        terminal_status = "interrupted"
        terminal_message = message
      }
      Terminal(Failed(message)) => {
        finished = false
        terminal_status = "failed"
        terminal_message = message
      }
      ApprovalRequested(_) | ApprovalResolved(_) | Summary(_) | User(_) => ()
    }
  }
  {
    finished,
    finish_message,
    steps,
    tool_results,
    tool_errors,
    shell_uses,
    shell_failures,
    runtime_notices,
    terminal_status,
    terminal_message,
  }
}

///|
fn append_item_text(
  out : StringBuilder,
  item : @agent_session.SessionItem,
) -> Unit {
  match item {
    User(_) | Summary(_) | ApprovalRequested(_) | ApprovalResolved(_) => ()
    Assistant(message) => {
      if message.reasoning_content() is Some(reasoning) {
        write_line(out, reasoning)
      }
      write_line(out, message.content())
      for call in message.tool_calls() {
        write_line(out, call.name)
        write_line(out, call.arguments)
      }
    }
    Tool(result) => {
      write_line(out, result.tool_name())
      write_line(out, result.content())
    }
    Runtime(notice) => write_line(out, notice.content())
    Terminal(terminal) =>
      match terminal {
        Finished(message)
        | Aborted(message)
        | Interrupted(message)
        | Failed(message) => write_line(out, message)
      }
  }
}

///|
fn write_line(out : StringBuilder, value : String) -> Unit {
  out.write_string(value)
  out.write_char('\n')
}
