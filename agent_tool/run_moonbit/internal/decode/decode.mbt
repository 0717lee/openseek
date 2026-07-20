///|
/// Decoded arguments of the `run_moonbit` tool: a self-contained MoonBit
/// program to compile and run in an ephemeral, isolated package.
pub struct RunMoonbitInput {
  source : String
} derive(Debug)

///|
/// Decode `run_moonbit` tool-call arguments. `source` is a required string
/// holding a full top-level MoonBit program (including its own `main`).
/// The failure names `arguments.source` so the model knows which field to fix.
pub fn decode(arguments : Json) -> RunMoonbitInput raise {
  match arguments {
    { "source": String(source), .. } => { source, }
    Object(_) => fail("arguments.source")
    _ => fail("object arguments")
  }
}

///|
test "decode reads source" {
  let input = decode({ "source": "fn main { println(1) }" })
  assert_eq(input.source, "fn main { println(1) }")
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
