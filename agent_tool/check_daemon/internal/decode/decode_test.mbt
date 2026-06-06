///|
test "decode start arguments" {
  let input = decode({
    "action": "start",
    "cmd": "moon check --watch --output-json",
    "cwd": "/tmp/project",
    "name": "moon",
    "max_output_chars": 7,
    "initial_wait_ms": 12,
  })
  assert_true(input.action is Start)
  guard input.cmd is Some(cmd) else { fail("missing cmd") }
  assert_eq(cmd, "moon check --watch --output-json")
  guard input.cwd is Some(cwd) else { fail("missing cwd") }
  assert_eq(cwd, "/tmp/project")
  guard input.name is Some(name) else { fail("missing name") }
  assert_eq(name, "moon")
  assert_eq(input.max_output_chars, 7)
  assert_eq(input.initial_wait_ms, 12)
}

///|
test "decode status and stop require id" {
  let status = decode({ "action": "status", "id": "daemon-1" })
  assert_true(status.action is Status)
  guard status.id is Some(status_id) else { fail("missing status id") }
  assert_eq(status_id, "daemon-1")
  let stop = decode({ "action": "stop", "id": "daemon-1" })
  assert_true(stop.action is Stop)
  guard stop.id is Some(stop_id) else { fail("missing stop id") }
  assert_eq(stop_id, "daemon-1")
}

///|
test "decode rejects missing start command" {
  let _ = decode({ "action": "start" }) catch {
    error => {
      assert_true("\{error}".contains("arguments.cmd"))
      return
    }
  }
  fail("missing cmd parsed")
}

///|
test "decode rejects missing status id" {
  let _ = decode({ "action": "status" }) catch {
    error => {
      assert_true("\{error}".contains("arguments.id"))
      return
    }
  }
  fail("missing id parsed")
}

///|
test "decode caps numeric options" {
  let input = decode({
    "action": "start",
    "cmd": "echo ok",
    "max_output_chars": 999999,
    "initial_wait_ms": 999999,
  })
  assert_eq(input.max_output_chars, hard_max_output_chars)
  assert_eq(input.initial_wait_ms, hard_initial_wait_ms)
}
