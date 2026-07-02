///|
/// Shared JSON argument-decoder helpers for the per-tool `internal/decode`
/// packages. Every helper fails with a message naming the offending field so
/// the error fed back to the model says exactly which argument to fix. The
/// exact failure-message bytes are load-bearing: the tool layer surfaces them
/// verbatim, so changing them changes what the model sees.

///|
/// Read an optional string field. An empty string, `null`, or an absent field
/// all decode to `None`; any other non-string JSON value is an error.
pub fn optional_string(
  fields : Map[String, Json],
  name : String,
) -> String? raise {
  match fields.get(name) {
    Some(String(value)) if value != "" => Some(value)
    Some(String(_)) | Some(Null) | None => None
    _ => fail("arguments.\{name} to be a string")
  }
}

///|
/// Read a required, non-empty string field. An empty string, `null`, or an
/// absent field fails with just the field path; a non-string value fails with
/// a type message.
pub fn required_nonempty_string(
  fields : Map[String, Json],
  name : String,
) -> String raise {
  match fields.get(name) {
    Some(String(value)) if value != "" => value
    Some(String(_)) | Some(Null) | None => fail("arguments.\{name}")
    _ => fail("arguments.\{name} to be a string")
  }
}

///|
/// Read an optional boolean field, substituting `default` when the field is
/// `null` or absent.
pub fn optional_bool(
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
/// Read a JSON number as a positive 1-based integer, failing when it is
/// fractional or non-positive. `prefix` names the enclosing argument path
/// (e.g. `arguments` or `arguments.edits[0]`) in failure messages.
pub fn positive_int_of_number(
  value : Double,
  name : String,
  prefix : String,
) -> Int raise {
  let int_value = value.to_int()
  if int_value.to_double() != value {
    fail("\{prefix}.\{name} to be an integer")
  }
  if int_value <= 0 {
    fail("\{prefix}.\{name} to be a positive integer")
  }
  int_value
}

///|
/// Read an optional field as a positive integer (rejecting fractional
/// values), decoding `null`/absent to `None`. Failure messages say
/// "integer" and are prefixed with `prefix`.
pub fn optional_positive_int_option(
  fields : Map[String, Json],
  name : String,
  prefix : String,
) -> Int? raise {
  match fields.get(name) {
    Some(Number(value, ..)) => Some(positive_int_of_number(value, name, prefix))
    Some(Null) | None => None
    _ => fail("\{prefix}.\{name} to be an integer")
  }
}

///|
/// Read an optional field as a positive number truncated to `Int` (no
/// fractional check), decoding `null`/absent to `None`. Failure messages say
/// "number" and are rooted at `arguments`.
pub fn optional_positive_number_option(
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
/// Like `optional_positive_number_option`, but substituting `default` when
/// the field is `null` or absent.
pub fn optional_positive_number(
  fields : Map[String, Json],
  name : String,
  default : Int,
) -> Int raise {
  optional_positive_number_option(fields, name).unwrap_or(default)
}

///|
/// Clamp an output-budget value to a hard `cap`.
pub fn cap_output_chars(value : Int, cap : Int) -> Int {
  if value > cap {
    cap
  } else {
    value
  }
}
