///|
test "unified diff comments retain line identity and trim the submitted text" {
  install_mounted_test_browser()
  defer restore_mounted_test_browser()
  let host = @rdom.document().create_element("div")
  let submitted : Ref[@unified_diff.UnifiedDiffLineComment?] = Ref(None)
  let view = UnifiedDiffView::create(host, on_comment=comment => {
    submitted.val = Some(comment)
  })
  defer view.dispose()
  view.set_diff("old", "new", context_lines=0)
  assert_eq(
    unified_diff_test_count(host, ".moonbit-unified-diff-comment-action"),
    2,
  )
  assert_eq(
    unified_diff_test_count(host, ".moonbit-unified-diff-line-deletion"),
    1,
  )
  assert_eq(
    unified_diff_test_count(host, ".moonbit-unified-diff-line-commentable"),
    2,
  )
  unified_diff_test_click(host, ".moonbit-unified-diff-comment-action", 0)
  assert_eq(
    unified_diff_test_count(host, ".moonbit-unified-diff-comment-form"),
    1,
  )
  unified_diff_test_submit(host, "  explain the deletion  ")
  assert_eq(
    submitted.val,
    Some({
      line: {
        kind: Deletion,
        original_line_number: Some(1),
        modified_line_number: None,
        text: "old",
      },
      comment: "explain the deletion",
    }),
  )
  assert_eq(
    unified_diff_test_count(host, ".moonbit-unified-diff-comment-form"),
    0,
  )
}

///|
test "unified diff stays read-only when its host omits the comment callback" {
  install_mounted_test_browser()
  defer restore_mounted_test_browser()
  let host = @rdom.document().create_element("div")
  let view = UnifiedDiffView::create(host)
  defer view.dispose()
  view.set_diff("old", "new", context_lines=0)
  assert_eq(
    unified_diff_test_count(host, ".moonbit-unified-diff-comment-action"),
    0,
  )
  assert_eq(unified_diff_test_count(host, ".moonbit-unified-diff-line"), 2)
}

///|
extern "js" fn unified_diff_test_count(
  host : @rdom.Element,
  selector : String,
) -> Int = "(host, selector) => host.querySelectorAll(selector).length"

///|
extern "js" fn unified_diff_test_click(
  host : @rdom.Element,
  selector : String,
  index : Int,
) -> Unit =
  #| (host, selector, index) => {
  #|   const target = host.querySelectorAll(selector)[index];
  #|   if (!target) throw new Error(`missing ${selector} at ${index}`);
  #|   target.dispatchEvent(new Event("click", { bubbles: true, cancelable: true }));
  #| }

///|
extern "js" fn unified_diff_test_submit(
  host : @rdom.Element,
  comment : String,
) -> Unit =
  #| (host, comment) => {
  #|   const textarea = host.querySelector("textarea");
  #|   if (!textarea) throw new Error("missing unified diff comment textarea");
  #|   textarea.value = comment;
  #|   textarea.dispatchEvent(new Event("input", { bubbles: true }));
  #|   const submit = host.querySelector(".moonbit-unified-diff-comment-submit");
  #|   if (!submit) throw new Error("missing unified diff comment submit");
  #|   submit.dispatchEvent(new Event("click", { bubbles: true, cancelable: true }));
  #| }
