///|
async fn run_shell(arguments : Json) -> @agent_tool.ToolAction {
  match @shell.definition().execute {
    Async(execute) => execute(arguments)
    Sync(_) => fail("shell tool should be async")
  }
}

///|
async test "shell runs cmd and returns exit code plus output" {
  let result = run_shell({ "cmd": "echo hello" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_true(output.content =~ re"^exit=0\nhello\n?$")
}

///|
async test "shell propagates non-zero exit codes" {
  let result = run_shell({ "cmd": "exit 7" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content =~ re"^exit=7\n?$")
}

///|
async test "shell honors cwd when non-empty" {
  let result = run_shell({ "cmd": "pwd", "cwd": "/tmp" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_true(output.content =~ re"^exit=0\n.*/tmp\n?$")
}

///|
async test "shell reads a virtual filesystem fixture from cwd" {
  let project = @fs.tmpdir(prefix="openseek-shell-vfs-")
  @vfs.FileSystem({
    "data/input.txt": (
      #|shell-vfs
      #|
    ),
  }).write_to(project)
  let result = run_shell({ "cmd": "cat data/input.txt", "cwd": project })
  let _ = @fs.rmdir(project, recursive=true) catch { _ => () }
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  inspect(
    output.content.trim(),
    content=(
      #|exit=0
      #|shell-vfs
    ),
  )
}

///|
async test "shell treats empty cwd as missing" {
  let result = run_shell({ "cmd": "echo cwdless", "cwd": "" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_true(output.content =~ re"^exit=0\ncwdless\n?$")
}

///|
async test "shell truncates oversized output and marks it as error" {
  let result = run_shell({ "cmd": "printf abcdef", "max_output_chars": 3 })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(
    output.content =~ re"^exit=0\ntruncated=true\noutput_chars=6\nshown_chars=3\nabc$",
  )
  assert_false(output.content.contains("abcdef"))
}

///|
async test "shell merges stderr into the captured output" {
  let result = run_shell({ "cmd": "echo oops 1>&2" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_true(output.content =~ re"^exit=0\noops\n?$")
}

///|
async test "shell times out long running commands" {
  let result = run_shell({ "cmd": "sleep 2", "timeout_ms": 50 })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_eq(output.content, "error: shell command timed out after 50ms")
}

///|
async test "shell rejects moon run and points to moon_cmd" {
  let result = run_shell({ "cmd": "moon run --target native cmd/main -- .a" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("shell blocked `moon run`"))
  assert_true(output.content.contains("moon_cmd"))
}

///|
async test "shell rejects moon_cmd as a shell command" {
  let result = run_shell({ "cmd": "moon_cmd run cmd/main" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("moon_cmd is a tool"))
}

///|
async test "shell rejects missing cmd" {
  let result = run_shell({ "cwd": "/tmp" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("error: shell requires"))
  assert_true(output.content.contains("arguments.cmd"))
}

///|
async test "shell rejects non-object arguments" {
  let result = run_shell(Json::null())
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_eq(output.content, "error: shell requires object arguments")
}

///|
async test "shell rejects non-existent cwd" {
  let result = run_shell({ "cmd": "echo hello", "cwd": "/nonexistent/path/xyz" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("cwd does not exist"))
}

///|
async test "shell rejects cwd that is a file not a directory" {
  let result = run_shell({ "cmd": "echo hello", "cwd": "/dev/null" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("cwd is not a directory"))
}
