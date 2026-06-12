///|
/// Characters of file content one `read` call returns when the model does not
/// pick a `max_output_chars` budget itself.
pub let default_max_output_chars : Int = 12000

///|
/// Ceiling a caller-supplied `max_output_chars` is clamped to, so a single
/// tool call can never flood the conversation with an arbitrarily large file.
pub let hard_max_output_chars : Int = 50000

///|
/// Decoded arguments of the `read` tool: one or more files (`paths` holds a
/// single element for a `path` call), starting from the 1-based `start_line`,
/// at most `max_lines` lines (unbounded when `None`), truncated to
/// `max_output_chars` characters across the whole call. Line-range options
/// only combine with a single file.
pub struct ReadInput {
  paths : Array[String]
  start_line : Int
  max_lines : Int?
  max_output_chars : Int
} derive(Debug)

///|
/// Decode `read` tool-call arguments.
///
/// Exactly one of `path` (string) or `paths` (non-empty string array) is
/// required; the numeric fields must be positive when present and otherwise
/// default (`start_line` 1, `max_lines` unbounded, `max_output_chars`
/// `default_max_output_chars` clamped to `hard_max_output_chars`).
/// `start_line`/`max_lines` are single-file affairs and are rejected for a
/// multi-file call. Failures name the offending field so the error fed back
/// to the model says exactly which argument to fix.
pub fn decode(arguments : Json) -> ReadInput raise {
  match arguments {
    Object(fields) => parse_fields(fields)
    _ => fail("object arguments")
  }
}

///|
fn parse_fields(fields : Map[String, Json]) -> ReadInput raise {
  let single = optional_string(fields, "path")
  let multi = optional_path_array(fields, "paths")
  let paths = match (single, multi) {
    (Some(path), None) => [path]
    (None, Some(paths)) => paths
    (Some(_), Some(_)) =>
      fail("arguments.path or arguments.paths, not both at once")
    (None, None) => fail("arguments.path or arguments.paths")
  }
  let start_line = optional_positive_int(fields, "start_line", 1)
  let max_lines = optional_positive_int_option(fields, "max_lines")
  if paths.length() > 1 && (start_line != 1 || max_lines is Some(_)) {
    fail(
      "arguments.start_line and arguments.max_lines to be combined with a single file only",
    )
  }
  let max_output_chars = optional_positive_int(
    fields, "max_output_chars", default_max_output_chars,
  )
  {
    paths,
    start_line,
    max_lines,
    max_output_chars: cap_max_output_chars(max_output_chars),
  }
}

///|
fn optional_string(fields : Map[String, Json], name : String) -> String? raise {
  match fields.get(name) {
    Some(String(value)) if value != "" => Some(value)
    Some(String(_)) => fail("arguments.\{name} to be a non-empty string")
    Some(Null) | None => None
    _ => fail("arguments.\{name} to be a string")
  }
}

///|
fn optional_path_array(
  fields : Map[String, Json],
  name : String,
) -> Array[String]? raise {
  match fields.get(name) {
    Some(Array(items)) => {
      guard items.length() > 0 else {
        fail("arguments.\{name} to be a non-empty array")
      }
      let paths : Array[String] = []
      for item in items {
        guard item is String(value) && value != "" else {
          fail("arguments.\{name} to be an array of non-empty path strings")
        }
        paths.push(value)
      }
      Some(paths)
    }
    Some(Null) | None => None
    _ => fail("arguments.\{name} to be an array of paths")
  }
}

///|
fn optional_positive_int(
  fields : Map[String, Json],
  name : String,
  default : Int,
) -> Int raise {
  match fields.get(name) {
    Some(Number(value, ..)) => {
      let int_value = value.to_int()
      if int_value <= 0 {
        fail("arguments.\{name} to be a positive number")
      }
      int_value
    }
    Some(Null) | None => default
    _ => fail("arguments.\{name} to be a number")
  }
}

///|
fn optional_positive_int_option(
  fields : Map[String, Json],
  name : String,
) -> Int? raise {
  match fields.get(name) {
    Some(Number(value, ..)) => {
      let int_value = value.to_int()
      if int_value <= 0 {
        fail("arguments.\{name} to be a positive number")
      }
      Some(int_value)
    }
    Some(Null) | None => None
    _ => fail("arguments.\{name} to be a number")
  }
}

///|
fn cap_max_output_chars(value : Int) -> Int {
  if value > hard_max_output_chars {
    hard_max_output_chars
  } else {
    value
  }
}
