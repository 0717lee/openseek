///|
test "sandbox source write profile regex covers source and manifests" {
  let regex = source_write_regex("/tmp/a.b")
  // The deny regex matches source files at any depth and no longer special-cases
  // build directories; `_build`/`.mooncakes` are re-allowed by the carve-out.
  assert_true(regex.contains("\\.mbt\\.md|\\.mbt|\\.mbti"))
  assert_false(regex.contains("_build"))
  let carveout = source_write_build_carveout_regex("/tmp/a.b")
  assert_true(carveout.contains("_build|\\.mooncakes"))
}

///|
async test "sandbox profile is cached per normalized workspace root" {
  let profile = source_write_readonly_profile_data("/workspace").profile
  let cached = source_write_readonly_profile_data("/workspace/").profile
  assert_eq(cached, profile)
  assert_true(profile.contains("(deny file-write*"))
  assert_true(profile.contains("(allow file-write* (regex"))
  assert_false(profile.contains("(deny file-write-create"))
  assert_false(profile.contains("(literal \"/workspace\")"))
}

///|
async test "sandbox profile blocks existing directories that contain source" {
  @vfs.with_tmpdir(prefix="openseek-shell-sandbox-source-tree-profile-", root => {
    @fs.mkdir("\{root}/pkg")
    @fs.mkdir("\{root}/assets")
    @fs.mkdir("\{root}/.git")
    @fs.mkdir("\{root}/_build")
    @fs.write_file(
      "\{root}/pkg/main.mbt",
      "pub fn answer() -> Int { 42 }\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{root}/assets/logo.txt",
      "not MoonBit source\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{root}/_build/generated.mbt",
      "pub fn generated() -> Int { 1 }\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{root}/.git/ignored.mbt",
      "not part of the workspace source tree\n",
      create_mode=CreateOrTruncate,
    )
    let profile = source_write_readonly_profile_data(root).profile
    assert_true(profile.contains("(deny file-write*"))
    assert_true(profile.contains("(literal \"\{root}/pkg\")"))
    assert_false(profile.contains("(literal \"\{root}/assets\")"))
    assert_false(profile.contains("(literal \"\{root}/.git\")"))
    assert_false(profile.contains("(literal \"\{root}/_build\")"))
  })
}

///|
test "source-write denial detection in command output" {
  // run_moonbit's shape: a MoonBit runtime error for a denied source write.
  assert_true(
    source_write_denied_in_text(
      "OSError(\"@fs.open(): \\\"keep.mbt\\\": Operation not permitted\")",
      [],
    ),
  )
  assert_true(
    source_write_denied_in_text("sh: main.mbt: Operation not permitted\n", []),
  )
  assert_true(
    source_write_denied_in_text("sh: moon.work: Operation not permitted\n", []),
  )
  // Generic denials and prose mentions are not source-write denials.
  assert_false(source_write_denied_in_text("Permission denied\n", []))
  assert_false(
    source_write_denied_in_text("Permission denied while reading main.mbt\n", []),
  )
  assert_false(
    source_write_denied_in_text(
      "Permission denied while reading 'main.mbt'\n",
      [],
    ),
  )
  // The subject may follow the denial (python's errno shape, plain colon).
  assert_true(
    source_write_denied_in_text(
      "PermissionError: [Errno 1] Operation not permitted: 'main.mbt'\n",
      [],
    ),
  )
  assert_true(
    source_write_denied_in_text("Operation not permitted: main.mbt\n", []),
  )
  assert_true(source_write_denied_in_text("Permission denied: main.mbt\n", []))
  // A denied directory is recognized only as a known denial subject.
  let dir_rename = "PermissionError: [Errno 1] Operation not permitted: 'pkg'\n"
  assert_false(source_write_denied_in_text(dir_rename, []))
  assert_true(source_write_denied_in_text(dir_rename, ["pkg"]))
  assert_false(
    source_write_denied_in_text("foo: Operation not permitted\n", []),
  )
  assert_false(
    source_write_denied_in_text("foo: Operation not permitted\n", ["pkg"]),
  )
  // A source path without any denial wording is not a denial either.
  assert_false(source_write_denied_in_text("compiled keep.mbt: ok", []))
}

///|
async test "sandbox profile cache invalidates when source tree changes" {
  @vfs.with_tmpdir(prefix="openseek-shell-sandbox-profile-invalidate-", root => {
    @fs.mkdir("\{root}/assets")
    @fs.write_file(
      "\{root}/assets/logo.txt",
      "not MoonBit source\n",
      create_mode=CreateOrTruncate,
    )
    let first = source_write_readonly_profile_data(root).profile
    assert_false(first.contains("(literal \"\{root}/assets\")"))
    @async.sleep(5)
    @fs.write_file(
      "\{root}/assets/main.mbt",
      "pub fn answer() -> Int { 42 }\n",
      create_mode=CreateOrTruncate,
    )
    let second = source_write_readonly_profile_data(root).profile
    assert_true(second.contains("(literal \"\{root}/assets\")"))
  })
}
