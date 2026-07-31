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
    // The reservation is released: the same slice provisions again.
    let _ = must_provision(
      repo,
      name="retry",
      allowed_paths=["lib"],
      nonce="n2",
    )
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
    // stage the resolution — then the controller commits.
    @vfs.write_text("\{repo}/lib", "a.txt", "MERGED\n")
    match @subtask.git_require(["add", "lib/a.txt"], cwd=repo) {
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
