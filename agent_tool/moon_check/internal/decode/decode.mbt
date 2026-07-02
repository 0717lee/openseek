///|
/// Decoded arguments of the `moon_check` tool: where to run the persistent
/// `moon check` watcher (`cwd`), which backend to check (`target`), and the
/// pass-through diagnostics switches (`warn_list`, `deny_warn`, `fmt`,
/// `explain`).
pub struct MoonCheckInput {
  cwd : String?
  target : String?
  warn_list : String?
  deny_warn : Bool
  fmt : Bool
  explain : Bool
} derive(Debug)

///|
/// Decode `moon_check` tool-call arguments.
///
/// Every field is optional: strings default to absent, booleans to `false`.
/// A present `target` must be one of moon's backends (`wasm`, `wasm-gc`,
/// `js`, `native`, `llvm`, `all`). Failures name the offending field so the
/// error fed back to the model says exactly which argument to fix.
pub fn decode(arguments : Json) -> MoonCheckInput raise {
  match arguments {
    Object(fields) => parse_fields(fields)
    _ => fail("object arguments")
  }
}

///|
fn parse_fields(fields : Map[String, Json]) -> MoonCheckInput raise {
  let cwd = @decode_common.optional_string(fields, "cwd")
  let target = @decode_common.optional_string(fields, "target")
  if target is Some(value) {
    @moon_target.validate_target(value)
  }
  let warn_list = @decode_common.optional_string(fields, "warn_list")
  {
    cwd,
    target,
    warn_list,
    deny_warn: @decode_common.optional_bool(fields, "deny_warn", false),
    fmt: @decode_common.optional_bool(fields, "fmt", false),
    explain: @decode_common.optional_bool(fields, "explain", false),
  }
}
