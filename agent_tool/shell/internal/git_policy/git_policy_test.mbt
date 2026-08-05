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
  // rebase is deliberately absent: its recoverable forms are gated by args
  // (`rebase_args_are_recoverable`), never trusted by name alone.
  for
    sub in [
      "mv", "clean", "apply", "am", "status", "checkout-index", "co", "rebase",
    ] {
    assert_false(@git_policy.subcommand_writes_from_object_store(sub))
  }
  // The custom-environment pre-blocks treat rebase as an object-store writer:
  // repointed via GIT_DIR/GIT_CONFIG_* it could write source from another repo.
  assert_true(@git_policy.subcommand_is_object_store_writer("rebase"))
  assert_true(@git_policy.subcommand_is_object_store_writer("checkout"))
  assert_false(@git_policy.subcommand_is_object_store_writer("apply"))
  assert_false(@git_policy.subcommand_is_object_store_writer("clean"))
}

///|
test "rebase args: plain and in-progress forms recoverable, rest fails closed" {
  fn recoverable(args : Array[String]) -> Bool {
    @git_policy.rebase_args_are_recoverable(args, 0, args.length())
  }

  fn preblocked(args : Array[String]) -> Bool {
    let cmd = ["git", "rebase"] + args
    @git_policy.should_preblock(cmd, 1)
  }

  // Plain rebases and the in-progress verbs: replayed content comes from the
  // object store and the pre-rebase tip stays in ORIG_HEAD/the reflog. Every
  // admitted form must also stay clear of the pre-block (allowlist ∩
  // pre-block = ∅), or a trusted form would be refused at launch.
  for
    args in (
      [
        [],
        ["main"],
        ["origin/main", "feature"],
        ["-"],
        ["--onto", "main", "feature~3", "feature"],
        ["--onto=main", "feature"],
        ["--keep-base", "main"],
        ["--fork-point", "main"],
        ["--no-fork-point", "main"],
        ["--autostash", "main"],
        ["--no-autostash", "main"],
        ["--continue"],
        ["--abort"],
        ["--skip"],
        ["--quit"],
      ] : Array[Array[String]]) {
    assert_true(recoverable(args))
    assert_false(preblocked(args))
  }
  // The one deliberate divergence: an option-looking `--onto` value is
  // admitted (mirroring git's consume-next parsing; git then fails to resolve
  // it as a committish), while the pre-block scans the same raw token and
  // refuses the command first — the pre-block runs before the trust mode at
  // launch, so nothing executes.
  assert_true(recoverable(["--onto", "-i", "main"]))
  assert_true(preblocked(["--onto", "-i", "main"]))
  // Allowlist polarity: anything not an exact known-safe token fails closed —
  // rebase's surface includes command runners, and git accepts unambiguous
  // long-option abbreviations, so `--cont` is as untrusted as `--exec`.
  assert_false(recoverable(["-i", "main"]))
  assert_false(recoverable(["--interactive", "main"]))
  assert_false(recoverable(["--exec", "ls", "main"]))
  assert_false(recoverable(["-x", "ls", "main"]))
  assert_false(recoverable(["--edit-todo"]))
  assert_false(recoverable(["--strategy=ours", "main"]))
  assert_false(recoverable(["--root"]))
  assert_false(recoverable(["--rebase-merges", "main"]))
  assert_false(recoverable(["--stat", "main"]))
  assert_false(recoverable(["--cont"]))
  assert_false(recoverable(["--onto"]))
  assert_false(recoverable(["--", "main"]))
}

///|
test "should_preblock: rebase command-running and reconfigured forms" {
  // Blocked: forms that execute external commands (interactive/todo editing,
  // `--exec`, a merge strategy, gpg signing) — including abbreviations, short
  // clusters, and attached values — plus any reconfigured rebase.
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
      ["git", "rebase", "-S", "main"],
      ["git", "rebase", "-Skey", "main"],
      ["git", "rebase", "--gpg-sign", "main"],
      ["git", "rebase", "--gpg-sign=key", "main"],
      ["git", "rebase", "--gpg-s", "main"],
      ["git", "-c", "sequence.editor=x", "rebase", "--continue"],
      ["git", "-C", "/tmp/x", "rebase", "--abort"],
      ["git", "--work-tree=/tmp/x", "rebase", "main"],
    ] {
    assert_true(@git_policy.should_preblock(cmd, 1))
  }
  // Not blocked: the recoverable forms (they run trusted) and the
  // merely-unrecognized forms (they run sandboxed, where the profile denies
  // any source write). `--stat`/`--empty` must not false-positive against the
  // `--strategy`/`--exec` abbreviation prefixes, and `--no-gpg-sign` disables
  // signing rather than requesting it.
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
      ["git", "rebase", "--no-gpg-sign", "main"],
      ["git", "rebase", "--help"],
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
    ] {
    assert_false(@git_policy.should_preblock(cmd, 1))
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
}

///|
test "worktree args: add and prune recoverable, remove only without force" {
  fn recoverable(args : Array[String]) -> Bool {
    @git_policy.worktree_args_are_recoverable(args, 0, args.length())
  }

  // `add` in any form: git itself refuses an existing non-empty target, force
  // included, so nothing existing can be clobbered.
  assert_true(recoverable(["add", "../wt"]))
  assert_true(recoverable(["add", "--force", "../wt"]))
  assert_true(recoverable(["add", "-b", "feat", "../wt", "HEAD"]))
  assert_true(recoverable(["add", "--detach", "../wt"]))
  // `remove` without force deletes only tracked, clean content.
  assert_true(recoverable(["remove", "../wt"]))
  assert_true(recoverable(["remove", "--", "../wt"]))
  assert_true(recoverable(["prune"]))
  assert_true(recoverable(["prune", "-n", "--expire", "1.day"]))
  // Force remove permanently deletes modified or untracked files. Any option
  // fails closed: git accepts unambiguous long-option abbreviations, so
  // `--fo`/`--for` force the removal too.
  assert_false(recoverable(["remove", "--force", "../wt"]))
  assert_false(recoverable(["remove", "-f", "../wt"]))
  assert_false(recoverable(["remove", "-ff", "../wt"]))
  assert_false(recoverable(["remove", "--fo", "../wt"]))
  assert_false(recoverable(["remove", "--quiet", "../wt"]))
  // After `--` every word is a path: a worktree named `-f` is a plain,
  // non-force removal.
  assert_true(recoverable(["remove", "--", "-f"]))
  // Everything else fails closed, including a missing verb.
  assert_false(recoverable(["list"]))
  assert_false(recoverable(["lock", "../wt"]))
  assert_false(recoverable(["move", "../wt", "../wt2"]))
  assert_false(recoverable(["repair"]))
  assert_false(recoverable([]))
}
