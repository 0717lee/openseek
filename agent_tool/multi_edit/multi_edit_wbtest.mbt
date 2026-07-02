///|
/// White-box tests for the auto-revert guard's pure pieces: threshold policy
/// and the two report formatters. The end-to-end revert (which runs a real
/// `moon check`) is exercised by the A/B harness, not here.

///|
fn sample_write(path : String, edits : Int) -> PreparedWrite {
  { path, new_content: "new", original_content: "old", edit_count: edits }
}

///|
test "effective_revert_threshold defaults and clamps to the host policy" {
  // Absent → host default.
  assert_eq(effective_revert_threshold(None), DefaultRevertThreshold)
  // The model may tighten the guard, down to 0 (revert on any new error).
  assert_eq(effective_revert_threshold(Some(2)), 2)
  assert_eq(effective_revert_threshold(Some(0)), 0)
  // A negative request is floored at 0, not treated as "disable".
  assert_eq(effective_revert_threshold(Some(-3)), 0)
  // The model cannot raise the guard past the host cap.
  assert_eq(
    effective_revert_threshold(Some(HostMaxRevertThreshold + 50)),
    HostMaxRevertThreshold,
  )
}

///|
test "keep_response is clean at zero errors and honest below threshold" {
  let summary = "ok: applied 3 edit(s) across 1 file(s)\na.mbt: 3 edit(s)"
  let clean : @auto_check.CheckErrors = {
    error_count: 0,
    warning_count: 12,
    first_errors: [],
    truncated: false,
  }
  assert_eq(
    keep_response(summary, clean, 5),
    "\{summary}\nmoon check: ok — 0 errors, 12 warning(s)",
  )
  let kept : @auto_check.CheckErrors = {
    error_count: 2,
    warning_count: 12,
    first_errors: ["a.mbt:1:1-1:2: boom", "a.mbt:4:1-4:2: bang"],
    truncated: false,
  }
  assert_eq(
    keep_response(summary, kept, 5),
    "\{summary}\nmoon check: applied with 2 error(s) kept (≤ revert_when_errors_above=5), 12 warning(s)\na.mbt:1:1-1:2: boom\na.mbt:4:1-4:2: bang",
  )
}

///|
test "keep_response on the false-alarm path makes the introduced split explicit" {
  let summary = "ok: applied 3 edit(s) across 1 file(s)\na.mbt: 3 edit(s)"
  // Baseline already had 7 errors; the batch kept it at 8 (1 newly introduced),
  // which is ≤ threshold even though the 8 total is above it. The line must not
  // claim "8 ≤ 5"; it states the 1 introduced instead.
  let after : @auto_check.CheckErrors = {
    error_count: 8,
    warning_count: 0,
    first_errors: ["a.mbt:1:1-1:2: boom"],
    truncated: false,
  }
  assert_eq(
    keep_response(summary, after, 5, introduced=1),
    "\{summary}\nmoon check: applied with 8 error(s) kept (only 1 newly introduced ≤ revert_when_errors_above=5; the rest pre-existed), 0 warning(s)\na.mbt:1:1-1:2: boom",
  )
}

///|
test "revert_report names the introduced count and the first errors" {
  let after : @auto_check.CheckErrors = {
    error_count: 9,
    warning_count: 3,
    first_errors: ["a.mbt:1:1-1:2: boom", "b.mbt:2:1-2:2: bang"],
    truncated: false,
  }
  let report = revert_report(
    [sample_write("a.mbt", 4), sample_write("b.mbt", 2)],
    after,
    introduced=9,
    threshold=5,
    restore_failures=[],
  )
  assert_eq(
    report,
    (
      #|reverted: applied 6 edit(s) across 2 file(s), but moon check then reported 9 error(s) (9 newly introduced > revert_when_errors_above=5); all 2 file(s) were rolled back to their pre-batch contents.
      #|first 2 error(s):
      #|a.mbt:1:1-1:2: boom
      #|b.mbt:2:1-2:2: bang
      #|re-issue with more precise old_strings (include the receiver) and/or smaller batches so a replacement cannot stray onto unintended sites.
    ),
  )
}

///|
test "revert_report marks a truncated count and a failed restore" {
  let after : @auto_check.CheckErrors = {
    error_count: 400,
    warning_count: 0,
    first_errors: ["a.mbt:1:1-1:2: boom"],
    truncated: true,
  }
  let report = revert_report(
    [sample_write("a.mbt", 1)],
    after,
    introduced=400,
    threshold=5,
    restore_failures=["a.mbt"],
  )
  assert_true(report.contains("reported ≥400 error(s)"))
  assert_true(report.contains("WARNING: could not restore 1 file(s): a.mbt"))
}

///|
test "batch_reject_report caps detailed files and labels lower bounds" {
  let rejections : Array[FileRejection] = [
    for index in 0..<5 => {
      (
        {
          path: "lib/f\{index}.mbt",
          introduced: 1,
          truncated: index == 0,
          section: "lib/f\{index}.mbt: would gain 1 new parse error(s):\nlib/f\{index}.mbt:1:1: e",
        } : FileRejection)
    }
  ]
  let report = batch_reject_report(rejections, total=5, any_truncated=true)
  assert_true(
    report.contains(
      "rejected: the batch would introduce at least 5 new parse error(s) across 5 file(s), so NO files were changed.",
    ),
  )
  // Only the first RejectedFileDisplayLimit files are detailed; the rest are
  // named in the overflow line.
  assert_true(report.contains("lib/f2.mbt: would gain"))
  assert_false(report.contains("lib/f3.mbt: would gain"))
  assert_true(report.contains("…and 2 more file(s): lib/f3.mbt, lib/f4.mbt"))
  assert_true(report.contains("revert_on_parse_errors=false"))
}
