///|
test "a diff includes shared context around the change" {
  let old =
    #|fn main {
    #|  let x = 1
    #|  println(x)
    #|}
  let new =
    #|fn main {
    #|  let x = 2
    #|  println(x)
    #|}
  assert_eq(
    @edit_diff.generate(old, new),
    (
      #|  fn main {
      #|-   let x = 1
      #|+   let x = 2
      #|    println(x)
      #|  }
    ),
  )
}

///|
/// The empty `old_string` is how the tools spell an insertion, and the empty
/// `new_string` a deletion; neither has context to collapse.
test "an insertion is all additions and a deletion all removals" {
  assert_eq(@edit_diff.generate("", "one\ntwo"), "+ one\n+ two")
  assert_eq(@edit_diff.generate("one\ntwo", ""), "- one\n- two")
}

///|
/// The shared code-unit clamp may retain a tail that begins partway through a
/// very long line. That fragment must repeat its diff marker — including when
/// the cut lands inside the marker itself — or an addition becomes context.
#warnings("-alert_unstable")
test "a long single-line diff keeps both retained sides marked" {
  let old = "a".repeat(15_000)
  // This length puts the retained tail's start on the space inside `+ `.
  let new = "b".repeat(7_999)
  let rendered = diff_block(@edit_diff.generate(old, new))
  let markup = @rabbita.render_to_string(() => @rabbita.Val::constant(rendered))
  assert_true(markup.contains("class=\"diff-del\">- a"))
  assert_true(markup.contains("class=\"diff-add\">+ b"))
  assert_false(markup.contains("class=\"diff-add\">+  b"))
}

///|
test "an edit decodes to its anchors and the change it describes" {
  let arguments =
    #|{"path":"lib/parser.mbt","start_line":12,"old_string":"args.length()","new_string":"args.len()"}
  guard card_fields(arguments) is Some(fields) else {
    fail("expected an object payload")
  }
  guard decode_edit(fields, path_key="path") is Some(edit) else {
    fail("expected a readable edit")
  }
  assert_eq(edit.chips, ["path: lib/parser.mbt", "start_line: 12"])
  assert_eq(edit.diff, "- args.length()\n+ args.len()")
}

///|
/// The strings are what the card dramatizes, so a payload without both — or
/// one whose change is no change, which the tools reject anyway — keeps the
/// generic rendering rather than showing an empty diff.
test "a payload with no readable change decodes to nothing" {
  let missing_new =
    #|{"path":"a.mbt","old_string":"x"}
  let unchanged =
    #|{"path":"a.mbt","old_string":"x","new_string":"x"}
  let not_a_string =
    #|{"path":"a.mbt","old_string":"x","new_string":3}
  for arguments in [missing_new, unchanged, not_a_string] {
    guard card_fields(arguments) is Some(fields) else {
      fail("expected an object payload")
    }
    assert_true(decode_edit(fields, path_key="path") is None)
  }
  assert_true(edit_card("not json") is None)
  assert_true(multi_edit_card("{\"edits\":[]}") is None)
}

///|
#warnings("-alert_unstable")
test "an edit row tabs its change and payload apart from its result" {
  let arguments =
    #|{"path":"lib/parser.mbt","start_line":12,"old_string":"args.length()","new_string":"args.len()"}
  let rendered = tool_call_view({
    kind: Tool(
      call_id="c1",
      name="edit",
      arguments=Some(arguments),
      has_result=true,
      is_error=false,
      brief=Some("edit lib/parser.mbt"),
    ),
    content: "edited 1 occurrence",
    ts: None,
    sequence: None,
  })
  let markup = @rabbita.render_to_string(() => @rabbita.Val::constant(rendered))
  assert_true(markup.contains("tool-diff"))
  assert_true(markup.contains("diff-del\">- args.length()"))
  assert_true(markup.contains("diff-add\">+ args.len()"))
  assert_true(markup.contains("tool-card-chip\">path: lib/parser.mbt"))
  assert_true(markup.contains("class=\"tool-call-tabs\""))
  assert_eq(markup.split("class=\"tool-call-tab-input\"").length(), 3)
  assert_true(markup.contains(">Change</label>"))
  assert_true(markup.contains(">Original JSON</label>"))
  assert_false(markup.contains(">Output</label>"))
  assert_true(markup.contains("edited 1 occurrence"))
  // The synthesized diff stands in for the arguments dump, not beside it.
  assert_false(markup.contains("tool-call-arguments"))
  assert_true(markup.contains("tool-call-section-label\">Output"))
  assert_true(markup.contains("class=\"tool-result\""))
}

///|
#warnings("-alert_unstable")
test "a multi_edit row tabs its changes and payload apart from its result" {
  let arguments =
    #|{"edits":[{"file":"a.mbt","start_line":3,"old_string":"one","new_string":"1"},{"file":"b.mbt","start_line":9,"old_string":"two","new_string":"2"}],"revert_when_errors_above":0}
  let rendered = tool_call_view({
    kind: Tool(
      call_id="c1",
      name="multi_edit",
      arguments=Some(arguments),
      has_result=true,
      is_error=false,
      brief=Some("multi_edit 2 edits"),
    ),
    content: "applied 2 edits",
    ts: None,
    sequence: None,
  })
  let markup = @rabbita.render_to_string(() => @rabbita.Val::constant(rendered))
  assert_true(markup.contains("tool-card-chip\">file: a.mbt"))
  assert_true(markup.contains("tool-card-chip\">file: b.mbt"))
  assert_true(markup.contains("tool-card-chip\">revert_when_errors_above: 0"))
  assert_true(markup.contains("diff-add\">+ 1"))
  assert_true(markup.contains("diff-add\">+ 2"))
  assert_true(markup.contains("class=\"tool-call-tabs\""))
  assert_eq(markup.split("class=\"tool-call-tab-input\"").length(), 3)
  assert_true(markup.contains(">Changes</label>"))
  assert_true(markup.contains(">Original JSON</label>"))
  assert_false(markup.contains(">Output</label>"))
  assert_true(markup.contains("applied 2 edits"))
  assert_true(markup.contains("tool-call-section-label\">Output"))
  assert_true(markup.contains("class=\"tool-result\""))
  assert_false(markup.contains("tool-call-arguments"))
}

///|
/// A batch longer than the card renders says what it left out, rather than
/// reading as the whole batch.
#warnings("-alert_unstable")
test "a long multi_edit batch states what it did not render" {
  let entries = [
    for index in 0..<(MAX_RENDERED_EDITS + 3) => {
      "{\"file\":\"f\{index}.mbt\",\"old_string\":\"a\",\"new_string\":\"b\"}"
    }
  ]
  let arguments = "{\"edits\":[\{entries.join(",")}]}"
  guard multi_edit_card(arguments) is Some(card) else {
    fail("expected a readable multi_edit batch")
  }
  let markup = @rabbita.render_to_string(() => @rabbita.Val::constant(card))
  assert_true(markup.contains("⋯ 3 more edits, in the original ⋯"))
  assert_true(markup.contains("tool-card-chip\">file: f0.mbt"))
  // Exactly the bound, as entries. The full tool row places the dropped ones
  // in its neighboring Original JSON tab; this direct card rendering contains
  // only the readable change view.
  let entries = [..markup.split("class=\"edit-entry\"")].length() - 1
  assert_eq(entries, MAX_RENDERED_EDITS)
  assert_false(
    markup.contains("tool-card-chip\">file: f\{MAX_RENDERED_EDITS}.mbt"),
  )
}

///|
/// An entry this build cannot read does not take the readable ones down with
/// it: the card renders what it can, and the original carries the rest.
#warnings("-alert_unstable")
test "a partly readable multi_edit batch renders the edits that decode" {
  let arguments =
    #|{"edits":[{"file":"a.mbt","old_string":"one","new_string":"1"},{"note":"not an edit"}]}
  guard multi_edit_card(arguments) is Some(card) else {
    fail("expected a readable multi_edit batch")
  }
  let markup = @rabbita.render_to_string(() => @rabbita.Val::constant(card))
  assert_true(markup.contains("tool-card-chip\">file: a.mbt"))
  assert_true(markup.contains("⋯ 1 more edits, in the original ⋯"))
}
