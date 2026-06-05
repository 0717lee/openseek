///|
async test "manifest error allows ordinary files" {
  assert_true(write_error("notes.json", "{}") is None)
}

///|
async test "manifest error rejects new moon.mod.json" {
  let dir = @fs.tmpdir(prefix="openseek-edit-manifest-error-")
  let path = dir + "/moon.mod.json"
  let error = write_error(path, "{}")
  @fs.rmdir(dir, recursive=true)
  guard error is Some(message) else { fail("expected manifest error") }
  assert_true(message.contains("moon.mod.json is legacy"))
}

///|
async test "manifest error allows existing moon.mod.json" {
  let dir = @fs.tmpdir(prefix="openseek-edit-manifest-error-")
  let path = dir + "/moon.mod.json"
  @fs.write_file(path, "{}", create_mode=CreateOrTruncate)
  let error = write_error(path, "{}")
  @fs.rmdir(dir, recursive=true)
  assert_true(error is None)
}

///|
async test "manifest error rejects invalid moon.mod content" {
  guard write_error("moon.mod", "") is Some(empty) else {
    fail("expected empty moon.mod error")
  }
  assert_eq(empty, "moon.mod must not be empty")
  guard write_error("moon.mod", "{\"name\":\"demo\"}") is Some(json) else {
    fail("expected JSON moon.mod error")
  }
  assert_eq(json, "moon.mod uses current text syntax, not JSON")
  guard write_error("moon.mod", "version = \"0.1.0\"") is Some(missing_name) else {
    fail("expected missing name moon.mod error")
  }
  assert_eq(missing_name, "moon.mod should include a module `name = ...` entry")
}

///|
async test "manifest error rejects invalid moon.pkg content" {
  guard write_error("moon.pkg", "x") is Some(tiny) else {
    fail("expected tiny moon.pkg error")
  }
  assert_eq(tiny, "moon.pkg content is suspiciously small")
  guard write_error("moon.pkg", "{\"import\":[]}") is Some(json) else {
    fail("expected JSON moon.pkg error")
  }
  assert_eq(json, "moon.pkg uses current text syntax, not JSON")
}
