///|
/// `openseek subrun <kind>` — the INTERNAL child mode the engine spawns for
/// one sub-run. Contract (see `agent_subrun`): the parent writes one JSON
/// input line on stdin and holds the pipe open; stdin EOF is the graceful
/// cancel signal; this process emits its standard JSONL events on stdout
/// and, when the kind produced a value, one final `{"subrun_report": ...}`
/// line. The API key rides the inherited environment; model, endpoint, and
/// the step ceiling ride argv.
///
/// Failure paths NEVER `@sys.exit` from inside the logging scope: the event
/// queue drains asynchronously, and an immediate exit would discard the
/// very failure event the parent classifies on. Every path returns
/// normally; `with_jsonl_stdout`'s teardown flushes the events, and the
/// report — printed only after that teardown — is the final line by
/// construction.
///
/// Kinds: `explore` (the read-only scout) and `echo` (a modelless probe
/// that emits two canned events and echoes its input as the report — used
/// by the parent-runner tests and the cram end-to-end doc).
async fn run_subrun_command(matches : @argparse.Matches) -> Unit {
  let report : Ref[Json?] = { val: None }
  with_jsonl_stdout(() => {
    let workspace_root = prepare_workspace_root(matches, log_created=false)
    let (model, thinking, api_url) = agent_settings(matches)
    let kind = match matches {
      { values: { "kind": [kind, ..], .. }, .. } => "\{kind}"
      _ => fail("missing parsed argument: kind")
    }
    // One input line; the pipe stays open afterwards as the cancel channel.
    guard @stdio.stdin.read_until("\n") is Some(line) else {
      // EOF before input: the parent gave up before we started.
      return
    }
    guard (Some(@json.parse(line.trim(chars="\r\n").to_owned())) catch {
        _ => None
      })
      is Some(input) else {
      @emit.emit(CommandError(error="subrun input is not JSON"))
      return
    }
    @async.with_task_group() <| group => {
      // Failures are caught INSIDE the task: a spawned task's failure
      // cancels the group body, so a catch around `work.wait()` observes
      // only the ambient cancellation and can never see the real error
      // (adversarial-review finding). In here, cancellation still
      // re-raises; every real error becomes the TurnFailed event the
      // parent classifies on, and the task completes normally.
      let work = group.spawn(() => {
        dispatch_kind(
          kind, input, matches, model, thinking, api_url, workspace_root,
        ) catch {
          error if @async.is_being_cancelled() ||
            @async.is_cancellation_error(error) => raise error
          error => {
            @emit.emit(TurnFailed(error="subrun \{kind} failed: \{error}"))
            None
          }
        }
      })
      // The cancel channel: the parent closing our stdin means "stop now,
      // gracefully" — cancel the kind's turn (its loop records Interrupted
      // and tears its tool subprocesses down) and exit without a report.
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        while @stdio.stdin.read_until("\n") is Some(_) {
          // Drain anything the parent writes; only EOF is meaningful.
        }
        work.cancel()
      }
      report.val = work.wait() catch {
        // Parent-initiated cancel (stdin EOF): exit without a report; the
        // parent is already classifying the run from what it observed.
        error if @async.is_being_cancelled() ||
          @async.is_cancellation_error(error) => None
        error => raise error
      }
    }
  })
  // Logging is closed: every queued event line reached stdout. Writing the
  // report through the SAME channel (@stdio.stdout, like the review CLI)
  // keeps one tracked writer on fd 1 — mixing println's C-stdio offset in
  // corrupts output when stdout is a regular file (review finding).
  if report.val is Some(value) {
    @stdio.stdout.write(@agent_subrun.report_line(value) + "\n")
  }
}

///|
/// Run one kind in this process and return its report, if any.
async fn dispatch_kind(
  kind : String,
  input : Json,
  matches : @argparse.Matches,
  model : @deepseek.Model,
  thinking : @deepseek.ThinkingMode,
  api_url : String?,
  workspace_root : String,
) -> Json? {
  match kind {
    "explore" => {
      let api_key = @agentcli.api_key(matches, model)
      let report = @agent_explore.run_child(
        input,
        api_key~,
        model~,
        max_steps=max_steps(matches).unwrap_or(
          @agent_explore.default_explore_max_steps,
        ),
        thinking~,
        api_url?,
        workspace_root~,
      )
      report.map(report => report.to_json())
    }
    "echo" => {
      // Modelless probe: two canned events plus the input echoed back —
      // enough to exercise spawn, drain, accounting, and the typed report
      // channel end to end.
      @emit.emit(AgentStep(step=1))
      @emit.emit(
        Usage(usage={
          prompt_tokens: 7,
          completion_tokens: 3,
          total_tokens: 10,
          prompt_cache_hit_tokens: 0,
          prompt_cache_miss_tokens: 7,
        }),
      )
      Some(input)
    }
    _ => {
      @emit.emit(CommandError(error="unknown subrun kind: \{kind}"))
      None
    }
  }
}

///|
/// The executable to spawn for a child sub-run: this process's own binary,
/// resolved from argv[0]. A path with a separator is made absolute (the
/// child runs with a different cwd, so a relative path would break); a bare
/// name stays PATH-resolved, matching however this process was launched.
/// Never hardcode a name: parent and child must be the SAME binary, or the
/// typed report channel's same-codec guarantee is gone.
async fn self_executable() -> String {
  let argv0 = match @env.args() {
    [first, ..] => first
    _ => "openseek"
  }
  // Under `moon run` on the tcc debug path argv0 is the generated .c
  // SOURCE, not an executable: spawning it would fail every explore call.
  // Fall back to PATH resolution — the same case the TUI handles for its
  // engine spawn (cmd/tui `moon_native_tcc_run_args`).
  if argv0.has_suffix(".c") {
    return "openseek"
  }
  if argv0.contains("/") || argv0.contains("\\") {
    @fs.realpath(argv0) catch {
      _ => argv0
    }
  } else {
    argv0
  }
}
