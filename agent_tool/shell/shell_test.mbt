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
  @vfs.with_tmpdir(prefix="openseek-shell-cwd-", dir => {
    let result = run_shell({ "cmd": "echo cwd-ok > marker.txt", "cwd": dir })
    let dir_path : @path.Path = dir
    let marker_path = dir_path.join("marker.txt").normalize().to_string()
    let marker = @fs.read_file(marker_path).text() catch { _ => "" }
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_true(output.content.contains("exit=0"))
    assert_eq(marker.trim(), "cwd-ok")
  })
}

///|
async test "shell uses the workspace root when cwd is omitted" {
  @vfs.with_tmpdir(prefix="openseek-shell-workspace-", dir => {
    let result = run_shell_in_workspace(dir, {
      "cmd": "echo root-ok > marker.txt",
    })
    let marker = @fs.read_file("\{dir}/marker.txt").text() catch { _ => "" }
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_true(output.content.contains("exit=0"))
    assert_eq(marker.trim(), "root-ok")
  })
}

///|
async test "shell reads a virtual filesystem fixture from cwd" {
  @vfs.with_tmpdir(prefix="openseek-shell-vfs-", project => {
    @vfs.FileSystem({
      "data/input.txt": (
        #|shell-vfs
        #|
      ),
    }).write_to(project)
    let result = run_shell({ "cmd": "cat data/input.txt", "cwd": project })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    inspect(
      output.content.trim(),
      content=(
        #|shell-vfs
        #|<system>exit=0</system>
      ),
    )
  })
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
  assert_eq(output.content, "abc\n<system>exit=0</system>")
}

///|
#cfg(not(platform="windows"))
async test "shell leaves output at exact limit as a normal result on Unix" {
  let result = run_shell({ "cmd": "printf %s 'abc'", "max_output_chars": 3 })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_eq(output.content, "abc\n<system>exit=0</system>")
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
  assert_eq(output.content, "中中\n<system>exit=0</system>")
}

///|
#cfg(not(platform="windows"))
async test "shell counts output limits in characters for non-ascii text on Unix" {
  let result = run_shell({ "cmd": "printf %s '中中'", "max_output_chars": 2 })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_eq(output.content, "中中\n<system>exit=0</system>")
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
  assert_eq(output.content, "😀\n<system>exit=0</system>")
}

///|
#cfg(not(platform="windows"))
async test "shell leaves four-byte utf8 output at exact character limit on Unix" {
  let result = run_shell({ "cmd": "printf %s '😀'", "max_output_chars": 1 })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_eq(output.content, "😀\n<system>exit=0</system>")
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
    output.content =~ re"^abc\n<system>exit=cancelled truncated=true output_limit_reached=true shown_chars=3 max_output_chars=3</system>$",
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
    output.content =~ re"^abc\n<system>exit=cancelled truncated=true output_limit_reached=true shown_chars=3 max_output_chars=3</system>$",
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
    output.content =~ re"^中中\n<system>exit=cancelled truncated=true output_limit_reached=true shown_chars=2 max_output_chars=2</system>$",
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
    output.content =~ re"^中中\n<system>exit=cancelled truncated=true output_limit_reached=true shown_chars=2 max_output_chars=2</system>$",
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
    output.content =~ re"^😀\n<system>exit=cancelled truncated=true output_limit_reached=true shown_chars=1 max_output_chars=1</system>$",
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
    output.content =~ re"^😀\n<system>exit=cancelled truncated=true output_limit_reached=true shown_chars=1 max_output_chars=1</system>$",
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
    output.content =~ re"^yyyyy\n<system>exit=cancelled truncated=true output_limit_reached=true shown_chars=5 max_output_chars=5</system>$",
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
    output.content =~ re"^yyyyy\n<system>exit=cancelled truncated=true output_limit_reached=true shown_chars=5 max_output_chars=5</system>$",
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
async test "shell rejects moon_cmd as a shell command" {
  // `moon check` now runs through shell (no redirect); the only remaining guard
  // is the bare `moon_cmd` tool name, blocked before execution. We do not
  // exercise `moon check` here: the shell tool would run a nested `moon` under
  // `moon test` and deadlock on the build lock.
  let result = run_shell({ "cmd": "moon_cmd run cmd/main" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("moon_cmd is not a shell command"))
}

///|
async test "shell rejects sed -i in-place editing" {
  // Blocked by policy before execution, so no file is touched; the model is
  // redirected to the edit tool.
  let result = run_shell({ "cmd": "sed -i 's/old/new/' main.mbt" })
  guard result is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("sed -i"))
  assert_true(output.content.contains("edit"))
}

///|
#cfg(not(platform="windows"))
async test "shell appends moon check after applied moon ide rename" {
  @vfs.with_tmpdir(prefix="openseek-shell-auto-check-", dir => {
    @fs.write_file(
      "\{dir}/moon.mod",
      "name = \"tmp/shell_auto_check\"\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{dir}/moon.pkg",
      "warnings = \"+unnecessary_annotation\"\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{dir}/main.mbt",
      (
        #|pub fn old_name() -> Int { missing_symbol }
        #|
        #|pub fn call() -> Int { old_name() }
        #|
      ),
      create_mode=CreateOrTruncate,
    )
    let result = run_shell({
      "cmd": "moon ide rename old_name new_name --loc main.mbt:1:8 --apply",
      "cwd": dir,
    })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_true(output.content.contains("<system>exit=0</system>"))
    assert_true(output.content.contains("Applied 2 edit(s)"))
    assert_true(output.content.contains("\nmoon check:\nexit="))
    assert_true(output.content.contains("missing_symbol"))
    // The `<system>` footer stays the last line even with the moon check block
    // inserted before it.
    assert_true(output.content.has_suffix("<system>exit=0</system>"))
    let renamed = @fs.read_file("\{dir}/main.mbt").text()
    assert_true(renamed.contains("new_name"))
    assert_false(renamed.contains("old_name"))
  })
}

///|
async test "shell does not append moon check for non-mutating moon shapes" {
  @vfs.with_tmpdir(prefix="openseek-shell-no-auto-check-", dir => {
    @fs.write_file(
      "\{dir}/moon.mod",
      "name = \"tmp/shell_no_auto_check\"\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{dir}/moon.pkg",
      "warnings = \"+unnecessary_annotation\"\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{dir}/main.mbt",
      (
        #|pub fn broken() -> Int { missing_symbol }
        #|
      ),
      create_mode=CreateOrTruncate,
    )
    for cmd in ["echo moon add", "true || moon fmt", "moon fmt --check"] {
      let result = run_shell({ "cmd": cmd, "cwd": dir })
      guard result is Respond(output) else { fail("expected Respond") }
      assert_false(output.content.contains("moon check:"))
    }
    let timed = run_shell({ "cmd": "moon fmt", "cwd": dir, "timeout_ms": 30000 })
    guard timed is Respond(output) else { fail("expected Respond") }
    assert_false(output.is_error)
    assert_false(output.content.contains("moon check:"))
  })
}

///|
#cfg(not(platform="windows"))
async test "shell appends moon check from moon command target cwd" {
  @vfs.with_tmpdir(prefix="openseek-shell-auto-check-c-option-", dir => {
    let project = "\{dir}/project"
    @fs.mkdir(project)
    @fs.write_file(
      "\{project}/moon.mod",
      "name = \"tmp/shell_auto_check_c_option\"\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{project}/moon.pkg",
      "warnings = \"+unnecessary_annotation\"\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{project}/main.mbt",
      (
        #|pub fn broken() -> Int { missing_symbol }
        #|
      ),
      create_mode=CreateOrTruncate,
    )
    for
      cmd in [
        "moon -C project fmt", "moon -Cproject fmt", "moon -C=project fmt", "cd ./project && moon fmt",
      ] {
      let result = run_shell({ "cmd": cmd, "cwd": dir })
      guard result is Respond(output) else { fail("expected Respond") }
      assert_false(output.is_error)
      assert_true(output.content.contains("<system>exit=0</system>"))
      assert_true(output.content.contains("\nmoon check:\nexit="))
      assert_true(output.content.contains("missing_symbol"))
    }
  })
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
  @vfs.with_tmpdir(prefix="openseek-shell-cwd-", dir => {
    let dir_path : @path.Path = dir
    let path = dir_path.join("does-not-exist").normalize().to_string()
    let result = run_shell({ "cmd": "echo hello", "cwd": path })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("cwd does not exist"))
  })
}

///|
async test "shell rejects cwd that is a file not a directory" {
  @vfs.with_tmpdir(prefix="openseek-shell-cwd-", dir => {
    let dir_path : @path.Path = dir
    let path = dir_path.join("file.txt").normalize().to_string()
    @fs.write_file(path, "not a directory", create_mode=CreateOrTruncate)
    let result = run_shell({ "cmd": "echo hello", "cwd": path })
    guard result is Respond(output) else { fail("expected Respond") }
    assert_true(output.is_error)
    assert_true(output.content.contains("cwd is not a directory"))
  })
}
