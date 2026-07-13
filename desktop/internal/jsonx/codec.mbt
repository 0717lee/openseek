// Shared building blocks for hand-written JSON codecs. They keep field paths
// precise and make the distinction between a missing optional field and a
// malformed present field explicit.

///|
/// Raise a JSON decoding failure at `path` with the supplied message.
pub fn[T] decode_error(
  path : @json.JsonPath,
  message : String,
) -> T raise @json.JsonDecodeError {
  raise JsonDecodeError((path, message))
}

///|
/// Decode `json` as an object, reporting a type error at `path` otherwise.
pub fn expect_object(
  json : Json,
  path : @json.JsonPath,
) -> Map[String, Json] raise @json.JsonDecodeError {
  guard json is Object(fields) else {
    return decode_error(path, "expected object")
  }
  fields
}

///|
/// Build a JSON object from key/value pairs.
pub fn object(fields : Array[(String, Json)]) -> Json {
  Json::object(Map::from_array(fields))
}

///|
/// Encode `value` under `key` when it is present, omitting the field otherwise.
pub fn[T : ToJson] put_optional(
  fields : Map[String, Json],
  key : String,
  value : T?,
) -> Unit {
  if value is Some(value) {
    fields[key] = value.to_json()
  }
}

///|
/// Decode the required field `key` as `T`. A missing field fails at the field's
/// own path; a present field delegates decoding at that same path.
pub fn[T : FromJson] required(
  fields : Map[String, Json],
  path : @json.JsonPath,
  key : String,
) -> T raise @json.JsonDecodeError {
  let field_path = path.add_key(key)
  guard fields.get(key) is Some(value) else {
    return decode_error(field_path, "expected field")
  }
  @json.from_json(value, path=field_path)
}

///|
/// Decode `key` as an optional field. Only absence becomes `None`; JSON `null`
/// and values that do not decode as `T` remain errors at the field path.
pub fn[T : FromJson] optional(
  fields : Map[String, Json],
  path : @json.JsonPath,
  key : String,
) -> T? raise @json.JsonDecodeError {
  guard fields.get(key) is Some(value) else { return None }
  Some(@json.from_json(value, path=path.add_key(key)))
}

///|
/// Read the required string field `key`, failing at its field path when absent
/// or not a JSON string.
pub fn required_string(
  fields : Map[String, Json],
  path : @json.JsonPath,
  key : String,
) -> String raise @json.JsonDecodeError {
  guard fields.get(key) is Some(String(value)) else {
    return decode_error(path.add_key(key), "expected string")
  }
  value
}

///|
/// Read the required boolean field `key`, failing at its field path when
/// absent or not a JSON boolean.
pub fn required_bool(
  fields : Map[String, Json],
  path : @json.JsonPath,
  key : String,
) -> Bool raise @json.JsonDecodeError {
  match fields.get(key) {
    Some(True) => true
    Some(False) => false
    _ => decode_error(path.add_key(key), "expected bool")
  }
}

///|
/// Decode the array field `key` row by row, skipping rows that fail to decode.
/// A missing or non-array field still fails at the field's own path.
pub fn[T : FromJson] tolerant_rows(
  fields : Map[String, Json],
  path : @json.JsonPath,
  key : String,
) -> Array[T] raise @json.JsonDecodeError {
  let field_path = path.add_key(key)
  guard fields.get(key) is Some(Array(values)) else {
    return decode_error(field_path, "expected array")
  }
  let rows : Array[T] = []
  for index, value in values {
    let row : T = @json.from_json(value, path=field_path.add_index(index)) catch {
      _ => continue
    }
    rows.push(row)
  }
  rows
}
