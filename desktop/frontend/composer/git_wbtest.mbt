///|
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
  // The chip stays lit while its popover floats. (What the popover itself
  // draws is browser-only: rabbita 0.15.1 removed the js `render_to_string`.)
  assert_eq(
    presentation.button_class(open=true),
    "composer-git-button pending open",
  )
  assert_eq(
    presentation.button_class(open=false),
    "composer-git-button pending",
  )
  guard presentation.changes is Some(changes) else {
    fail("expected recorded changes")
  }
  assert_eq(changes.file_count(), "2 files")
}
