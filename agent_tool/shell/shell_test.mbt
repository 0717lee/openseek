///|
async fn run_shell(arguments : Json) -> @agent_tool.ToolAction {
  match @shell.definition().execute {
    Async(execute) => execute(arguments)
    Sync(_) => fail("shell tool should be async")
  }
}

///|
async fn run_shell_in_workspace(
  workspace_root : String,
  arguments : Json,
) -> @agent_tool.ToolAction {
  match @shell.definition(workspace_root~).execute {
    Async(execute) => execute(arguments)
    Sync(_) => fail("shell tool should be async")
  }
}

///|
#cfg(platform="windows")
test "shell description tells models to use PowerShell on Windows" {
  let description = @shell.definition().description
  assert_true(description.contains("PowerShell"))
  assert_true(description.contains("pwsh -NoProfile -Command"))
  assert_true(description.contains("PowerShell syntax"))
}

///|
#cfg(not(platform="windows"))
test "shell description tells models to use POSIX shell off Windows" {
  let description = @shell.definition().description
  assert_true(description.contains("POSIX shell"))
  assert_true(description.contains("sh -c"))
  assert_true(description.contains("POSIX shell syntax"))
}

///|
async test "shell runs cmd and returns exit code plus output" {
  let result = run_shell({ "cmd": "echo hello" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_true(output.content.contains("exit=0"))
  assert_true(output.content.contains("hello"))
}

///|
async test "shell propagates non-zero exit codes" {
  let result = run_shell({ "cmd": "exit 7" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("exit=7"))
}

///|
#cfg(platform="windows")
async test "shell follows PowerShell native Windows exit semantics" {
  let result = run_shell({ "cmd": "cmd /c exit 7" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("exit=1"))
}

///|
#cfg(platform="windows")
async test "shell follows final successful PowerShell command on Windows" {
  let result = run_shell({ "cmd": "cmd /c exit 7; Write-Output 'ok'" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_true(output.content.contains("exit=0"))
  assert_true(output.content.contains("ok"))
}

///|
async test "shell honors cwd when non-empty" {
  let dir = @fs.tmpdir(prefix="openseek-shell-cwd-")
  let result = run_shell({ "cmd": "echo cwd-ok > marker.txt", "cwd": dir })
  let dir_path : @path.Path = dir
  let marker_path = dir_path.join("marker.txt").normalize().to_string()
  let marker = @fs.read_file(marker_path).text() catch { _ => "" }
  @fs.rmdir(dir, recursive=true)
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_true(output.content.contains("exit=0"))
  assert_eq(marker.trim(), "cwd-ok")
}

///|
async test "shell uses the workspace root when cwd is omitted" {
  let dir = @fs.tmpdir(prefix="openseek-shell-workspace-")
  let result = run_shell_in_workspace(dir, {
    "cmd": "echo root-ok > marker.txt",
  })
  let marker = @fs.read_file(dir + "/marker.txt").text() catch { _ => "" }
  @fs.rmdir(dir, recursive=true)
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_true(output.content.contains("exit=0"))
  assert_eq(marker.trim(), "root-ok")
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
  @fs.rmdir(project, recursive=true)
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
  assert_true(output.content.contains("exit=0"))
  assert_true(output.content.contains("cwdless"))
}

///|
#cfg(platform="windows")
async test "shell leaves output at exact limit as a normal result on Windows" {
  let result = run_shell({
    "cmd": "[Console]::Out.Write('abc')",
    "max_output_chars": 3,
  })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_eq(output.content, "exit=0\nabc")
}

///|
#cfg(not(platform="windows"))
async test "shell leaves output at exact limit as a normal result on Unix" {
  let result = run_shell({ "cmd": "printf %s 'abc'", "max_output_chars": 3 })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_eq(output.content, "exit=0\nabc")
}

///|
#cfg(platform="windows")
async test "shell counts output limits in characters for non-ascii text on Windows" {
  let result = run_shell({
    "cmd": "[Console]::Out.Write('中中')",
    "max_output_chars": 2,
  })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_eq(output.content, "exit=0\n中中")
}

///|
#cfg(not(platform="windows"))
async test "shell counts output limits in characters for non-ascii text on Unix" {
  let result = run_shell({ "cmd": "printf %s '中中'", "max_output_chars": 2 })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_eq(output.content, "exit=0\n中中")
}

///|
#cfg(platform="windows")
async test "shell leaves four-byte utf8 output at exact character limit on Windows" {
  let result = run_shell({
    "cmd": "[Console]::Out.Write('😀')",
    "max_output_chars": 1,
  })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_eq(output.content, "exit=0\n😀")
}

///|
#cfg(not(platform="windows"))
async test "shell leaves four-byte utf8 output at exact character limit on Unix" {
  let result = run_shell({ "cmd": "printf %s '😀'", "max_output_chars": 1 })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_eq(output.content, "exit=0\n😀")
}

///|
#cfg(platform="windows")
async test "shell stops oversized output while the command is still running on Windows" {
  let result = run_shell({
    "cmd": "[Console]::Out.Write('abcdef'); Start-Sleep -Seconds 2",
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
#cfg(not(platform="windows"))
async test "shell stops oversized output while the command is still running on Unix" {
  let result = run_shell({
    "cmd": "printf %s 'abcdef'; sleep 2",
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
#cfg(platform="windows")
async test "shell does not cut multi-byte utf8 output mid-character on Windows" {
  let result = run_shell({
    "cmd": "[Console]::Out.Write('中中中'); Start-Sleep -Seconds 2",
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
#cfg(not(platform="windows"))
async test "shell does not cut multi-byte utf8 output mid-character on Unix" {
  let result = run_shell({
    "cmd": "printf %s '中中中'; sleep 2",
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
#cfg(platform="windows")
async test "shell does not split four-byte utf8 characters on Windows" {
  let result = run_shell({
    "cmd": "[Console]::Out.Write('😀😀'); Start-Sleep -Seconds 2",
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
#cfg(not(platform="windows"))
async test "shell does not split four-byte utf8 characters on Unix" {
  let result = run_shell({
    "cmd": "printf %s '😀😀'; sleep 2",
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
#cfg(platform="windows")
async test "shell reports binary output as a tool error on Windows" {
  let result = run_shell({
    "cmd": "[Console]::OpenStandardOutput().WriteByte(255)",
  })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("error running shell:"))
  assert_true(output.content.contains("Malformed"))
}

///|
#cfg(not(platform="windows"))
async test "shell reports binary output as a tool error on Unix" {
  let result = run_shell({ "cmd": "printf '\\377'" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("error running shell:"))
  assert_true(output.content.contains("Malformed"))
}

///|
#cfg(platform="windows")
async test "shell output limit wins over an unbounded producer on Windows" {
  let result = run_shell({
    "cmd": "while ($true) { [Console]::Out.Write('yyyyyyyyyy') }",
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
#cfg(not(platform="windows"))
async test "shell output limit wins over an unbounded producer on Unix" {
  let result = run_shell({
    "cmd": "while :; do printf %s 'yyyyyyyyyy'; done",
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
#cfg(platform="windows")
async test "shell merges stderr into the captured output on Windows" {
  let result = run_shell({ "cmd": "[Console]::Error.WriteLine('oops')" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_true(output.content.contains("oops"))
}

///|
#cfg(not(platform="windows"))
async test "shell merges stderr into the captured output on Unix" {
  let result = run_shell({ "cmd": "printf '%s\\n' 'oops' 1>&2" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_true(output.content.contains("oops"))
}

///|
#cfg(platform="windows")
async test "shell times out long running commands on Windows" {
  let result = run_shell({ "cmd": "Start-Sleep -Seconds 2", "timeout_ms": 50 })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_eq(output.content, "error: shell command timed out after 50ms")
}

///|
#cfg(not(platform="windows"))
async test "shell times out long running commands on Unix" {
  let result = run_shell({ "cmd": "sleep 2", "timeout_ms": 50 })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_eq(output.content, "error: shell command timed out after 50ms")
}

///|
async test "shell rejects moon check and points to moon_check" {
  let result = run_shell({ "cmd": "moon check" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("shell blocked `moon check`"))
  assert_true(output.content.contains("moon_check"))
}

///|
async test "shell rejects moon_cmd as a shell command" {
  let result = run_shell({ "cmd": "moon_cmd run cmd/main" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("moon_cmd is a tool name"))
}

///|
async test "shell rejects missing cmd" {
  let result = run_shell({ "cwd": "unused" })
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
  let dir = @fs.tmpdir(prefix="openseek-shell-cwd-")
  let dir_path : @path.Path = dir
  let path = dir_path.join("does-not-exist").normalize().to_string()
  let result = run_shell({ "cmd": "echo hello", "cwd": path })
  @fs.rmdir(dir, recursive=true)
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("cwd does not exist"))
}

///|
async test "shell rejects cwd that is a file not a directory" {
  let dir = @fs.tmpdir(prefix="openseek-shell-cwd-")
  let dir_path : @path.Path = dir
  let path = dir_path.join("file.txt").normalize().to_string()
  @fs.write_file(path, "not a directory", create_mode=CreateOrTruncate)
  let result = run_shell({ "cmd": "echo hello", "cwd": path })
  @fs.rmdir(dir, recursive=true)
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("cwd is not a directory"))
}
