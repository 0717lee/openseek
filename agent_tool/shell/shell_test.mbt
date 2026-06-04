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
async test "shell leaves output at exact limit as a normal result" {
  let result = run_shell({ "cmd": "printf abc", "max_output_chars": 3 })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_eq(output.content, "exit=0\nabc")
}

///|
async test "shell counts output limits in characters for non-ascii text" {
  let result = run_shell({ "cmd": "printf '中中'", "max_output_chars": 2 })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_eq(output.content, "exit=0\n中中")
}

///|
async test "shell leaves four-byte utf8 output at exact character limit" {
  let result = run_shell({ "cmd": "printf '😀'", "max_output_chars": 1 })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_eq(output.content, "exit=0\n😀")
}

///|
async test "shell stops oversized output while the command is still running" {
  let result = run_shell({
    "cmd": "printf abcdef; sleep 2",
    "max_output_chars": 3,
    "timeout_ms": 1000,
  })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(
    output.content =~ re"^exit=cancelled\ntruncated=true\noutput_limit_reached=true\nshown_chars=3\nmax_output_chars=3\nabc$",
  )
  assert_false(output.content.contains("timed out"))
  assert_false(output.content.contains("abcdef"))
}

///|
async test "shell does not cut multi-byte utf8 output mid-character" {
  let result = run_shell({
    "cmd": "printf '中中中'; sleep 2",
    "max_output_chars": 2,
    "timeout_ms": 1000,
  })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(
    output.content =~ re"^exit=cancelled\ntruncated=true\noutput_limit_reached=true\nshown_chars=2\nmax_output_chars=2\n中中$",
  )
  assert_false(output.content.contains("�"))
  assert_false(output.content.contains("中中中"))
}

///|
async test "shell does not split four-byte utf8 characters" {
  let result = run_shell({
    "cmd": "printf '😀😀'; sleep 2",
    "max_output_chars": 1,
    "timeout_ms": 1000,
  })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(
    output.content =~ re"^exit=cancelled\ntruncated=true\noutput_limit_reached=true\nshown_chars=1\nmax_output_chars=1\n😀$",
  )
  assert_false(output.content.contains("�"))
  assert_false(output.content.contains("😀😀"))
}

///|
async test "shell reports binary output as a tool error" {
  let result = run_shell({ "cmd": "printf '\\377'" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("error running shell:"))
  assert_true(output.content.contains("Malformed"))
}

///|
async test "shell output limit wins over an unbounded producer" {
  let result = run_shell({
    "cmd": "while :; do printf yyyyyyyyyy; done",
    "max_output_chars": 5,
    "timeout_ms": 1000,
  })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(
    output.content =~ re"^exit=cancelled\ntruncated=true\noutput_limit_reached=true\nshown_chars=5\nmax_output_chars=5\nyyyyy$",
  )
  assert_false(output.content.contains("timed out"))
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
