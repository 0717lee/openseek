///|
/// One bounded wall-clock budget for the WHOLE baseline capture (both git
/// probes): a goal set is a rare, explicit command, but it runs on the
/// serve loop's single consumer, so a hung git must cost seconds, not the
/// session.
const BaselineCaptureBudgetMs : Int = 2_000

///|
/// Run `command args...` in `cwd`, capturing stdout. `Some(output)` only on
/// exit 0; any failure — spawn, nonzero exit, pipe trouble — is `None`.
async fn run_capture(
  command : String,
  args : Array[String],
  cwd : String,
) -> String? {
  let (stdout_reader, child_stdout) = @process.read_from_process() catch {
    error if @async.is_being_cancelled() => raise error
    _ => return None
  }
  let mut exit_code = -1
  let output = StringBuilder()
  (@async.with_task_group() <| group => {
    let process = @process.spawn(
      group,
      command,
      args,
      inherit_env=true,
      stdout=child_stdout,
      cwd=cwd.view(),
      no_wait=true,
    ) catch {
      error if @async.is_being_cancelled() => {
        stdout_reader.close()
        raise error
      }
      _ => {
        stdout_reader.close()
        return
      }
    }
    try {
      while stdout_reader.read_until("\n") is Some(line) {
        output.write_string(line)
      }
    } catch {
      error if @async.is_being_cancelled() => {
        stdout_reader.close()
        process.cancel()
        raise error
      }
      _ => ()
    }
    exit_code = process.wait() catch {
      error if @async.is_being_cancelled() => raise error
      _ => -1
    }
    stdout_reader.close()
    process.cancel()
  }) catch {
    error if @async.is_being_cancelled() || @async.is_cancellation_error(error) =>
      raise error
    _ => return None
  }
  if exit_code == 0 {
    Some(output.to_string())
  } else {
    None
  }
}

///|
/// Capture the goal-baseline notice for `workspace_root`: the commit the
/// worktree sits on plus whether it is dirty. `None` when the workspace is
/// not a git repo, git is unavailable, or the probe exceeds its budget —
/// the goal still sets; only the future review gate loses its anchor. A
/// failed dirty probe reports dirty=true: the conservative direction for an
/// audit anchor.
async fn capture_goal_baseline(workspace_root : String) -> String? {
  let probe = @async.with_timeout_opt(BaselineCaptureBudgetMs, () => {
    guard run_capture("git", ["rev-parse", "HEAD"], workspace_root)
      is Some(sha_line) else {
      return None
    }
    let sha = sha_line.trim().to_owned()
    if sha.is_empty() {
      return None
    }
    let dirty = match
      run_capture("git", ["status", "--porcelain"], workspace_root) {
      Some(status) => !status.trim().is_empty()
      None => true
    }
    Some(@agent_session.goal_baseline_notice(sha~, dirty~))
  }) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return None
  }
  probe.bind(x => x)
}

///|
async test "capture_goal_baseline probes the enclosing repo" {
  // Needs git and spawn permission; this checkout is a git repo. Guarded
  // rather than asserted: sandboxes without spawn or git report None.
  let notice = capture_goal_baseline(".")
  guard notice is Some(notice) else {
    println("skipped: git probe unavailable")
    return
  }
  guard @agent_session.parse_goal_baseline(notice) is Some(baseline) else {
    fail("expected a parseable baseline notice: \{notice}")
  }
  // A full commit id, not a short one: the gate resolves it exactly.
  assert_eq(baseline.sha.length(), 40)
}
