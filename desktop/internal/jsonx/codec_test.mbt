///|
struct OptionalString {
  value : String?
} derive(Debug, Eq)

///|
impl FromJson for OptionalString with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { value: @jsonx.optional(fields, path, "value") }
}

///|
struct RequiredFields {
  n : Int
  text : String
  flag : Bool
} derive(Debug, Eq)

///|
impl FromJson for RequiredFields with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    n: @jsonx.required(fields, path, "n"),
    text: @jsonx.required_string(fields, path, "text"),
    flag: @jsonx.required_bool(fields, path, "flag"),
  }
}

///|
struct IntRows {
  rows : Array[Int]
} derive(Debug, Eq)

///|
impl FromJson for IntRows with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { rows: @jsonx.tolerant_rows(fields, path, "rows") }
}

///|
fn[T : FromJson] assert_decode_error(
  json : Json,
  type_witness : T?,
  expected_path : String,
  expected_message : String,
) -> Unit raise {
  ignore(type_witness)
  try {
    let value : T = @json.from_json(json)
    ignore(value)
  } catch {
    JsonDecodeError((path, message)) => {
      assert_eq(path.to_string(), expected_path)
      assert_eq(message, expected_message)
    }
  } noraise {
    _ => fail("expected JSON decoding to fail")
  }
}

///|
test "decoding helpers report the precise failing path" {
  assert_decode_error([], (None : OptionalString?), "", "expected object")
  assert_decode_error(
    Json::empty_object(),
    (None : RequiredFields?),
    "/n",
    "expected field",
  )
  assert_decode_error(
    { "n": 1 },
    (None : RequiredFields?),
    "/text",
    "expected string",
  )
  assert_decode_error(
    { "n": 1, "text": "ok", "flag": null },
    (None : RequiredFields?),
    "/flag",
    "expected bool",
  )
}

///|
test "optional distinguishes absence from malformed present values" {
  let missing : OptionalString = @json.from_json(Json::empty_object())
  assert_true(missing.value is None)
  let present : OptionalString = @json.from_json({ "value": "ok" })
  assert_true(present.value is Some("ok"))
  assert_decode_error(
    { "value": null },
    (None : OptionalString?),
    "/value",
    "String::from_json: expected string",
  )
  assert_decode_error(
    { "value": 1 },
    (None : OptionalString?),
    "/value",
    "String::from_json: expected string",
  )
}

///|
test "object and put_optional omit absent fields" {
  let fields : Map[String, Json] = Map([])
  @jsonx.put_optional(fields, "present", Some("value"))
  @jsonx.put_optional(fields, "missing", (None : String?))
  assert_true(fields.get("present") is Some(String("value")))
  assert_true(fields.get("missing") is None)
  assert_eq(
    @jsonx.object([("present", "value")]),
    ({ "present": "value" } : Json),
  )
}

///|
test "typed accessors preserve strict and tolerant policies" {
  let decoded : RequiredFields = @json.from_json({
    "n": 42,
    "text": "value",
    "flag": false,
  })
  assert_eq(decoded, { n: 42, text: "value", flag: false })
  let fields = fields_of({ "n": 42, "bad_n": "42" })
  assert_true(@jsonx.json_int(fields, "n") is Some(42))
  assert_true(@jsonx.json_int(fields, "bad_n") is None)
  assert_true(@jsonx.json_int(fields, "missing") is None)
}

///|
test "tolerant_rows skips bad rows but requires an array field" {
  let decoded : IntRows = @json.from_json({ "rows": [1, "bad", 2, null] })
  assert_eq(decoded.rows, [1, 2])
  assert_decode_error(
    { "rows": Json::empty_object() },
    (None : IntRows?),
    "/rows",
    "expected array",
  )
  assert_decode_error(
    Json::empty_object(),
    (None : IntRows?),
    "/rows",
    "expected array",
  )
}
