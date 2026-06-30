///|
test "parse finds the subcommand past global options" {
  let argv = ["git", "-C", "pkg", "--no-pager", "checkout", "--", "main.mbt"]
  guard @git_policy.parse(argv, 1) is Some(inv) else { fail("expected Some") }
  assert_eq(inv.subcommand, "checkout")
  assert_eq(inv.subcommand_index, 4)
}

///|
test "parse fails closed" {
  assert_true(@git_policy.parse(["git", "--bogus", "checkout"], 1) is None)
  assert_true(@git_policy.parse(["git", "--help", "checkout"], 1) is None)
  assert_true(@git_policy.parse(["git", "--", "checkout"], 1) is None)
  assert_true(@git_policy.parse(["git", "-c"], 1) is None)
  assert_true(@git_policy.parse(["git"], 1) is None)
}

///|
test "object-store-write classification excludes mv and plumbing" {
  for sub in ["checkout", "switch", "restore", "reset", "stash", "rm"] {
    assert_true(@git_policy.subcommand_writes_from_object_store(sub))
  }
  for sub in ["mv", "clean", "apply", "am", "status", "checkout-index", "co"] {
    assert_false(@git_policy.subcommand_writes_from_object_store(sub))
  }
}

///|
test "store-feeder classification" {
  for sub in ["apply", "am", "update-index", "read-tree", "fast-import"] {
    assert_true(@git_policy.subcommand_is_store_feeder(sub))
  }
  for sub in ["checkout", "restore", "status", "mv"] {
    assert_false(@git_policy.subcommand_is_store_feeder(sub))
  }
}

///|
test "reconfiguring global options" {
  for
    opt in [
      "-c", "--config-env", "--git-dir", "--namespace", "--exec-path", "-C", "--work-tree",
      "-Cpkg", "--git-dir=/x", "--work-tree=/x",
    ] {
    assert_true(@git_policy.global_option_reconfigures(opt))
  }
  for opt in ["--no-pager", "-p", "--literal-pathspecs", "checkout"] {
    assert_false(@git_policy.global_option_reconfigures(opt))
  }
}

///|
test "text-path subcommand finding and feeder check" {
  let words = ["git", "-C", "pkg", "apply", "patch"]
  guard @git_policy.text_subcommand_index(words, 1, words.length()) is Some(i) else {
    fail("expected Some")
  }
  assert_eq(words[i], "apply")
  assert_true(
    @git_policy.text_subcommand_is_store_feeder(words, i, words.length()),
  )
  // A help flag on the subcommand disables the feeder block.
  let help = ["git", "apply", "--help"]
  guard @git_policy.text_subcommand_index(help, 1, help.length()) is Some(j) else {
    fail("expected Some")
  }
  assert_false(
    @git_policy.text_subcommand_is_store_feeder(help, j, help.length()),
  )
}
