///|
#warnings("-alert_unstable")
test "Git presentation owns chip and popover rendering" {
  let presentation = GitPresentation(
    branch="feature/shared-git",
    changes=GitChanges(added=12, removed=3, files=2, partial=false, base="main"),
    pull_request=GitPullRequest(
      number=42,
      title="Share Git presentation",
      state="open",
      draft=true,
      url="https://github.test/acme/app/pull/42",
      checks=GitChecks(passed=4, failed=0, pending=1),
    ),
  )
  assert_eq(presentation.label(), "#42 Draft")
  assert_eq(presentation.tone(), "pending")
  assert_eq(
    presentation.summary(),
    "Share Git presentation — CI 1 running · 4 passed",
  )
  let html = @rabbita.render_to_string(() => {
    @rabbita.Val::constant(presentation.render(open=true, toggle=@cmd.none))
  })
  assert_true(html.contains("composer-git-button pending open"))
  assert_true(html.contains(">Branch</span>"))
  assert_true(html.contains(">Changes</span>"))
  assert_true(html.contains("+12"))
  assert_true(html.contains("−3"))
  assert_true(html.contains("#42 Draft"))
  assert_true(html.contains(">CI</span>"))
}
