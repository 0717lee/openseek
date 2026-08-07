///|
test "contains matches roots across path separators" {
  guard @pathx.Path("/ws/proj").to_absolute() is Some(posix_root) else {
    fail("test POSIX root was not absolute")
  }
  guard @pathx.Path("/ws/proj/src/a.mbt").to_absolute() is Some(posix_file) else {
    fail("test POSIX file was not absolute")
  }
  guard @pathx.Path("/ws/project/a.mbt").to_absolute() is Some(posix_sibling) else {
    fail("test POSIX sibling was not absolute")
  }
  assert_true(posix_root.contains(posix_file))
  assert_true(posix_root.contains(posix_root))
  assert_false(posix_root.contains(posix_sibling))
  guard @pathx.Path("C:\\ws\\proj").to_absolute() is Some(windows_root) else {
    fail("test Windows root was not absolute")
  }
  guard @pathx.Path("C:\\ws\\proj\\src\\a.mbt").to_absolute()
    is Some(windows_file) else {
    fail("test Windows file was not absolute")
  }
  guard @pathx.Path("C:/ws/proj/src/a.mbt").to_absolute() is Some(mixed_file) else {
    fail("test mixed-separator file was not absolute")
  }
  guard @pathx.Path("C:\\ws\\other\\a.mbt").to_absolute()
    is Some(windows_sibling) else {
    fail("test Windows sibling was not absolute")
  }
  assert_true(windows_root.contains(windows_file))
  assert_true(windows_root.contains(mixed_file))
  assert_false(windows_root.contains(windows_sibling))
  assert_true(@pathx.Relative("src").contains(Relative("src/a.mbt")))
  assert_false(@pathx.Relative("src").contains(Relative("src2/a.mbt")))
}

///|
test "Path converts complete POSIX and Windows paths to Absolute" {
  assert_true(
    @pathx.Path("/ws/src/a.mbt").to_absolute()
    is Some(Absolute("/ws/src/a.mbt")),
  )
  assert_true(
    @pathx.Path("C:/ws/src/a.mbt").to_absolute()
    is Some(Absolute("C:/ws/src/a.mbt")),
  )
  assert_true(
    @pathx.Path("C:\\ws\\src\\a.mbt").to_absolute()
    is Some(Absolute("C:\\ws\\src\\a.mbt")),
  )
  assert_true(
    @pathx.Path("\\\\server\\share\\a.mbt").to_absolute()
    is Some(Absolute("\\\\server\\share\\a.mbt")),
  )
}

///|
test "Path rejects conversion when the spelling depends on process context" {
  for path in ["", "src/a.mbt", "C:src\\a.mbt", "\\src\\a.mbt"] {
    assert_true(@pathx.Path(path).to_absolute() is None)
  }
}

///|
test "Absolute::relative_to types the one blessed conversion" {
  guard @pathx.Path("/ws").to_absolute() is Some(root) else {
    fail("test root was not absolute")
  }
  assert_true(
    @pathx.Path("/ws/src/a.mbt").to_absolute() is Some(path) &&
    path.relative_to(root~) is Some(Relative("src/a.mbt")),
  )
  assert_true(
    @pathx.Path("/ws").to_absolute() is Some(path) &&
    path.relative_to(root~) is Some(rest) &&
    rest.is_root(),
  )
  assert_true(
    @pathx.Path("/other/a.mbt").to_absolute() is Some(path) &&
    path.relative_to(root~) is None,
  )
  guard @pathx.Path("C:\\ws").to_absolute() is Some(windows_root) else {
    fail("test Windows root was not absolute")
  }
  assert_true(
    @pathx.Path("C:\\ws\\src\\a.mbt").to_absolute() is Some(path) &&
    path.relative_to(root=windows_root) == Some(Relative("src/a.mbt")),
  )
  // A trailing slash on the root reads the same as none.
  guard @pathx.Path("/ws/").to_absolute() is Some(root_with_slash) else {
    fail("test root with slash was not absolute")
  }
  assert_true(
    @pathx.Path("/ws/a.mbt").to_absolute() is Some(path) &&
    path.relative_to(root=root_with_slash) == Some(Relative("a.mbt")),
  )
}

///|
test "the root relative path is the zero-segment one" {
  assert_true(@pathx.Relative::root().is_root())
  assert_false(@pathx.Relative("src").is_root())
}

///|
test "normalize is lexical only" {
  assert_true(@pathx.Path("C:\\a\\b").normalize() == Path("C:/a/b"))
  assert_true(
    @pathx.Relative("src\\main.mbt").normalize() == Relative("src/main.mbt"),
  )
  guard @pathx.Path("C:\\a\\b").to_absolute() is Some(absolute) else {
    fail("test path was not absolute")
  }
  assert_true(absolute.normalize() is Absolute("C:/a/b"))
}

///|
test "host operations stay distinct from separator normalization" {
  assert_eq(@pathx.Path("a/./b/../c").normalize().0, "a/./b/../c")
  assert_eq(@pathx.Path("a/./b/../c").clean().0, "a/c")
  assert_eq(@pathx.Path("a").join(Path("b")).0, "a/b")
  assert_eq(@pathx.Path("a/b.txt").dirname().0, "a")
  assert_eq(@pathx.Path("a/b.txt").basename().to_owned(), "b.txt")
  assert_eq(@pathx.Path("a/b.txt").extname().to_owned(), ".txt")
}
