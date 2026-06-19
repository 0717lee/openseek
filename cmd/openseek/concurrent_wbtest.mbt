///|
test "one_line_brief collapses newlines and caps length" {
  assert_eq(one_line_brief("a\nb", 10), "a b")
  assert_eq(one_line_brief("  spaced  ", 10), "spaced")
  assert_eq(one_line_brief("hello world", 5), "hello…")
}

///|
test "copy_skip drops build/vendor/session dirs but keeps git and sources" {
  assert_true(copy_skip("_build"))
  assert_true(copy_skip("node_modules"))
  assert_true(copy_skip(".openseek"))
  assert_false(copy_skip(".git"))
  assert_false(copy_skip("src"))
}

///|
test "terminal_summary reads the last terminal" {
  let finished = @agent_session.Session(SessionId("t"), system_prompt="")
    .append(User(UserMessage("hi")))
    .append(Terminal(Finished("done")))
  let (status, detail) = terminal_summary(finished)
  assert_eq(status, "finished")
  assert_eq(detail, "done")
  let none = @agent_session.Session(SessionId("e"), system_prompt="")
  let (no_status, _) = terminal_summary(none)
  assert_eq(no_status, "(no terminal)")
}

///|
async test "resolve_run_dirs names siblings and reports a copy source" {
  let root = @fs.tmpdir(prefix="openseek-fleet-resolve-")
  @fs.mkdir("\{root}/proj", recursive=true)
  // Existing dir → a source to copy, with sibling _run_N names.
  let (dirs, source) = resolve_run_dirs("\{root}/proj", 2)
  assert_eq(dirs.length(), 2)
  assert_true(dirs[0].has_suffix("proj_run_1"))
  assert_true(dirs[1].has_suffix("proj_run_2"))
  guard source is Some(_) else {
    fail("expected a copy source for an existing dir")
  }
  // Absent dir (parent exists) → no source (build-from-scratch).
  let (ghost_dirs, ghost_source) = resolve_run_dirs("\{root}/ghost", 1)
  assert_true(ghost_dirs[0].has_suffix("ghost_run_1"))
  guard ghost_source is None else {
    fail("expected no source for an absent dir")
  }
  @fs.rmdir(root, recursive=true)
}

///|
async test "resolve_run_dirs rejects an existing run directory" {
  let root = @fs.tmpdir(prefix="openseek-fleet-collide-")
  @fs.mkdir("\{root}/proj", recursive=true)
  @fs.mkdir("\{root}/proj_run_1", recursive=true)
  let mut raised = false
  let _ = resolve_run_dirs("\{root}/proj", 2) catch {
    _ => {
      raised = true
      ([], None)
    }
  }
  assert_true(raised)
  @fs.rmdir(root, recursive=true)
}

///|
async test "copy_tree copies files and .git but skips build/vendor dirs" {
  let root = @fs.tmpdir(prefix="openseek-fleet-copy-")
  let src = "\{root}/s"
  @fs.mkdir("\{src}/sub", recursive=true)
  @fs.mkdir("\{src}/_build", recursive=true)
  @fs.mkdir("\{src}/.git", recursive=true)
  @fs.write_file("\{src}/a.txt", "hi", create_mode=CreateOrTruncate)
  @fs.write_file("\{src}/sub/b.txt", "yo", create_mode=CreateOrTruncate)
  @fs.write_file("\{src}/_build/junk", "x", create_mode=CreateOrTruncate)
  @fs.write_file("\{src}/.git/config", "g", create_mode=CreateOrTruncate)
  let dst = "\{root}/d"
  copy_tree(src, dst)
  assert_eq(@fs.read_file("\{dst}/a.txt").text(), "hi")
  assert_true(@fs.exists("\{dst}/sub/b.txt"))
  assert_true(@fs.exists("\{dst}/.git/config")) // hidden kept
  assert_false(@fs.exists("\{dst}/_build")) // build skipped
  @fs.rmdir(root, recursive=true)
}
