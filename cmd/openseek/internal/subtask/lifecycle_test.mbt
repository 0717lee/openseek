///|
/// Full-lifecycle tests against REAL git repositories: provision a worktree,
/// play the worker's part with plain filesystem edits, capture, integrate —
/// and every refusal edge the state machine promises. These are the
/// controller's ground-truth tests; the parent tool wires what they prove.
async fn seed_repo(dir : String) -> String {
  let repo = "\{dir}/repo"
  @fs.mkdir(repo)
  for
    args in [
      ["init", "-q"],
      ["config", "user.email", "e2e@test"],
      ["config", "user.name", "e2e"],
    ] {
    match @subtask.git_require(args, cwd=repo) {
      Ok(_) => ()
      Err(reason) => fail(reason)
    }
  }
  @fs.mkdir("\{repo}/lib")
  @fs.mkdir("\{repo}/other")
  @vfs.write_text("\{repo}/lib", "a.txt", "alpha\n")
  @vfs.write_text("\{repo}/other", "b.txt", "beta\n")
  for args in [["add", "-A"], ["commit", "-q", "-m", "base"]] {
    match @subtask.git_require(args, cwd=repo) {
      Ok(_) => ()
      Err(reason) => fail(reason)
    }
  }
  repo
}

///|
async fn must_provision(
  repo : String,
  name~ : String,
  allowed_paths~ : Array[String],
  nonce~ : String,
) -> @subtask.Provisioned {
  match @subtask.provision(repo, name~, allowed_paths~, nonce~) {
    Ok(provisioned) => provisioned
    Err(reason) => fail("provision failed: \{reason}")
  }
}

///|
async test "provision, worker edit, capture, integrate — the happy path" {
  @vfs.with_tmpdir(prefix="openseek-subtask-happy-", dir => {
    let repo = seed_repo(dir)
    let provisioned = must_provision(
      repo,
      name="fix-lib",
      allowed_paths=["lib"],
      nonce="n1",
    )
    let entry = provisioned.entry
    assert_true(entry.state is Running)
    assert_true(@fs.exists("\{entry.worker_root}/lib/a.txt"))
    // The worker's part: an in-scope edit.
    @vfs.write_text("\{entry.worker_root}/lib", "a.txt", "ALPHA\n")
    let captured = @subtask.capture(provisioned.geometry, entry)
    assert_eq(captured.defects, ([] : Array[String]))
    assert_true(captured.entry.state is Committed)
    guard captured.entry.commit_oid is Some(_) else {
      fail("expected a commit oid")
    }
    let integrated = @subtask.integrate(provisioned.geometry, captured.entry)
    assert_eq(integrated.result, "integrated")
    // The change landed in origin history and the worktree is gone.
    assert_eq(@fs.read_file("\{repo}/lib/a.txt").text(), "ALPHA\n")
    assert_false(@fs.exists(entry.worker_root))
    // The registry records the terminal state.
    let (entries, skipped) = @subtask.load_entries(
      provisioned.geometry.common_git_dir,
    )
    assert_eq(skipped, ([] : Array[String]))
    assert_eq(entries.length(), 1)
    assert_true(entries[0].state is Integrated)
  })
}

///|
async test "out-of-scope worker changes are captured as defects, not merged" {
  @vfs.with_tmpdir(prefix="openseek-subtask-scope-", dir => {
    let repo = seed_repo(dir)
    let provisioned = must_provision(
      repo,
      name="fix-lib",
      allowed_paths=["lib"],
      nonce="n1",
    )
    let entry = provisioned.entry
    @vfs.write_text("\{entry.worker_root}/lib", "a.txt", "ALPHA\n")
    @vfs.write_text("\{entry.worker_root}/other", "b.txt", "INTRUDED\n")
    let captured = @subtask.capture(provisioned.geometry, entry)
    assert_true(captured.defects.length() > 0)
    assert_true(captured.defects[0].contains("other/b.txt"))
    assert_true(captured.entry.state is Captured)
    // Nothing was committed; integration refuses.
    let refused = @subtask.integrate(provisioned.geometry, captured.entry)
    assert_eq(refused.result, "refused")
    // Origin untouched either way.
    assert_eq(@fs.read_file("\{repo}/other/b.txt").text(), "beta\n")
  })
}

///|
async test "overlapping reservations and duplicate names refuse at provision" {
  @vfs.with_tmpdir(prefix="openseek-subtask-overlap-", dir => {
    let repo = seed_repo(dir)
    let _ = must_provision(
      repo,
      name="first",
      allowed_paths=["lib"],
      nonce="n1",
    )
    guard @subtask.provision(
        repo,
        name="second",
        allowed_paths=["lib/deep"],
        nonce="n2",
      )
      is Err(overlap) else {
      fail("expected an overlap refusal")
    }
    assert_true(overlap.contains("overlap"))
    guard @subtask.provision(
        repo,
        name="first",
        allowed_paths=["other"],
        nonce="n3",
      )
      is Err(duplicate) else {
      fail("expected a duplicate-name refusal")
    }
    assert_true(duplicate.contains("already active"))
    // A DISJOINT slice provisions fine alongside.
    let _ = must_provision(
      repo,
      name="third",
      allowed_paths=["other"],
      nonce="n4",
    )
  })
}

///|
async test "an empty worker tree resolves to no_changes and releases the slice" {
  @vfs.with_tmpdir(prefix="openseek-subtask-empty-", dir => {
    let repo = seed_repo(dir)
    let provisioned = must_provision(
      repo,
      name="noop",
      allowed_paths=["lib"],
      nonce="n1",
    )
    let captured = @subtask.capture(provisioned.geometry, provisioned.entry)
    assert_true(captured.entry.state is NoChanges)
    assert_eq(captured.defects, ([] : Array[String]))
    // Cleanup is immediate (terminal entries are undiscoverable), so the
    // SAME name and slice provision again — with a natural trailing-slash
    // spelling, which normalization must accept.
    let again = must_provision(
      repo,
      name="noop",
      allowed_paths=["lib/"],
      nonce="n2",
    )
    assert_eq(again.entry.allowed_paths, ["lib"])
  })
}

///|
async test "a conflicting merge hands off, continues after resolution" {
  @vfs.with_tmpdir(prefix="openseek-subtask-conflict-", dir => {
    let repo = seed_repo(dir)
    let provisioned = must_provision(
      repo,
      name="fix-lib",
      allowed_paths=["lib"],
      nonce="n1",
    )
    let entry = provisioned.entry
    // Worker changes the file...
    @vfs.write_text("\{entry.worker_root}/lib", "a.txt", "WORKER\n")
    let captured = @subtask.capture(provisioned.geometry, entry)
    assert_true(captured.entry.state is Committed)
    // ...and the origin advances the SAME line before integration.
    @vfs.write_text("\{repo}/lib", "a.txt", "ORIGIN\n")
    for args in [["add", "-A"], ["commit", "-q", "-m", "origin moved"]] {
      match @subtask.git_require(args, cwd=repo) {
        Ok(_) => ()
        Err(reason) => fail(reason)
      }
    }
    let conflicted = @subtask.integrate(provisioned.geometry, captured.entry)
    assert_eq(conflicted.result, "conflicted")
    assert_true(conflicted.entry.state is Conflicted)
    assert_true(conflicted.detail[0].contains("lib/a.txt"))
    // Resolve the markers (the parent model's job, via file tools) and
    // stage the resolution — then the controller commits. A stray staged
    // file outside the slice + conflict set refuses the continue first.
    @vfs.write_text("\{repo}/lib", "a.txt", "MERGED\n")
    @vfs.write_text("\{repo}/other", "stray.txt", "stray\n")
    for args in [["add", "lib/a.txt"], ["add", "other/stray.txt"]] {
      match @subtask.git_require(args, cwd=repo) {
        Ok(_) => ()
        Err(reason) => fail(reason)
      }
    }
    let strayed = @subtask.integrate_continue(
      provisioned.geometry,
      conflicted.entry,
    )
    assert_eq(strayed.result, "refused")
    assert_true(strayed.detail[0].contains("other/stray.txt"))
    match
      @subtask.git_require(
        ["restore", "--staged", "--worktree", "other/stray.txt"],
        cwd=repo,
      ) {
      Ok(_) => ()
      Err(reason) => fail(reason)
    }
    let continued = @subtask.integrate_continue(
      provisioned.geometry,
      conflicted.entry,
    )
    assert_eq(continued.result, "integrated")
    assert_eq(@fs.read_file("\{repo}/lib/a.txt").text(), "MERGED\n")
    assert_false(@fs.exists(entry.worker_root))
  })
}

///|
async test "integrate refuses a dirty tracked origin; abort restores state" {
  @vfs.with_tmpdir(prefix="openseek-subtask-dirty-", dir => {
    let repo = seed_repo(dir)
    let provisioned = must_provision(
      repo,
      name="fix-lib",
      allowed_paths=["lib"],
      nonce="n1",
    )
    @vfs.write_text("\{provisioned.entry.worker_root}/lib", "a.txt", "WORKER\n")
    let captured = @subtask.capture(provisioned.geometry, provisioned.entry)
    // Dirty the origin's tracked file.
    @vfs.write_text("\{repo}/other", "b.txt", "dirty\n")
    let refused = @subtask.integrate(provisioned.geometry, captured.entry)
    assert_eq(refused.result, "refused")
    assert_true(refused.detail[0].contains("uncommitted tracked changes"))
    // Clean it; force a conflict; then abort restores the pre-merge state.
    @vfs.write_text("\{repo}/other", "b.txt", "beta\n")
    @vfs.write_text("\{repo}/lib", "a.txt", "ORIGIN\n")
    for args in [["add", "-A"], ["commit", "-q", "-m", "origin moved"]] {
      match @subtask.git_require(args, cwd=repo) {
        Ok(_) => ()
        Err(reason) => fail(reason)
      }
    }
    let conflicted = @subtask.integrate(provisioned.geometry, captured.entry)
    assert_eq(conflicted.result, "conflicted")
    let aborted = @subtask.integrate_abort(
      provisioned.geometry,
      conflicted.entry,
    )
    assert_eq(aborted.result, "aborted")
    assert_true(aborted.entry.state is Committed)
    assert_eq(@fs.read_file("\{repo}/lib/a.txt").text(), "ORIGIN\n")
    // The branch and worktree survive an abort for a later retry.
    assert_true(@fs.exists(provisioned.entry.worker_root))
    // Discard releases everything.
    match @subtask.discard(provisioned.geometry, aborted.entry) {
      Ok(_) => ()
      Err(reason) => fail(reason)
    }
    assert_false(@fs.exists(provisioned.entry.worker_root))
    let retry = must_provision(
      repo,
      name="fix-lib",
      allowed_paths=["lib"],
      nonce="n9",
    )
    assert_true(retry.entry.state is Running)
  })
}

///|
async test "provision refuses linked-worktree origins and submodule slices" {
  @vfs.with_tmpdir(prefix="openseek-subtask-precond-", dir => {
    let repo = seed_repo(dir)
    // A linked worktree cannot be the origin.
    match
      @subtask.git_require(
        ["worktree", "add", "-q", "../linked", "-b", "linked"],
        cwd=repo,
      ) {
      Ok(_) => ()
      Err(reason) => fail(reason)
    }
    guard @subtask.provision(
        "\{dir}/linked",
        name="x",
        allowed_paths=["lib"],
        nonce="n1",
      )
      is Err(linked) else {
      fail("expected the linked-worktree refusal")
    }
    assert_true(linked.contains("MAIN worktree"))
  })
}

///|
/// Two disjoint slices provisioned back-to-back both go live — the shape a
/// one-call `slices` fan-out relies on (the tool layer runs these
/// concurrently; here the controller-level invariant is what matters).
async test "disjoint slices coexist as active reservations" {
  @vfs.with_tmpdir(prefix="openseek-subtask-fanout-", dir => {
    let repo = seed_repo(dir)
    let a = must_provision(
      repo,
      name="slice-a",
      allowed_paths=["lib"],
      nonce="n1",
    )
    let b = must_provision(
      repo,
      name="slice-b",
      allowed_paths=["other"],
      nonce="n2",
    )
    assert_true(a.entry.state is Running)
    assert_true(b.entry.state is Running)
    assert_true(@fs.exists("\{a.entry.worker_root}/lib/a.txt"))
    assert_true(@fs.exists("\{b.entry.worker_root}/other/b.txt"))
    // Both reservations are visible; a third overlapping slice is refused.
    guard @subtask.provision(
        repo,
        name="slice-c",
        allowed_paths=["lib/deep"],
        nonce="n3",
      )
      is Err(_) else {
      fail("expected the overlapping third slice to be refused")
    }
  })
}

///|
/// The resume path's controller half: capture is re-entrant. A second
/// capture after further edits stacks a child commit on the same branch; a
/// second capture with nothing new leaves the prior commit standing instead
/// of tripping the no-changes cleanup (which would delete validated work).
async test "capture is re-entrant: resumed work stacks on the same branch" {
  @vfs.with_tmpdir(prefix="openseek-subtask-resume-", dir => {
    let repo = seed_repo(dir)
    let provisioned = must_provision(
      repo,
      name="fix-lib",
      allowed_paths=["lib"],
      nonce="n1",
    )
    let entry = provisioned.entry
    @vfs.write_text("\{entry.worker_root}/lib", "a.txt", "ALPHA\n")
    let first = @subtask.capture(provisioned.geometry, entry)
    assert_eq(first.defects, ([] : Array[String]))
    assert_true(first.entry.state is Committed)
    guard first.entry.commit_oid is Some(commit1) else {
      fail("expected a first commit")
    }
    // Resume finds the entry continuable and flips it back to Running.
    let resumed = match
      @subtask.resume_running(provisioned.geometry, "fix-lib") {
      Ok(resumed) => resumed
      Err(reason) => fail("resume_running failed: \{reason}")
    }
    assert_true(resumed.state is Running)
    assert_eq(resumed.commit_oid, Some(commit1))
    // A resumed worker that adds nothing: the prior capture must stand and
    // the worktree and branch must survive.
    let idle = @subtask.capture(provisioned.geometry, resumed)
    assert_eq(idle.defects, ([] : Array[String]))
    assert_true(idle.entry.state is Committed)
    assert_eq(idle.entry.commit_oid, Some(commit1))
    assert_true(@fs.exists(entry.worker_root))
    // A resumed worker that adds more work: the second capture stacks a
    // commit whose parent is the first capture's commit.
    @vfs.write_text("\{entry.worker_root}/lib", "c.txt", "GAMMA\n")
    let second = @subtask.capture(provisioned.geometry, idle.entry)
    assert_eq(second.defects, ([] : Array[String]))
    assert_true(second.entry.state is Committed)
    guard second.entry.commit_oid is Some(commit2) else {
      fail("expected a second commit")
    }
    assert_true(commit1 != commit2)
    match @subtask.git_require(["rev-parse", "\{commit2}^"], cwd=repo) {
      Ok(parent) => assert_eq(parent.trim().to_owned(), commit1)
      Err(reason) => fail(reason)
    }
    // Integration lands BOTH captures' work.
    let integrated = @subtask.integrate(provisioned.geometry, second.entry)
    assert_eq(integrated.result, "integrated")
    assert_eq(@fs.read_file("\{repo}/lib/a.txt").text(), "ALPHA\n")
    assert_eq(@fs.read_file("\{repo}/lib/c.txt").text(), "GAMMA\n")
  })
}

///|
/// resume_running refuses what it must: unknown names, and states without a
/// kept worktree (a Running slice may still have a live child).
async test "resume_running refuses unknown names and running slices" {
  @vfs.with_tmpdir(prefix="openseek-subtask-resume-refuse-", dir => {
    let repo = seed_repo(dir)
    let provisioned = must_provision(
      repo,
      name="fix-lib",
      allowed_paths=["lib"],
      nonce="n1",
    )
    guard @subtask.resume_running(provisioned.geometry, "nope") is Err(unknown) else {
      fail("expected an unknown-name refusal")
    }
    assert_true(unknown.contains("no active subtask"))
    // Freshly provisioned means Running — a child may still be live.
    guard @subtask.resume_running(provisioned.geometry, "fix-lib")
      is Err(running) else {
      fail("expected a running-state refusal")
    }
    assert_true(running.contains("Running"))
  })
}
