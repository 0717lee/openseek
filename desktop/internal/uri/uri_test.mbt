///|
test "path encoding keeps separators and escapes the rest" {
  assert_eq(@uri.encode_path("/a/b.mbt"), "/a/b.mbt")
  assert_eq(@uri.encode_path("/a b/c#d.mbt"), "/a%20b/c%23d.mbt")
  assert_eq(@uri.encode_path("/tmp/中文"), "/tmp/%E4%B8%AD%E6%96%87")
  assert_eq(@uri.encode_path("100%.mbt"), "100%25.mbt")
}

///|
test "component encoding escapes separators too" {
  assert_eq(@uri.encode_component("/ws/proj"), "%2Fws%2Fproj")
  assert_eq(@uri.encode_component("a=b&c"), "a%3Db%26c")
  assert_eq(@uri.encode_component("plain-id_1.2~x"), "plain-id_1.2~x")
}

///|
test "decode reverses both encoders" {
  for text in ["/a b/c#d.mbt", "/tmp/中文", "100%.mbt", "a=b&c?d"] {
    assert_eq(@uri.decode(@uri.encode_path(text)), text)
    assert_eq(@uri.decode(@uri.encode_component(text)), text)
  }
}

///|
test "decode leaves malformed escapes literal" {
  assert_eq(@uri.decode("a%2"), "a%2")
  assert_eq(@uri.decode("a%zz"), "a%zz")
  assert_eq(@uri.decode("a%"), "a%")
}

///|
test "file uris encode reserved and non-ascii path bytes" {
  guard @pathx.Path("/a/b.mbt").to_absolute() is Some(plain) else {
    fail("test plain path was not absolute")
  }
  assert_eq(@uri.file_uri(plain), "file:///a/b.mbt")
  guard @pathx.Path("/a b/c#d.mbt").to_absolute() is Some(reserved) else {
    fail("test reserved-character path was not absolute")
  }
  assert_eq(@uri.file_uri(reserved), "file:///a%20b/c%23d.mbt")
  guard @pathx.Path("/tmp/中文").to_absolute() is Some(non_ascii) else {
    fail("test non-ASCII path was not absolute")
  }
  assert_eq(@uri.file_uri(non_ascii), "file:///tmp/%E4%B8%AD%E6%96%87")
}

///|
test "file uris give windows drive paths an authority slash" {
  guard @pathx.Path("C:\\Users\\dev\\proj\\a.mbt").to_absolute()
    is Some(absolute) else {
    fail("test Windows path was not absolute")
  }
  assert_eq(@uri.file_uri(absolute), "file:///C:/Users/dev/proj/a.mbt")
}

///|
test "file uri paths round-trip through encode and decode" {
  for path in ["/a/b.mbt", "/a b/c#d.mbt", "/tmp/中文", "/x/100%.mbt"] {
    guard @pathx.Path(path).to_absolute() is Some(absolute) else {
      fail("test path was not absolute")
    }
    assert_true(@uri.file_uri_path(@uri.file_uri(absolute)) == Path(path))
  }
  guard @pathx.Path("C:\\Users\\dev\\a.mbt").to_absolute() is Some(windows_path) else {
    fail("test Windows path was not absolute")
  }
  assert_true(
    @uri.file_uri_path(@uri.file_uri(windows_path)) ==
    Path("C:/Users/dev/a.mbt"),
  )
}

///|
test "file uri path decode tolerates other schemes" {
  assert_true(@uri.file_uri_path("untitled:one") == Path("untitled:one"))
}
