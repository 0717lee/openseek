// Fold-preview policy is DOM-free. Rendering, controls, and runtime gutter
// sizing are exercised by the real Playwright Markdown-comment contracts.

///|
test "Markdown comment folded previews require provider opt-in" {
  assert_eq(markdown_comment_folded_preview("---", true), None)
  assert_eq(
    markdown_comment_folded_preview(
      (
        #|---
        #|
        #|Only summary
      ),
      true,
    ),
    None,
  )
  assert_eq(
    markdown_comment_folded_preview(
      (
        #|---
        #|
        #|# Summary
        #|
        #|More **documentation**.
        #|
        #|- detail
      ),
      true,
    ),
    Some(
      (
        #|---
        #|
        #|# Summary
      ),
    ),
  )
  assert_eq(
    markdown_comment_folded_preview(
      "---\r\n\r\nWindows summary\r\n\r\nWindows details", true,
    ),
    Some(
      (
        #|---
        #|
        #|Windows summary
      ),
    ),
  )
  assert_eq(
    markdown_comment_folded_preview(
      "---\rClassic summary\r\rClassic details", true,
    ),
    Some(
      (
        #|---
        #|
        #|Classic summary
      ),
    ),
  )
  assert_eq(
    markdown_comment_folded_preview(
      (
        #|---
        #|
        #|Summary
        #|
        #|Ordinary Markdown stays expanded.
      ),
      false,
    ),
    None,
  )
  assert_eq(
    markdown_comment_folded_preview("First line\nSecond line", true),
    None,
  )
  assert_eq(
    markdown_comment_folded_preview(
      (
        #|```mermaid
        #|flowchart LR
        #|A --> B
        #|```
      ),
      true,
    ),
    None,
  )
  assert_eq(
    markdown_comment_folded_preview(
      (
        #|
        #|
        #|Only line
        #|
        #|
      ),
      true,
    ),
    None,
  )
}
