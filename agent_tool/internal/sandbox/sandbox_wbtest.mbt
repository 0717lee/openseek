///|
test "sandbox source write regex covers moonbit source and manifests" {
  let regex = source_write_regex("/tmp/a.b")
  // The deny regex matches source files at any depth and no longer special-cases
  // build directories; `_build`/`.mooncakes` are re-allowed by the carve-out.
  assert_true(regex.contains("\\.mbt\\.md|\\.mbt|\\.mbti"))
  assert_false(regex.contains("_build"))
  let carveout = source_write_build_carveout_regex("/tmp/a.b")
  assert_true(carveout.contains("_build|\\.mooncakes"))
  assert_true(
    is_protected_workspace_source_path("/workspace", "/workspace/moon.mod"),
  )
  assert_true(
    is_protected_workspace_source_path("/workspace", "/workspace/pkg/moon.pkg"),
  )
  assert_true(
    is_protected_workspace_source_path("/workspace", "/workspace/pkg/main.mbt"),
  )
  assert_true(
    is_protected_workspace_source_path(
      "/workspace", "/workspace/pkg/_build.mbt",
    ),
  )
  assert_true(
    is_protected_workspace_source_path(
      "/workspace", "/workspace/.mooncakes.mbt",
    ),
  )
  assert_false(
    is_protected_workspace_source_path(
      "/workspace", "/workspace/backup-moon.mod",
    ),
  )
  assert_false(
    is_protected_workspace_source_path(
      "/workspace", "/workspace/_build/wasm-gc/release/format/main.mbt",
    ),
  )
  assert_false(
    is_protected_workspace_source_path(
      "/workspace", "/workspace/.mooncakes/moonbitlang/core/main.mbt",
    ),
  )
  assert_false(
    is_protected_workspace_source_path(
      "/workspace", "/workspace/pkg/_build/main.mbt",
    ),
  )
  assert_false(
    is_protected_workspace_source_path(
      "/workspace", "/workspace/scripts/.mooncakes/pkg/main.mbt",
    ),
  )
  assert_true(is_under_workspace_root("C:\\repo", "C:\\repo\\main.mbt"))
  assert_true(
    is_protected_workspace_source_path("C:\\repo", "C:\\repo\\main.mbt"),
  )
  assert_true(
    is_protected_workspace_source_path("C:\\repo", "C:\\repo\\pkg\\moon.pkg"),
  )
  assert_false(
    is_protected_workspace_source_path("C:\\repo", "C:\\repo\\_build\\main.mbt"),
  )
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
