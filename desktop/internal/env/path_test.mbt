///|
test "a bin dir is prepended to the path, and stands alone when there is none" {
  assert_eq(
    @env.prepend_to_path_env("/toolchain/bin", None),
    "/toolchain/bin",
  )
  assert_eq(
    @env.prepend_to_path_env("/toolchain/bin", Some("")),
    "/toolchain/bin",
  )
  assert_eq(
    @env.prepend_to_path_env("/toolchain/bin", Some("/usr/bin")),
    "/toolchain/bin\{@env.PathSep}/usr/bin",
  )
}

///|
/// Windows environment blocks commonly spell the key `Path`; the child gets
/// exactly one path variable, under the spelling that was already there.
test "prepending updates the existing spelling and drops duplicate keys" {
  let env = { "Path": "/usr/bin" }
  assert_eq(
    @env.prepend_path_entry(env, "/toolchain/bin"),
    "/toolchain/bin\{@env.PathSep}/usr/bin",
  )
  assert_eq(env.get("Path"), Some("/toolchain/bin\{@env.PathSep}/usr/bin"))
  assert_eq(env.get("PATH"), None)
  assert_eq(env.length(), 1)
}

///|
test "an empty block gains an uppercase PATH" {
  let env : Map[String, String] = Map([])
  assert_eq(@env.prepend_path_entry(env, "/toolchain/bin"), "/toolchain/bin")
  assert_eq(env.get("PATH"), Some("/toolchain/bin"))
}
