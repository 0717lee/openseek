///|
fn[T : FromJson] test_reply(text : String) -> T? {
  let json = @json.parse(text) catch { _ => return None }
  let reply : T = @json.from_json(json) catch { _ => return None }
  Some(reply)
}

///|
test "workspace hints preserve trimming and omission" {
  assert_true(workspace_hint(None) is None)
  assert_true(workspace_hint(Some(Absolute("   "))) is None)
  assert_eq(
    workspace_hint(Some(Absolute("  /ws/project  "))),
    Some("/ws/project"),
  )
}

///|
test "child_path joins entry names onto their parent directory" {
  assert_eq(child_path(@pathx.Relative::root(), "src").0, "src")
  assert_eq(child_path(@pathx.Relative::root(), "moon.mod").0, "moon.mod")
  assert_eq(child_path(Relative("src"), "main.mbt").0, "src/main.mbt")
  assert_eq(child_path(Relative("src/lib"), "util.mbt").0, "src/lib/util.mbt")
}

///|
test "language_id maps known extensions and falls back to plain text" {
  assert_eq(language_id("main.mbt"), "moonbit")
  assert_eq(language_id("pkg.generated.mbti"), "moonbit")
  assert_eq(language_id("README.mbt.md"), "moonbit")
  assert_eq(language_id("bundle.js"), "javascript")
  assert_eq(language_id("config.mjs"), "javascript")
  assert_eq(language_id("moon.mod.json"), "json")
  assert_eq(language_id("notes.txt"), "plaintext")
  assert_eq(language_id("LICENSE"), "plaintext")
}

///|
test "decode_dir_entries builds full relative paths and skips bad rows" {
  let text =
    #|{"entries":[{"name":"src","is_dir":true},{"name":"moon.mod","is_dir":false},{"is_dir":true}]}
  let reply : @protocol.ReadDirReply = test_reply(text).unwrap()
  let entries = decode_dir_entries(reply, @pathx.Relative::root())
  // The third row has no name and is dropped.
  assert_eq(entries.length(), 2)
  assert_eq(entries[0].name, "src")
  assert_eq(entries[0].path.0, "src")
  assert_true(entries[0].is_dir)
  assert_eq(entries[1].name, "moon.mod")
  assert_eq(entries[1].path.0, "moon.mod")
  assert_false(entries[1].is_dir)
}

///|
test "decode_dir_entries roots child paths at the parent directory" {
  let text =
    #|{"entries":[{"name":"util.mbt","is_dir":false}]}
  let reply : @protocol.ReadDirReply = test_reply(text).unwrap()
  let entries = decode_dir_entries(reply, Relative("src/lib"))
  assert_eq(entries[0].path.0, "src/lib/util.mbt")
}

///|
test "decode_dir_entries rejects structurally unusable replies" {
  let invalid_json : @protocol.ReadDirReply? = test_reply("not json")
  let invalid_entries : @protocol.ReadDirReply? = test_reply("{\"entries\":42}")
  assert_true(invalid_json is None)
  assert_true(invalid_entries is None)
}

///|
test "decode_file_index parses paths, truncation, and rejects garbage" {
  let text =
    #|{"files":["moon.mod","src/lib.mbt",42,""],"truncated":true}
  let reply : @protocol.ListFilesReply = test_reply(text).unwrap()
  let (files, truncated) = decode_file_index(reply)
  // The non-string and empty rows are dropped.
  assert_eq(files.length(), 2)
  assert_eq(files[0].0, "moon.mod")
  assert_eq(files[1].0, "src/lib.mbt")
  assert_true(truncated)
  let empty : @protocol.ListFilesReply = test_reply("{\"files\":[]}").unwrap()
  assert_true(decode_file_index(empty).0.is_empty())
  assert_false(decode_file_index(empty).1)
  let invalid_json : @protocol.ListFilesReply? = test_reply("not json")
  let invalid_files : @protocol.ListFilesReply? = test_reply("{\"files\":42}")
  assert_true(invalid_json is None)
  assert_true(invalid_files is None)
}

///|
test "decode_file_content decodes each reply kind" {
  let content : @protocol.ReadFileReply = test_reply(
    "{\"kind\":\"content\",\"content\":\"hello\",\"absolute\":\"/ws/a.mbt\",\"sig\":\"12:34\"}",
  ).unwrap()
  assert_true(
    decode_file_content(content)
    is Content(content="hello", absolute=Absolute("/ws/a.mbt"), sig="12:34"),
  )
  let binary : @protocol.ReadFileReply = test_reply("{\"kind\":\"binary\"}").unwrap()
  assert_true(decode_file_content(binary) is Binary)
  let oversized : @protocol.ReadFileReply = test_reply(
    "{\"kind\":\"oversized\"}",
  ).unwrap()
  assert_true(decode_file_content(oversized) is Oversized)
  // The shared decoder rejects a content reply missing any required field,
  // just as the old feature-local decoder did.
  let missing_absolute : @protocol.ReadFileReply? = test_reply(
    "{\"kind\":\"content\",\"content\":\"x\",\"sig\":\"1:2\"}",
  )
  let missing_sig : @protocol.ReadFileReply? = test_reply(
    "{\"kind\":\"content\",\"content\":\"x\",\"absolute\":\"/ws/a.mbt\"}",
  )
  let unknown : @protocol.ReadFileReply? = test_reply("{\"truncated\":true}")
  let garbage : @protocol.ReadFileReply? = test_reply("garbage")
  assert_true(missing_absolute is None)
  assert_true(missing_sig is None)
  assert_true(unknown is None)
  assert_true(garbage is None)
}

///|
test "decode_file_stats maps shared rows and keeps missing-file signatures" {
  let text =
    #|{"stats":[{"path":"src/main.mbt","sig":"12:34"},{"path":"gone.mbt","sig":""},{"path":"bad.mbt"},{"sig":"1:2"}]}
  let reply : @protocol.StatFilesReply = test_reply(text).unwrap()
  let stats = decode_file_stats(reply)
  assert_eq(stats.length(), 2)
  assert_eq(stats[0].path.0, "src/main.mbt")
  assert_eq(stats[0].sig, "12:34")
  assert_eq(stats[1].path.0, "gone.mbt")
  assert_eq(stats[1].sig, "")
}
