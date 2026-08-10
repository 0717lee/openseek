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
test "recognized porcelain excludes aliases, plumbing, and command runners" {
  for
    sub in [
      "status", "diff", "fetch", "pull", "merge", "rebase", "cherry-pick", "worktree",
    ] {
    assert_true(@git_policy.subcommand_is_recognized_porcelain(sub))
  }
  for
    sub in ["co", "checkout-index", "commit-tree", "filter-branch", "difftool"] {
    assert_false(@git_policy.subcommand_is_recognized_porcelain(sub))
  }
}

///|
test "worktree-write classification separates metadata and read commands" {
  for
    sub in [
      "checkout", "clone", "merge", "pull", "rebase", "restore", "submodule", "worktree",
    ] {
    assert_true(@git_policy.subcommand_may_write_worktree(sub))
  }
  for sub in ["add", "commit", "diff", "fetch", "push", "status", "tag"] {
    assert_false(@git_policy.subcommand_may_write_worktree(sub))
  }
}

///|
test "should_preblock: rebase command-running and reconfigured forms" {
  // Blocked: forms that execute external commands (interactive/todo editing,
  // `--exec`, a merge strategy) — including abbreviations, short clusters, and
  // attached values — plus any reconfigured rebase.
  for
    cmd in [
      ["git", "rebase", "-i", "main"],
      ["git", "rebase", "--interactive", "main"],
      ["git", "rebase", "--int", "main"],
      ["git", "rebase", "-iv", "main"],
      ["git", "rebase", "--exec", "ls", "main"],
      ["git", "rebase", "--exec=ls", "main"],
      ["git", "rebase", "--exe=ls", "main"],
      ["git", "rebase", "-x", "ls", "main"],
      ["git", "rebase", "-xls", "main"],
      ["git", "rebase", "--edit-todo"],
      ["git", "rebase", "-s", "ours", "main"],
      ["git", "rebase", "--strategy=ours", "main"],
      ["git", "rebase", "-Xtheirs", "main"],
      ["git", "rebase", "--strategy-option", "theirs", "main"],
      ["git", "-c", "sequence.editor=x", "rebase", "--continue"],
      ["git", "-C", "/tmp/x", "rebase", "--abort"],
      ["git", "--work-tree=/tmp/x", "rebase", "main"],
    ] {
    assert_true(@git_policy.should_preblock(cmd, 1))
  }
  // Not blocked: the recoverable forms (they run trusted) and the
  // merely-unrecognized forms (they run sandboxed, where the profile denies
  // any source write). `--stat`/`--empty` must not false-positive against the
  // `--strategy`/`--exec` abbreviation prefixes.
  for
    cmd in [
      ["git", "rebase", "main"],
      ["git", "rebase", "--onto", "main", "feature~3", "feature"],
      ["git", "rebase", "--continue"],
      ["git", "rebase", "--abort"],
      ["git", "rebase", "--autostash", "main"],
      ["git", "rebase", "--root"],
      ["git", "rebase", "--rebase-merges", "main"],
      ["git", "rebase", "--stat", "main"],
      ["git", "rebase", "--empty=drop", "main"],
      ["git", "rebase", "--help"],
    ] {
    assert_false(@git_policy.should_preblock(cmd, 1))
  }
}

///|
test "should_preblock: external strategies, bisect run, and worktree loss" {
  for
    cmd in [
      ["git", "merge", "-s", "evil", "main"],
      ["git", "merge", "--strategy=evil", "main"],
      ["git", "pull", "-Xtheirs"],
      ["git", "pull", "--rebase=interactive"],
      ["git", "pull", "--rebase=i"],
      ["git", "cherry-pick", "--strategy=evil", "HEAD~1"],
      ["git", "revert", "-Xtheirs", "HEAD"],
      ["git", "bisect", "run", "./test.sh"],
      ["git", "worktree", "move", "../wt", "../moved"],
      ["git", "worktree", "remove", "--force", "../wt"],
      ["git", "worktree", "remove", "--fo", "../wt"],
      ["git", "-C", "/tmp/x", "merge", "main"],
    ] {
    assert_true(@git_policy.should_preblock(cmd, 1))
  }
  for
    cmd in [
      ["git", "merge", "main"],
      ["git", "pull", "--rebase"],
      ["git", "pull", "--rebase=merges"],
      ["git", "cherry-pick", "-s", "HEAD~1"],
      ["git", "revert", "-s", "HEAD"],
      ["git", "bisect", "start", "HEAD", "HEAD~10"],
      ["git", "worktree", "add", "../wt"],
      ["git", "worktree", "list"],
      ["git", "worktree", "remove", "../wt"],
      ["git", "worktree", "remove", "--", "-f"],
    ] {
    assert_false(@git_policy.should_preblock(cmd, 1))
  }
}

///|
test "should_preblock: feeders, mv, non-dry-run clean, reconfigured writers" {
  // Blocked: mutates source but is not a recoverable object-store write.
  for
    cmd in [
      ["git", "apply", "patch"],
      ["git", "am", "mbox"],
      ["git", "update-index", "--cacheinfo", "100644,abc,main.mbt"],
      ["git", "read-tree", "HEAD"],
      ["git", "fast-import"],
      ["git", "mv", "notes.md", "main.mbt"],
      ["git", "clean", "-fd"],
      // `-e -n` is an exclude pattern, not a dry run -> still destructive.
      ["git", "clean", "-e", "-n", "-fd"],
      // read-only apply flag forced back to applying.
      ["git", "apply", "--stat", "--apply", "patch"],
      ["git", "apply", "--cached", "patch"],
      // checkout/restore that can clobber an untracked file from another tree.
      ["git", "checkout", "-f", "other"],
      ["git", "restore", "--source=HEAD~1", "--", "foo.mbt"],
      ["git", "restore", "-s", "HEAD~1", "foo.mbt"],
      ["git", "checkout", "HEAD~1", "--", "foo.mbt"],
      ["git", "checkout", "-fB", "new", "other"],
      ["git", "checkout", "HEAD~1", "--pathspec-from-file=list"],
      ["git", "checkout", "--ours", "conflict.mbt"],
      ["git", "-c", "filter.f.smudge=cmd", "checkout", "--", "."],
      ["git", "-C", "/tmp/x", "checkout", "--", "."],
      ["git", "--work-tree=/tmp/x", "restore", "main.mbt"],
    ] {
    assert_true(@git_policy.should_preblock(cmd, 1))
  }
  // Not blocked: recoverable writers, dry-run clean, read-only apply validation,
  // read-only git, reconfigured read-only git, and help.
  for
    cmd in [
      ["git", "checkout", "--", "main.mbt"],
      ["git", "checkout", "feature/foo"],
      ["git", "restore", "main.mbt"],
      ["git", "reset", "--hard"],
      ["git", "stash"],
      ["git", "rm", "main.mbt"],
      ["git", "clean", "-fdn"],
      ["git", "clean", "--dry-run"],
      ["git", "apply", "--check", "patch"],
      ["git", "apply", "--stat", "patch"],
      ["git", "status"],
      ["git", "-c", "core.pager=less", "status"],
      ["git", "checkout", "--help"],
      ["git", "clean", "--help"],
      // submodule: unforced update/deinit and read-only verbs are not
      // preblocked (update/deinit without force are recoverable writes; the
      // others fall to the sandbox, which is fine for them).
      ["git", "submodule", "update", "--init"],
      ["git", "submodule", "update", "--remote"],
      ["git", "submodule", "update", "--recursive"],
      ["git", "submodule", "--quiet", "update", "--init"],
      ["git", "submodule", "update", "--", "path"],
      ["git", "submodule", "deinit", "path"],
      ["git", "submodule", "add", "https://example.com/repo", "path"],
      ["git", "submodule", "set-url", "path", "https://example.com"],
      ["git", "submodule", "set-branch", "-b", "main", "path"],
      ["git", "submodule", "init"],
      ["git", "submodule", "status"],
      ["git", "submodule", "sync"],
      ["git", "submodule", "absorbgitdirs", "path"],
      ["git", "submodule", "--help"],
      ["git", "submodule", "foreach", "--help"],
      ["git", "submodule", "foreach", "--recursive", "--help"],
      ["git", "submodule"],
      ["git", "submodule", "--quiet"],
    ] {
    assert_false(@git_policy.should_preblock(cmd, 1))
  }
  // Blocked: submodule foreach runs arbitrary shell commands (including after
  // a leading `--quiet`, which git accepts), --help trailing a command argument
  // is part of the command, not a git help flag, forced update/deinit permanently
  // lose dirty or untracked content, and a reconfigured submodule is blocked.
  for
    cmd in [
      ["git", "submodule", "foreach", "echo", "hello"],
      ["git", "submodule", "foreach", "rm -rf /"],
      ["git", "submodule", "--quiet", "foreach", "echo", "hello"],
      ["git", "submodule", "foreach", "echo", "hi", "--help"],
      ["git", "submodule", "update", "--force"],
      ["git", "submodule", "update", "-f"],
      ["git", "submodule", "deinit", "--force", "path"],
      ["git", "submodule", "deinit", "-f", "path"],
      ["git", "-c", "filter.f.smudge=cmd", "submodule", "update", "--init"],
    ] {
    assert_true(@git_policy.should_preblock(cmd, 1))
  }
}

///|
/// The verb-level submodule classification is exercised through the public
/// preblock surface (the sandbox layer keeps its own private mirror):
/// `update`/`deinit` without force are recoverable, `foreach` and forced
/// forms are preblocked, and a `--quiet` prefix is honored.
test "submodule verbs: recoverable update/deinit, blocked foreach/force" {
  // Not preblocked: bare submodule, update/deinit without force, foreach --help.
  for
    cmd in [
      ["git", "submodule"],
      ["git", "submodule", "--quiet"],
      ["git", "submodule", "update", "--init"],
      ["git", "submodule", "--quiet", "update", "--init"],
      ["git", "submodule", "update", "--recursive"],
      ["git", "submodule", "update", "--", "path"],
      ["git", "submodule", "deinit", "path"],
      ["git", "submodule", "foreach", "--help"],
      ["git", "submodule", "foreach", "--recursive", "--help"],
    ] {
    assert_false(@git_policy.should_preblock(cmd, 1))
  }
  // Preblocked.
  for
    cmd in [
      ["git", "submodule", "foreach", "echo", "hi"],
      ["git", "submodule", "--quiet", "foreach", "echo", "hi"],
      ["git", "submodule", "foreach", "echo", "hi", "--help"],
      ["git", "submodule", "update", "--force"],
      ["git", "submodule", "update", "-f"],
      ["git", "submodule", "deinit", "--force", "path"],
      ["git", "submodule", "deinit", "-f", "path"],
    ] {
    assert_true(@git_policy.should_preblock(cmd, 1))
  }
}

///|

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
test "text_should_preblock mirrors should_preblock on a flat word list" {
  let apply = ["git", "-C", "pkg", "apply", "patch"]
  assert_true(@git_policy.text_should_preblock(apply, 1, apply.length()))
  let mv = ["git", "mv", "a", "b"]
  assert_true(@git_policy.text_should_preblock(mv, 1, mv.length()))
  let recoverable = ["git", "checkout", "--", "f"]
  assert_false(
    @git_policy.text_should_preblock(recoverable, 1, recoverable.length()),
  )
  // A help flag on the subcommand disables the block.
  let help = ["git", "apply", "--help"]
  assert_false(@git_policy.text_should_preblock(help, 1, help.length()))
  // submodule: update is not preblocked, foreach is.
  let update = ["git", "submodule", "update", "--init"]
  assert_false(@git_policy.text_should_preblock(update, 1, update.length()))
  let foreach = ["git", "submodule", "foreach", "echo", "x"]
  assert_true(@git_policy.text_should_preblock(foreach, 1, foreach.length()))
  let quiet_foreach = ["git", "submodule", "--quiet", "foreach", "echo", "x"]
  assert_true(
    @git_policy.text_should_preblock(quiet_foreach, 1, quiet_foreach.length()),
  )
  let forced = ["git", "submodule", "update", "--force"]
  assert_true(@git_policy.text_should_preblock(forced, 1, forced.length()))
}

///|
test "text path identifies worktree-writing porcelain" {
  let fetch = ["git", "fetch", "origin", "main"]
  assert_false(
    @git_policy.text_invocation_may_write_worktree(fetch, 1, fetch.length()),
  )
  let rebase = ["git", "rebase", "origin/main"]
  assert_true(
    @git_policy.text_invocation_may_write_worktree(rebase, 1, rebase.length()),
  )
  let plumbing = ["git", "checkout-index", "-a"]
  assert_false(
    @git_policy.text_invocation_may_write_worktree(
      plumbing,
      1,
      plumbing.length(),
    ),
  )
}
