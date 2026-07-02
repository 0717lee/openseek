///|
/// Characters of captured command output one `shell` call returns when the
/// model does not pick a `max_output_chars` budget itself.
pub let default_max_output_chars : Int = 12000

///|
/// Ceiling a caller-supplied `max_output_chars` is clamped to, so a single
/// command's output can never flood the conversation.
pub let hard_max_output_chars : Int = 50000

///|
/// Decoded arguments of the `shell` tool: run `cmd` through the platform
/// shell, in `cwd` when given, killed after `timeout_ms` when given, with
/// captured output truncated to `max_output_chars` characters.
pub struct ShellInput {
  cmd : String
  cwd : String?
  timeout_ms : Int?
  max_output_chars : Int
} derive(Debug)

///|
/// Decode `shell` tool-call arguments.
///
/// Only `cmd` is required (and must be non-empty). `cwd` defaults to the
/// process working directory, `timeout_ms` to no timeout, and
/// `max_output_chars` to `default_max_output_chars`, clamped to
/// `hard_max_output_chars`. Failures name the offending field so the error
/// fed back to the model says exactly which argument to fix.
pub fn decode(arguments : Json) -> ShellInput raise {
  match arguments {
    Object(fields) => parse_fields(fields)
    _ => fail("object arguments")
  }
}

///|
fn parse_fields(fields : Map[String, Json]) -> ShellInput raise {
  let cmd = @decode_common.required_nonempty_string(fields, "cmd")
  let cwd = @decode_common.optional_string(fields, "cwd")
  let timeout_ms = @decode_common.optional_positive_number_option(
    fields, "timeout_ms",
  )
  let max_output_chars = @decode_common.optional_positive_number(
    fields, "max_output_chars", default_max_output_chars,
  )
  {
    cmd,
    cwd,
    timeout_ms,
    max_output_chars: @decode_common.cap_output_chars(
      max_output_chars, hard_max_output_chars,
    ),
  }
}
