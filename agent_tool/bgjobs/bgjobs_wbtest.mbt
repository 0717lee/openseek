///|
/// Poll `id` until it leaves `Running`, failing after a bounded deadline so a
/// hung child can never hang the test. Async tests run in parallel, so each test
/// isolates its own runtime and jobs.
#cfg(not(platform="windows"))
async fn poll_until_terminal(
  rt : BgJobRuntime,
  id : String,
  ticks? : Int = 200,
) -> BgJobSnapshot {
  for _ in 0..<ticks {
    if rt.snapshot(id) is Some(snap) && !(snap.status is Running) {
      return snap
    }
    @async.sleep(25)
  }
  fail("bg job \{id} did not reach a terminal state in time")
}

///|
#cfg(not(platform="windows"))
async test "bg job runs to completion and captures output" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    let id = rt.start(
      program="sh",
      args=["-c", "printf hello"],
      command="printf hello",
    )
    let snap = poll_until_terminal(rt, id)
    assert_true(snap.status is Exited(0))
    assert_true(snap.output.contains("hello"))
    assert_true(snap.exit_code is Some(0))
  })
}

///|
#cfg(not(platform="windows"))
async test "bg job records a non-zero exit code" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    let id = rt.start(program="sh", args=["-c", "exit 3"], command="exit 3")
    let snap = poll_until_terminal(rt, id)
    assert_true(snap.status is Exited(3))
    assert_true(snap.exit_code is Some(3))
  })
}

///|
#cfg(not(platform="windows"))
async test "stop terminates a running job" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    // Spawn the sleeper directly (no shell) so `stop` cancels the sleeper itself
    // rather than a shell wrapper, and leaves no orphan behind.
    let id = rt.start(program="sleep", args=["30"], command="sleep 30")
    @async.sleep(50)
    assert_true(rt.snapshot(id).unwrap().status is Running)
    assert_true(rt.stop(id))
    assert_true(rt.snapshot(id).unwrap().status is Stopped)
  })
}

///|
#cfg(not(platform="windows"))
async test "job with a descendant holding the pipe still reaches a terminal state" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    // The parent exits immediately but backgrounds a short-lived child that
    // inherits — and holds open — stdout/stderr, so pipe EOF never comes; exit
    // must be detected via wait(), not by reading to EOF. `sleep 1` bounds the
    // intentional descendant so the test leaves nothing behind for long.
    let id = rt.start(
      program="sh",
      args=["-c", "sleep 1 & exit 0"],
      command="detached child",
    )
    let snap = poll_until_terminal(rt, id)
    assert_true(snap.status is Exited(0))
  })
}

///|
#cfg(not(platform="windows"))
async test "concurrent stop calls all complete without hanging" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    let id = rt.start(program="sleep", args=["30"], command="sleep 30")
    @async.sleep(50)
    // Two stops race on the same job. The inner group awaits both, so a caller
    // that blocked forever would deadlock the test rather than reach the asserts.
    let done = [false, false]
    @async.with_task_group(g => {
      g.spawn_bg(() => done[0] = rt.stop(id))
      g.spawn_bg(() => done[1] = rt.stop(id))
    })
    assert_true(done[0])
    assert_true(done[1])
    assert_true(rt.snapshot(id).unwrap().status is Stopped)
  })
}

///|
#cfg(not(platform="windows"))
async test "stop terminates a job that closed its streams but is still running" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    // Redirect the shell's own stdout/stderr away, then `exec` the sleeper so the
    // tracked PID becomes the still-running process: the monitor reaches EOF and
    // must fall back to wait() while the child keeps running — the stop/wait race
    // — and `stop` cancels the sleeper directly, leaving no orphan.
    let id = rt.start(
      program="sh",
      args=["-c", "exec >/dev/null 2>&1; exec sleep 30"],
      command="closed streams",
    )
    @async.sleep(100)
    assert_true(rt.snapshot(id).unwrap().status is Running)
    assert_true(rt.stop(id))
    assert_true(rt.snapshot(id).unwrap().status is Stopped)
    // A second stop must be idempotent and must not block on the terminal job.
    assert_true(rt.stop(id))
  })
}

///|
#cfg(not(platform="windows"))
async test "captures full output of a fast command that exits during a burst" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    // A burst that fits under the budget but may still be buffered in the pipe
    // when the process exits: none of it may be lost when the job reports Exited.
    let id = rt.start(
      program="sh",
      args=["-c", "printf '%30000s' '' | tr ' ' a"],
      command="burst",
      max_output_chars=50000,
    )
    let snap = poll_until_terminal(rt, id)
    assert_true(snap.status is Exited(0))
    assert_false(snap.output_truncated)
    assert_true(snap.output.char_length() == 30000)
  })
}

///|
#cfg(not(platform="windows"))
async test "a non-positive output budget is clamped, not left unbounded" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    let id = rt.start(
      program="sh",
      args=["-c", "printf hello"],
      command="printf hello",
      max_output_chars=0,
    )
    let snap = poll_until_terminal(rt, id)
    assert_true(snap.output_truncated)
    assert_true(snap.output.char_length() <= 1)
  })
}

///|
#cfg(not(platform="windows"))
async test "the final incomplete utf-8 byte is surfaced at terminal status" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    // A lone 0xC3 (a 2-byte lead with no continuation) is the whole output, so
    // it stays in pending_bytes until the end-of-stream flush; the terminal
    // snapshot must already include its lossy replacement character.
    let id = rt.start(
      program="sh",
      args=["-c", "printf '\\303'"],
      command="incomplete",
    )
    let snap = poll_until_terminal(rt, id)
    assert_true(snap.status is Exited(0))
    assert_true(snap.output.char_length() >= 1)
  })
}

///|
#cfg(not(platform="windows"))
async test "output is capped to the trailing max_output_chars" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    let id = rt.start(
      program="sh",
      args=["-c", "seq 1 100000"],
      command="seq",
      max_output_chars=100,
    )
    let snap = poll_until_terminal(rt, id)
    assert_true(snap.output_truncated)
    assert_true(snap.output.char_length() <= 100)
  })
}

///|
#cfg(not(platform="windows"))
async test "two jobs run independently with distinct ids" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    let a = rt.start(program="sh", args=["-c", "printf aaa"], command="a")
    let b = rt.start(program="sh", args=["-c", "printf bbb"], command="b")
    assert_true(a != b)
    let sa = poll_until_terminal(rt, a)
    let sb = poll_until_terminal(rt, b)
    assert_true(sa.output.contains("aaa"))
    assert_true(sb.output.contains("bbb"))
    assert_true(rt.list().length() == 2)
  })
}

///|
#cfg(not(platform="windows"))
async test "bg job preserves non-ascii output" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    let id = rt.start(
      program="sh",
      args=["-c", "printf 'héllo wörld'"],
      command="printf",
    )
    let snap = poll_until_terminal(rt, id)
    assert_true(snap.output.contains("héllo wörld"))
  })
}

///|
#cfg(not(platform="windows"))
async test "snapshot and stop handle unknown ids" {
  @async.with_task_group(group => {
    let rt = BgJobRuntime::new(AgentTaskScope(group))
    assert_true(rt.snapshot("nope") is None)
    assert_false(rt.stop("nope"))
  })
}

///|
test "split_valid_utf8 carries an incomplete trailing character across chunks" {
  // "café" = 63 61 66 C3 A9 (é is a 2-byte sequence).
  let full : Bytes = [0x63, 0x61, 0x66, 0xC3, 0xA9]
  let (text, rest) = split_valid_utf8(full)
  assert_true(text == "café")
  assert_true(rest.length() == 0)
  // A chunk that ends on é's lead byte: decode "caf" now, hold the lead byte.
  let truncated : Bytes = [0x63, 0x61, 0x66, 0xC3]
  let (head, tail) = split_valid_utf8(truncated)
  assert_true(head == "caf")
  assert_true(tail.length() == 1)
  // The next chunk's continuation byte completes é rather than corrupting it.
  let joined = Buffer()
  joined.write_bytes(tail)
  joined.write_bytes(([0xA9] : Bytes))
  let (completed, remainder) = split_valid_utf8(joined.to_bytes())
  assert_true(completed == "é")
  assert_true(remainder.length() == 0)
}

///|
test "split_valid_utf8 surfaces corrupt trailing bytes instead of hiding them" {
  // 0xff is neither a valid lead nor a continuation byte: it must be decoded
  // (lossily) right away, not held in pending bytes waiting for a completion
  // that can never come — otherwise a running job's output would vanish.
  let bytes : Bytes = [0x68, 0x69, 0xff]
  let (text, rest) = split_valid_utf8(bytes)
  assert_true(rest.length() == 0)
  assert_true(text.has_prefix("hi"))
  assert_true(text.char_length() >= 3)
}

///|
test "split_valid_utf8 does not carry malformed multi-byte prefixes" {
  // 0xE0 0x80 looks like the start of a 3-byte char, but 0x80 is below the
  // legal 0xA0 for 0xE0 (an overlong encoding) — surface it now, don't hold it.
  let (t1, r1) = split_valid_utf8(([0x78, 0xE0, 0x80] : Bytes))
  assert_true(r1.length() == 0)
  assert_true(t1.has_prefix("x"))
  // 0xF4 0x90 is out of range (0xF4 continuations must be 0x80..0x8F).
  let (t2, r2) = split_valid_utf8(([0x78, 0xF4, 0x90] : Bytes))
  assert_true(r2.length() == 0)
  assert_true(t2.has_prefix("x"))
  // A genuinely valid incomplete prefix (0xE0 0xA0, missing its last byte) is
  // still carried, so real multi-byte output is not corrupted.
  let (t3, r3) = split_valid_utf8(([0x78, 0xE0, 0xA0] : Bytes))
  assert_true(t3 == "x")
  assert_true(r3.length() == 2)
}
