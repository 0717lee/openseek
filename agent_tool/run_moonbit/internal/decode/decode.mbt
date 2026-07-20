///|
/// Decoded arguments of the `run_moonbit` tool: a self-contained MoonBit
/// program (`.mbtx` single-file script) to compile and run, plus the backend
/// `target` to run it on.
pub struct RunMoonbitInput {
  source : String
  target : String
} derive(Debug)

///|
/// The moon backends `--target` accepts. `native` is the default because the
/// async IO batteries (`@fs`, `@stdio`, `@process`) require it.
fn valid_target(target : String) -> Bool {
  target is ("native" | "wasm" | "wasm-gc" | "js" | "llvm")
}

///|
/// Decode `run_moonbit` tool-call arguments. `source` is a required string
/// holding a full `.mbtx` program (an optional leading `import { … }` block,
/// then the program including its own `main`). `target` is an optional backend
/// name defaulting to `native`. Failures name the offending field.
pub fn decode(arguments : Json) -> RunMoonbitInput raise {
  match arguments {
    { "source": String(source), .. } => {
      let target = match arguments {
        { "target": String(t), .. } => t
        { "target": Null, .. } => "native"
        { "target": _, .. } => fail("arguments.target to be a string")
        _ => "native"
      }
      guard valid_target(target) else {
        fail("arguments.target to be one of native, wasm, wasm-gc, js, llvm")
      }
      { source, target }
    }
    Object(_) => fail("arguments.source")
    _ => fail("object arguments")
  }
}

///|
test "decode reads source with the default native target" {
  let input = decode({ "source": "fn main { println(1) }" })
  assert_eq(input.source, "fn main { println(1) }")
  assert_eq(input.target, "native")
}

///|
test "decode accepts an explicit target" {
  let input = decode({ "source": "fn main {  }", "target": "wasm-gc" })
  assert_eq(input.target, "wasm-gc")
}

///|
test "decode rejects an unknown target" {
  let failed = try {
    decode({ "source": "x", "target": "banana" }) |> ignore
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "decode rejects a missing source" {
  let failed = try {
    decode({ "code": "x" }) |> ignore
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "decode rejects non-object arguments" {
  let failed = try {
    decode(Json::string("x")) |> ignore
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}
