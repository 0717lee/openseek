///|
/// Live end-to-end eval for the background-shell workflow: drive the real
/// engine (`openseek serve`, real model) over JSONL and assert the three ways a
/// background job reaches the model:
///
/// 1. **Mid-turn notice** — the model starts a slow background job, does real
///    foreground work meanwhile, and must fold the pushed completion notice
///    into its answer without `sleep` chains or `shell_output` polling loops.
/// 2. **Idle notice** — a job outlives its turn; the idle engine must emit the
///    untagged `background_notice` event.
/// 3. **Durability** — a later turn reads the finished job's output by id.
///
/// Run manually (needs a real API key; not wired into CI):
///
///   moon run --target native eval/bgjobs_e2e
///
/// Exits non-zero listing the failed assertions; prints ALL PASS otherwise.
async fn main {
  // This eval spends real model turns; skip cleanly where no key is configured.
  // `DEEPSEEK` is the engine's API-key env var (see
  // @agentcli.api_key_env_for_model), not DEEPSEEK_API_KEY.
  guard @env.get_env_var("DEEPSEEK") is Some(_) else {
    println("SKIP: DEEPSEEK is not set; this eval drives the live engine")
    return
  }
  let failures : Array[String] = []
  @async.with_task_group(group => {
    let engine = Engine::spawn(group)
    run_phases(engine, failures)
    // Returning cancels the task group, which tears the engine process down —
    // the serve child is spawned on this group, so nothing outlives the eval.
  })
  if failures.length() > 0 {
    for failure in failures {
      println("FAIL  \{failure}")
    }
    fail("bgjobs e2e: \{failures.length()} assertion(s) failed")
  }
  println("ALL PASS: background-job workflow verified against the live engine")
}

///|
/// The engine under test: `openseek serve` run through `moon run` (always the
/// freshly built binary — never a stale one from PATH), talking JSONL on
/// stdin/stdout. Events land in `events` in arrival order.
priv struct Engine {
  writer : @process.WriteToProcess
  events : @async.Queue[Json]
}

///|
async fn[G] Engine::spawn(group : @async.TaskGroup[G]) -> Engine {
  let (child_stdin, writer) = @process.write_to_process()
  let (reader, child_stdout) = @process.read_from_process()
  let (stderr_reader, child_stderr) = @process.read_from_process()
  let _proc = @process.spawn(
    group,
    "moon",
    ["run", "--target", "native", "cmd/openseek", "--", "serve"],
    stdin=child_stdin,
    stdout=child_stdout,
    stderr=child_stderr,
    no_wait=true,
  )
  // Drain stderr (moon build progress, engine diagnostics) so the child can
  // never block on a full pipe; the content is irrelevant to the assertions.
  group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
    for ;; {
      if (stderr_reader.read_some(max_len=4096) catch { _ => None }) is None {
        break
      }
    }
  }
  let events : @async.Queue[Json] = Queue(kind=Unbounded)
  group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
    @jsonl.each(reader, json => {
      ignore(events.try_put(json) catch { _ => false })
    })
  }
  { writer, events }
}

///|
async fn Engine::prompt(self : Engine, text : String) -> Unit {
  let command : Json = { "command": "prompt", "text": text.to_json() }
  self.writer.write("\{command.stringify()}\n")
}

///|
/// Await the first event matching `matches`, recording everything seen (matched
/// or not) into `seen`. `None` on timeout.
async fn Engine::wait_for(
  self : Engine,
  timeout_ms : Int,
  seen : Array[Json],
  matches : (Json) -> Bool,
) -> Json? {
  @async.with_timeout_opt(timeout_ms, () => {
    let mut found : Json = Json::null()
    for ;; {
      let event = self.events.get()
      seen.push(event)
      if matches(event) {
        found = event
        break
      }
    }
    found
  })
}

///|
fn check(
  failures : Array[String],
  name : String,
  passed : Bool,
  detail? : String = "",
) -> Unit {
  let label = if passed { "PASS" } else { "FAIL" }
  let suffix = if detail == "" { "" } else { " — \{detail}" }
  println("  \{label}  \{name}\{suffix}")
  if !passed {
    failures.push(name)
  }
}

///|
fn finished_answer(event : Json?) -> String {
  match event {
    Some({ "event": String("agent_finished"), "answer": String(answer), .. }) =>
      answer
    _ => ""
  }
}

///|
async fn run_phases(engine : Engine, failures : Array[String]) -> Unit {
  // ---- Phase 1: mid-turn notice ----
  println(
    "== Phase 1: background job + foreground work; notice folded in mid-turn ==",
  )
  engine.prompt(
    (
      #|Using the shell tool, first start this exact command as a background job
      #|(run_in_background=true): sh -c 'sleep 5; echo NOTICE-MARK-4242'.
      #|Then, in the foreground, run these three commands one at a time and note
      #|each result: `ls agent_tool/shell_exec | wc -l`,
      #|`ls agent_tool/bgjobs | wc -l`, `ls agent_tool/shell_output | wc -l`.
      #|Do NOT use sleep to wait and do NOT poll shell_output in a loop; when the
      #|background job's completion notice arrives, read its output with
      #|shell_output and put the exact marker line it printed in your final
      #|answer together with the three counts.
    ),
  )
  let seen1 : Array[Json] = []
  let finished1 = engine.wait_for(360_000, seen1, event => {
    event is { "event": String("agent_finished"), .. }
  })
  let started = seen1
    .iter()
    .any(event => {
      event
      is { "event": String("tool_result"), "content": String(content), .. } &&
      content.contains("started background job")
    })
  let notice_mid = seen1
    .iter()
    .any(event => {
      event
      is { "event": String("steer_applied"), "kind": String("notice"), .. }
    })
  let read_output = seen1
    .iter()
    .any(event => {
      event
      is {
        "event": String("tool_result"),
        "tool_name": String("shell_output"),
        "content": String(content),
        ..
      } &&
      content.contains("NOTICE-MARK-4242")
    })
  check(failures, "P1: job started via run_in_background", started)
  check(
    failures, "P1: completion notice pushed mid-turn (steer_applied kind=notice)",
    notice_mid,
  )
  check(failures, "P1: model read the job output via shell_output", read_output)
  check(
    failures,
    "P1: final answer contains the marker",
    finished_answer(finished1).contains("NOTICE-MARK-4242"),
  )

  // ---- Phase 2: idle notice ----
  println(
    "== Phase 2: job outlives the turn; idle engine pushes background_notice ==",
  )
  engine.prompt(
    (
      #|Start this exact command as a background job (run_in_background=true) and
      #|then finish immediately, answering with just the job id — do not wait for
      #|it and do not read its output: sh -c 'sleep 6; echo IDLE-MARK-777'.
    ),
  )
  let seen2 : Array[Json] = []
  let finished2 = engine.wait_for(240_000, seen2, event => {
    event is { "event": String("agent_finished"), .. }
  })
  check(failures, "P2: turn finished before the job", finished2 is Some(_))
  let seen2b : Array[Json] = []
  let idle_notice = engine.wait_for(30_000, seen2b, event => {
    event is { "event": String("background_notice"), .. }
  })
  check(
    failures,
    "P2: idle engine emitted untagged background_notice",
    idle_notice is Some(_),
    detail=match idle_notice {
      Some({ "content": String(content), .. }) => content
      _ => ""
    },
  )

  // ---- Phase 3: the durable notice is usable next turn ----
  println("== Phase 3: a later turn reads the finished job by id ==")
  engine.prompt(
    (
      #|A background job you started earlier has finished. Read its output with
      #|shell_output and tell me the exact marker line it printed.
    ),
  )
  let seen3 : Array[Json] = []
  let finished3 = engine.wait_for(240_000, seen3, event => {
    event is { "event": String("agent_finished"), .. }
  })
  check(
    failures,
    "P3: model retrieved the idle job's output",
    finished_answer(finished3).contains("IDLE-MARK-777"),
  )
}
