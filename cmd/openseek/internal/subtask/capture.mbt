///|
/// Capture: after the worker child exits, decide from GIT EVIDENCE — never
/// the child's own report — whether its changes are mergeable, and if so
/// commit them on the subtask branch. The sequence pins an immutable
/// snapshot: validate the working tree, stage, REVALIDATE the staged tree
/// (a straggling process may have raced the first pass), commit with hooks
/// and signing neutralized, then verify the commit's parent and tree are
/// exactly what was validated.
pub struct CaptureOutcome {
  entry : SubtaskEntry
  /// Human-facing evidence lines (bounded by the caller when displayed).
  evidence : Array[String]
  /// Non-empty when the result must not merge; names each reason.
  defects : Array[String]
}

///|
/// Validate and (when clean) commit a finished worker's changes on its
/// subtask branch; see the file comment for the full sequence.
pub async fn capture(
  geometry : Geometry,
  entry : SubtaskEntry,
) -> CaptureOutcome {
  let worker = entry.worker_root
  let evidence : Array[String] = []
  let defects : Array[String] = []
  // The worker cannot commit (the sandbox denies the shared object store);
  // a moved HEAD means something abnormal happened — refuse to reason on it.
  match git_require(["rev-parse", "HEAD"], cwd=worker) {
    Ok(head) =>
      if head.trim() != entry.base_oid {
        defects.push(
          "worktree HEAD moved from the pinned base (\{head.trim()} != \{entry.base_oid})",
        )
      }
    Err(reason) => defects.push(reason)
  }
  let status = git_run(
    [
      "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none",
    ],
    cwd=worker,
  )
  guard status.exit_code == 0 else {
    defects.push("git status failed: \{status.output.trim()}")
    return { entry, evidence, defects }
  }
  let changes = parse_status_z(status.output)
  if changes.is_empty() {
    let entry = { ..entry, state: NoChanges }
    let _ = save_entry(geometry.common_git_dir, entry)
    evidence.push("no changes in the worker tree")
    return { entry, evidence, defects }
  }
  evidence.push("\{changes.length()} changed path(s)")
  let violations = scope_violations(changes, entry.allowed_paths)
  if !violations.is_empty() {
    defects.push(
      "out-of-scope changes (allowed: \{entry.allowed_paths.join(", ")}): \{violations.join(", ")}",
    )
  }
  if !defects.is_empty() {
    let entry = { ..entry, state: Captured }
    let _ = save_entry(geometry.common_git_dir, entry)
    return { entry, evidence, defects }
  }
  // Stage and revalidate the STAGED picture against the same contract.
  match git_require(["add", "-A"], cwd=worker) {
    Ok(_) => ()
    Err(reason) => {
      defects.push(reason)
      return { entry, evidence, defects }
    }
  }
  let staged = git_run(
    ["diff", "--cached", "--name-status", "-z", entry.base_oid],
    cwd=worker,
  )
  guard staged.exit_code == 0 else {
    defects.push("git diff --cached failed: \{staged.output.trim()}")
    return { entry, evidence, defects }
  }
  let staged_changes = parse_diff_name_status_z(staged.output)
  let staged_violations = scope_violations(staged_changes, entry.allowed_paths)
  if !staged_violations.is_empty() {
    defects.push(
      "staged changes escaped scope between validation and staging: \{staged_violations.join(", ")}",
    )
  }
  match
    git_run(["diff", "--cached", "--raw", "-z", entry.base_oid], cwd=worker) {
    raw if raw.exit_code == 0 => {
      let links = new_gitlinks_in_raw_z(raw.output)
      if !links.is_empty() {
        defects.push(
          "the worker staged embedded repositories as gitlinks: \{links.join(", ")}",
        )
      }
    }
    raw => defects.push("git diff --raw failed: \{raw.output.trim()}")
  }
  if !defects.is_empty() {
    let entry = { ..entry, state: Captured }
    let _ = save_entry(geometry.common_git_dir, entry)
    return { entry, evidence, defects }
  }
  // Pin the exact tree being committed, commit, then verify parent+tree.
  let tree_oid = match git_require(["write-tree"], cwd=worker) {
    Ok(output) => output.trim().to_owned()
    Err(reason) => {
      defects.push(reason)
      return { entry, evidence, defects }
    }
  }
  match
    git_require(
      [
        "-c",
        "core.hooksPath=/dev/null",
        "commit",
        "--no-verify",
        "--no-gpg-sign",
        "-m",
        "subtask \{entry.name}: worker changes",
      ],
      cwd=worker,
    ) {
    Ok(_) => ()
    Err(reason) => {
      defects.push(reason)
      return { entry, evidence, defects }
    }
  }
  let commit_oid = match git_require(["rev-parse", "HEAD"], cwd=worker) {
    Ok(output) => output.trim().to_owned()
    Err(reason) => {
      defects.push(reason)
      return { entry, evidence, defects }
    }
  }
  match git_require(["rev-parse", "HEAD^{tree}", "HEAD^"], cwd=worker) {
    Ok(output) => {
      let lines = output
        .trim()
        .to_owned()
        .split("\n")
        .map(l => l.to_owned())
        .collect()
      if lines.length() != 2 ||
        lines[0] != tree_oid ||
        lines[1] != entry.base_oid {
        defects.push(
          "the commit does not match the validated snapshot (tree/parent drifted)",
        )
      }
    }
    Err(reason) => defects.push(reason)
  }
  if !defects.is_empty() {
    let entry = { ..entry, state: Captured }
    let _ = save_entry(geometry.common_git_dir, entry)
    return { entry, evidence, defects }
  }
  let diffstat = git_run(
    ["diff", "--stat", entry.base_oid, commit_oid],
    cwd=worker,
  )
  if diffstat.exit_code == 0 {
    evidence.push(diffstat.output.trim().to_owned())
  }
  let entry = { ..entry, state: Committed, commit_oid: Some(commit_oid) }
  let _ = save_entry(geometry.common_git_dir, entry)
  evidence.push("committed \{commit_oid} on \{entry.branch}")
  { entry, evidence, defects }
}
