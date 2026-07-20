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
