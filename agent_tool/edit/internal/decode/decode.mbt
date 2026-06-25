///|
/// Decoded arguments of the `edit` tool: replace `old_string` with
/// `new_string` in the file at `path` — every occurrence when `replace_all`,
/// otherwise exactly one. Optional line bounds restrict the search/replace
/// region to an inclusive 1-based line range.
pub struct EditInput {
  path : String
  old_string : String
  new_string : String
  replace_all : Bool
  start_line : Int?
  end_line : Int?
} derive(Debug)

///|
/// Decode `edit` tool-call arguments.
///
/// `path`, `old_string`, and `new_string` are required strings;
/// `replace_all` is an optional boolean defaulting to `false`, and
/// `start_line`/`end_line` are optional positive 1-based inclusive bounds.
/// Failures name the first offending field (e.g. `arguments.old_string`) so the
/// error fed back to the model says exactly which argument to fix.
pub fn decode(arguments : Json) -> EditInput raise {
  match arguments {
    Object(fields) => parse_fields(fields)
    _ => fail("object arguments")
  }
}

///|
fn parse_fields(fields : Map[String, Json]) -> EditInput raise {
  let path = required_string(fields, "path")
  let old_string = required_string(fields, "old_string")
  let new_string = required_string(fields, "new_string")
  let replace_all = optional_bool(fields, "replace_all", false)
  let start_line = optional_positive_int_option(fields, "start_line")
  let end_line = optional_positive_int_option(fields, "end_line")
  match (start_line, end_line) {
    (Some(start), Some(end)) if end < start =>
      fail(
        "arguments.end_line to be greater than or equal to arguments.start_line",
      )
    _ => ()
  }
  { path, old_string, new_string, replace_all, start_line, end_line }
}

///|
fn required_string(fields : Map[String, Json], name : String) -> String raise {
  match fields.get(name) {
    Some(String(value)) => value
    _ => fail("arguments.\{name}")
  }
}

///|
fn optional_bool(
  fields : Map[String, Json],
  name : String,
  default : Bool,
) -> Bool raise {
  match fields.get(name) {
    Some(True) => true
    Some(False) => false
    Some(Null) | None => default
    _ => fail("arguments.\{name} to be a boolean")
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
      if int_value.to_double() != value {
        fail("arguments.\{name} to be an integer")
      }
      if int_value <= 0 {
        fail("arguments.\{name} to be a positive integer")
      }
      Some(int_value)
    }
    Some(Null) | None => None
    _ => fail("arguments.\{name} to be an integer")
  }
}
