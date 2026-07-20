///|
async fn run(source : String) -> @agent_tool.ToolOutput {
  let action = match @run_moonbit.definition().execute {
    Async(execute) => execute({ "source": source })
    Sync(_) => fail("run_moonbit should be async")
  }
  guard action is Respond(output) else { fail("expected Respond") }
  output
}

///|
async test "runs a pure-core program and returns its output" {
  let out = run("fn main { println(6 * 7) }")
  assert_false(out.is_error)
  assert_true(out.content.contains("42"))
}

///|
async test "surfaces a compile error via moon's own diagnostics" {
  let out = run("fn main { let _x : Int = \"nope\" }")
  assert_true(out.is_error)
  assert_true(
    out.content.to_lower().contains("type") || out.content.contains("String"),
  )
}

///|
async test "reads a file through an inline import block" {
  @vfs.with_tmpdir(dir => {
    @fs.write_file(
      "\{dir}/note.txt",
      "one\ntwo\n",
      create_mode=CreateOrTruncate,
    )
    let out = run(
      (
        #|import { "moonbitlang/async", "moonbitlang/async/fs", "moonbitlang/async/stdio" }
        #|
        #|async fn main {
        #|  let text = @fs.read_file("$P").text()
        #|  @stdio.stdout.write("lines=\{[..text.split("\n")].filter(l => !l.is_empty()).length()}\n")
        #|}
      ).replace_all(old="$P", new="\{dir}/note.txt"),
    )
    assert_false(out.is_error)
    assert_true(out.content.contains("lines=2"))
  })
}

///|
async test "rejects non-string source arguments" {
  let action = match @run_moonbit.definition().execute {
    Async(execute) => execute({ "code": "x" })
    Sync(_) => fail("run_moonbit should be async")
  }
  guard action is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  assert_true(output.content.contains("run_moonbit requires"))
}

///|
async test "runs a pure snippet on a non-native target" {
  let action = match @run_moonbit.definition().execute {
    Async(execute) =>
      execute({ "source": "fn main { println(6 * 7) }", "target": "js" })
    Sync(_) => fail("run_moonbit should be async")
  }
  guard action is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_true(output.content.contains("42"))
}

///|
async test "error diagnostics name `source`, not the throwaway temp path" {
  let out = run("fn main {\n  let _x : Int = \"nope\"\n}")
  assert_true(out.is_error)
  // the model reads a path about its own input, not /tmp/openseek-run-moonbit-*
  assert_true(out.content.contains("source:"))
  assert_false(out.content.contains("openseek-run-moonbit-"))
  assert_false(out.content.contains("_build/snippet.mbt"))
}

///|
async test "refuses a program that spawns processes (shell owns commands)" {
  let out = run(
    (
      #|import { "moonbitlang/async", "moonbitlang/async/process" }
      #|
      #|async fn main { @process.run("ls", []) |> ignore }
    ),
  )
  assert_true(out.is_error)
  assert_true(out.content.contains("spawns processes"))
}

///|
async test "refuses native FFI (extern can bind libc system)" {
  // `extern` sidesteps the @process import check, so it is refused too — the
  // static boundary is best-effort until the wasm sandbox lands.
  let out = run(
    (
      #|extern "c" fn c_system(cmd : Bytes) -> Int = "system"
      #|
      #|fn main { c_system("true") |> ignore }
    ),
  )
  assert_true(out.is_error)
  assert_true(out.content.contains("native FFI"))
}

///|
async test "snippet stdin is an empty file (EOF), not the engine's inherited fd 0" {
  // A snippet that reads stdin must get immediate EOF, not block on (or steal
  // from) the parent's fd 0 — which under serve/TUI is the control channel.
  let out = run(
    (
      #|import { "moonbitlang/async", "moonbitlang/async/stdio" }
      #|
      #|async fn main {
      #|  let line = @stdio.stdin.read_until("\n")
      #|  @stdio.stdout.write("got=\{line is Some(_)}\n")
      #|}
    ),
  )
  assert_false(out.is_error)
  assert_true(out.content.contains("got=false"))
}

///|
async test "a non-zero exit shows the exit code in the content, not just the brief" {
  // prints, then aborts: the model must see the failure in what it reads
  let out = run("fn main { println(\"before\"); panic() }")
  assert_true(out.is_error)
  assert_true(out.content.contains("before"))
  assert_true(out.content.contains("exited"))
}
