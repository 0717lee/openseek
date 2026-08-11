///|
/// Exact gitlink paths from `git ls-tree -z` or `git ls-files --stage -z`.
/// Reading Git metadata keeps paths with spaces unambiguous and still sees
/// submodules whose working directories are absent.
fn gitlink_paths(metadata : String) -> Array[String] {
  let paths : Array[String] = []
  for record in metadata.split("\u{0}") {
    guard record.has_prefix("160000 ") && record.find("\t") is Some(tab) else {
      continue
    }
    let path = record.view(start_offset=tab + 1).to_owned()
    // A conflicted index can carry several stages for one gitlink.
    if !paths.contains(path) {
      paths.push(path)
    }
  }
  paths
}

///|
/// Populate the new checkout with the same top-level submodules that are
/// initialized in the attached main checkout. Optional, uninitialized
/// submodules stay opt-in. `--checkout` deliberately overrides any configured
/// `!command` update procedure; recursive children use the ordinary checkout
/// strategy too.
async fn provision_initialized_submodules(
  origin : @pathx.Absolute,
  checkout : @pathx.Absolute,
) -> Unit {
  // Worktrees branch from HEAD, not the main checkout's staged index.
  let tree = git_output_text(origin, ["ls-tree", "-r", "-z", "HEAD"])
  let initialized : Array[String] = []
  for path in gitlink_paths(tree) {
    guard git_probe(origin, ["submodule", "status", "--", path]) is Some(status) &&
      !status.is_empty() &&
      !status.has_prefix("-") else {
      continue
    }
    initialized.push(path)
  }
  guard !initialized.is_empty() else { return }
  let args : Array[String] = []
  // `git submodule` does not forward repository-local protocol policy to the
  // clone helper. Preserve an explicit user opt-in for local submodule URLs;
  // never relax the default on the app's own authority.
  if git_probe(origin, ["config", "--get", "protocol.file.allow"])
    is Some("always") {
    args.push("-c")
    args.push("protocol.file.allow=always")
  }
  args.push("submodule")
  args.push("update")
  args.push("--init")
  args.push("--checkout")
  args.push("--recursive")
  args.push("--")
  for path in initialized {
    args.push(path)
  }
  ignore(git_in(checkout, args))
}

///|
async fn checkout_has_gitlinks(checkout : @pathx.Absolute) -> Bool {
  let index = git_output_text(checkout, ["ls-files", "--stage", "-z", "--"])
  if !gitlink_paths(index).is_empty() {
    return true
  }
  // A staged removal can hide a committed gitlink from the index while Git
  // still treats the worktree as containing submodules.
  let tree = git_output_text(checkout, ["ls-tree", "-r", "-z", "HEAD"])
  !gitlink_paths(tree).is_empty()
}

///|
test "gitlink paths preserve exact names and deduplicate conflict stages" {
  let index = "100644 dead 0\tplain\u{0}160000 aaa 0\tdeps/one\u{0}160000 bbb 1\twith space\u{0}160000 ccc 2\twith space\u{0}"
  assert_eq(gitlink_paths(index), ["deps/one", "with space"])
}

///|
#cfg(not(platform="windows"))
async test "worktree lifecycle mirrors initialized submodules" {
  archive_env_test_lock.acquire()
  defer archive_env_test_lock.release()
  let previous = @sys.get_env_var("OPENSEEK_SESSION_ROOT")
  let root = worktree_test_root("openseek-worktree-submodules-")
  @sys.set_env_var("OPENSEEK_SESSION_ROOT", root.join("global").to_string())
  defer restore_session_root_env(previous)
  let required = root.join("required")
  let optional = root.join("optional")
  prepare_git_repo(required)
  prepare_git_repo(optional)
  let repo = root.join("repo")
  prepare_git_repo(repo)
  // Local fixture repositories keep the lifecycle test deterministic and
  // offline; production submodules retain Git's normal transport policy.
  ignore(git_in(repo, ["config", "protocol.file.allow", "always"]))
  ignore(
    git_in(repo, [
      "-c",
      "protocol.file.allow=always",
      "submodule",
      "add",
      "-q",
      required.to_string(),
      "deps/required",
    ]),
  )
  ignore(
    git_in(repo, [
      "-c",
      "protocol.file.allow=always",
      "submodule",
      "add",
      "-q",
      optional.to_string(),
      "deps/optional",
    ]),
  )
  ignore(
    git_in(repo, [
      "-c", "user.email=test@example.com", "-c", "user.name=test", "-c", "commit.gpgsign=false",
      "commit", "-q", "-am", "add submodules",
    ]),
  )
  ignore(
    git_in(repo, ["submodule", "deinit", "--force", "--", "deps/optional"]),
  )
  ignore(add_workspace(repo.to_string(), fn(_) {  }))
  let manager = new_engine_manager("openseek")
  let created = create_worktree(
    manager,
    repo.to_string(),
    "s-submodules",
    fn(_) {  },
    name="with-submodules",
  )
  assert_eq(created.name, "with-submodules")
  let checkout = repo.join(".worktrees/with-submodules")
  assert_eq(
    git_in(checkout.join("deps/required"), ["rev-parse", "HEAD"]),
    git_in(required, ["rev-parse", "HEAD"]),
  )
  assert_false(@fsx.exists(checkout.join("deps/optional/.git").to_path()))
  // Repair follows the same provisioning rule after an external deletion.
  @fs.rmdir(checkout.to_string(), recursive=true)
  ignore(
    create_worktree(
      manager,
      repo.to_string(),
      "s-submodules",
      fn(_) {  },
      name="with-submodules",
    ),
  )
  assert_eq(
    git_in(checkout.join("deps/required"), ["rev-parse", "HEAD"]),
    git_in(required, ["rev-parse", "HEAD"]),
  )
  assert_false(@fsx.exists(checkout.join("deps/optional/.git").to_path()))
  // Git's own `worktree remove` refuses a tree containing gitlinks; the app's
  // fallback must honor an external lock before deleting a clean checkout.
  ignore(
    git_in(repo, [
      "worktree", "lock", "--reason", "held by test", ".worktrees/with-submodules",
    ]),
  )
  let locked_detail = try {
    ignore(
      remove_worktree(manager, repo.to_string(), "with-submodules", false, fn(
        _,
      ) {

      }),
    )
    "no error"
  } catch {
    EngineError(detail) => detail
    error if @async.is_being_cancelled() => raise error
    error => "\{error}"
  }
  assert_true(locked_detail.contains("is locked"))
  assert_true(@fsx.is_dir(checkout.to_path()))
  ignore(git_in(repo, ["worktree", "unlock", ".worktrees/with-submodules"]))
  // Once unlocked, clean removal unregisters and deletes the checkout.
  let removed = remove_worktree(
    manager,
    repo.to_string(),
    "with-submodules",
    false,
    fn(_) {  },
  )
  assert_eq(removed.worktrees.length(), 0)
  assert_false(@fsx.exists(checkout.to_path()))
  @fs.rmdir(root.to_string(), recursive=true)
}
