///|
#warnings("-alert_unstable")
fn render_semantic_review_html(node : @html.Html) -> String {
  @rabbita.render_to_string(() => @rabbita.Val::constant(node))
}

///|
fn semantic_test_input(
  mode : @moon_diff_provider.MoonDiffMode,
) -> SemanticReviewInput {
  {
    old_name: "old.mbt",
    new_name: "new.mbt",
    old_source: "",
    new_source: "",
    mode,
    ignore_comments: true,
    ignore_tests: true,
  }
}

///|
fn semantic_test_section(
  key : String,
  identity : Int?,
  kind : @moon_diff_provider.SemanticReviewSectionKind,
  original_source : String,
  modified_source : String,
) -> @moon_diff_provider.SemanticReviewSection {
  {
    key,
    identity,
    kind,
    old_range: Some({ start_line_number: 10, line_count: 2, }),
    new_range: Some({ start_line_number: 30, line_count: 2, }),
    old_context: Some("fn old_context"),
    new_context: Some("fn new_context"),
    fallbacks: [],
    original_source,
    modified_source,
    diff: @moon_diff_provider.SemanticReviewDiff::Core,
  }
}

///|
test "semantic view renders keyed DiffEditor hosts instead of source HTML" {
  let main = semantic_test_section(
    "section-1",
    Some(1),
    @moon_diff_provider.SemanticReviewSectionKind::Matched,
    "OLD_SOURCE_MUST_NOT_BE_HTML",
    "NEW_SOURCE_MUST_NOT_BE_HTML",
  )
  let deleted = {
    ..semantic_test_section(
      "section-0",
      Some(0),
      @moon_diff_provider.SemanticReviewSectionKind::Deleted,
      "DELETED_SOURCE_MUST_NOT_BE_HTML",
      "",
    ),
    new_range: None,
    new_context: None,
  }
  let plan : @moon_diff_provider.SectionedSemanticReviewPlan = {
    requested: @moon_diff_provider.Tree,
    status: @moon_diff_provider.SemanticReviewStatus::Reordered,
    reordered: true,
    main_sections: [main],
    deleted_sections: [deleted],
  }
  let html = render_semantic_review_html(
    semantic_plan_view(
      test_emit(),
      plan,
      semantic_test_input(@moon_diff_provider.Tree),
      [],
    ),
  )
  let reordered = html.find("Top-level declarations are reordered").unwrap()
  let main_title = html.find("fn new_context").unwrap()
  let deleted_title = html.find("fn old_context").unwrap()
  assert_true(reordered < main_title)
  assert_true(main_title < deleted_title)
  assert_true(html.contains("class=\"semantic-entry-status deleted\">D</span>"))
  assert_true(html.contains("aria-expanded=\"true\""))
  assert_true(html.contains("id=\"semantic-diff-editor-section-1\""))
  assert_true(html.contains("id=\"semantic-diff-editor-section-0\""))
  assert_false(html.contains("OLD_SOURCE_MUST_NOT_BE_HTML"))
  assert_false(html.contains("NEW_SOURCE_MUST_NOT_BE_HTML"))
  assert_false(html.contains("DELETED_SOURCE_MUST_NOT_BE_HTML"))
  assert_false(html.contains("<table"))
  assert_false(html.contains("class=\"diff-scroll\""))
}

///|
test "semantic whole fallback keeps metadata beside an empty editor host" {
  let whole = {
    ..semantic_test_section(
      "whole",
      None,
      @moon_diff_provider.SemanticReviewSectionKind::Whole,
      "old",
      "new",
    ),
    fallbacks: ["syntax matching unavailable"],
    old_range: None,
    new_range: None,
    old_context: None,
    new_context: None,
  }
  let plan : @moon_diff_provider.SectionedSemanticReviewPlan = {
    requested: @moon_diff_provider.Tree,
    status: @moon_diff_provider.SemanticReviewStatus::Changed,
    reordered: false,
    main_sections: [whole],
    deleted_sections: [],
  }
  let html = render_semantic_review_html(
    semantic_plan_view(
      test_emit(),
      plan,
      semantic_test_input(@moon_diff_provider.Tree),
      [],
    ),
  )
  assert_true(html.contains("Lexical fallback"))
  assert_true(html.contains("syntax matching unavailable"))
  assert_true(html.contains("id=\"semantic-diff-editor-whole\""))
  assert_true(html.contains("Whole file"))
}

///|
test "semantic empty statuses do not allocate editor hosts" {
  for
    case in [
      (
        @moon_diff_provider.SemanticReviewStatus::IgnoredOnly,
        "No changes besides ignored",
      ),
      (
        @moon_diff_provider.SemanticReviewStatus::Identical,
        "No structural changes found",
      ),
      (
        @moon_diff_provider.SemanticReviewStatus::NoStructuralChanges,
        "No structural changes found",
      ),
    ] {
    let (status, expected) = case
    let plan : @moon_diff_provider.SectionedSemanticReviewPlan = {
      requested: @moon_diff_provider.Tree,
      status,
      reordered: false,
      main_sections: [],
      deleted_sections: [],
    }
    let html = render_semantic_review_html(
      semantic_plan_view(
        test_emit(),
        plan,
        semantic_test_input(@moon_diff_provider.Tree),
        [],
      ),
    )
    assert_true(html.contains(expected))
    assert_false(html.contains("semantic-diff-editor-"))
  }
}

///|
test "default semantic filters explain an ignored-only empty result" {
  let plan : @moon_diff_provider.SectionedSemanticReviewPlan = {
    requested: @moon_diff_provider.Token,
    status: @moon_diff_provider.SemanticReviewStatus::IgnoredOnly,
    reordered: false,
    main_sections: [],
    deleted_sections: [],
  }
  let html = render_semantic_review_html(
    semantic_plan_view(
      test_emit(),
      plan,
      semantic_test_input(@moon_diff_provider.Token),
      [],
    ),
  )
  assert_true(
    html.contains(
      "No changes besides ignored comments, blank lines, or test blocks were found. Turn off the relevant Ignore filter to view them.",
    ),
  )
  assert_true(html.contains("class=\"semantic-empty\""))
  assert_false(html.contains("semantic-diff-editor-"))
}

///|
test "semantic input follows active MoonBit review and ignores layout" {
  let path = @pathx.Relative("src/main.mbt")
  let selected = test_modified_change(path)
  let docs = owned_state().docs.copy()
  docs[path] = {
    ..loaded_doc(path.0),
    state: TabLoaded(
      content="fn value() { 2 }",
      absolute=test_ctx().test_resource("/work/src/main.mbt"),
      sig="working",
    ),
    review: Some({
      generation: 1,
      working_generation: 1,
      baseline: ReviewContent("fn value() { 1 }"),
      view_mode: ReviewDiff,
      selected,
    }),
  }
  let state = {
    ..owned_state(),
    docs,
    review_diff_mode: ReviewDiffToken,
    review_diff_layout: ReviewInline,
  }
  let ctx = { ..test_ctx(), open_files: [path], active_file: Some(path), }
  guard semantic_review_input(state, ctx) is Some(input) else {
    fail("expected semantic review input")
  }
  assert_eq(input.old_source, "fn value() { 1 }")
  assert_eq(input.new_source, "fn value() { 2 }")
  assert_true(input.mode is @moon_diff_provider.Token)
  assert_eq(
    semantic_review_input({ ..state, review_diff_mode: ReviewDiffCore, }, ctx),
    None,
  )
}

///|
test "semantic state cache drives section chrome" {
  let input = semantic_test_input(@moon_diff_provider.Token)
  let section = semantic_test_section(
    "section-2",
    Some(2),
    @moon_diff_provider.SemanticReviewSectionKind::Matched,
    "old",
    "new",
  )
  let plan : @moon_diff_provider.SectionedSemanticReviewPlan = {
    requested: @moon_diff_provider.Token,
    status: @moon_diff_provider.SemanticReviewStatus::Changed,
    reordered: false,
    main_sections: [section],
    deleted_sections: [],
  }
  let state = {
    ..State::empty(),
    semantic_review_input: Some(input),
    semantic_review_plan: Some(plan),
    semantic_review_collapsed: ["section-2"],
    review_diff_layout: ReviewInline,
  }
  let html = render_semantic_review_html(
    semantic_review_view(test_emit(), state),
  )
  assert_true(html.contains("data-mode=\"token\""))
  assert_true(html.contains("data-layout=\"unified\""))
  assert_true(html.contains("semantic-diff-entry collapsed"))
  assert_true(html.contains("aria-expanded=\"false\""))
  assert_true(html.contains("id=\"semantic-diff-editor-section-2\""))
  assert_true(html.contains("id=\"semantic-review-scroll-width\""))
}

///|
test "semantic multi-diff entry collapse is tab-local retained state" {
  let section = semantic_test_section(
    "section-4",
    Some(4),
    @moon_diff_provider.SemanticReviewSectionKind::Matched,
    "old",
    "new",
  )
  let state = {
    ..State::empty(),
    semantic_review_plan: Some({
      requested: @moon_diff_provider.Token,
      status: @moon_diff_provider.SemanticReviewStatus::Changed,
      reordered: false,
      main_sections: [section],
      deleted_sections: [],
    }),
  }
  let (_, collapsed) = update(
    test_emit(),
    SemanticReviewSectionToggled("section-4"),
    state,
    test_ctx(),
  )
  assert_eq(collapsed.semantic_review_collapsed, ["section-4"])
  let (_, expanded) = update(
    test_emit(),
    SemanticReviewSectionToggled("section-4"),
    collapsed,
    test_ctx(),
  )
  assert_true(expanded.semantic_review_collapsed.is_empty())
  let (_, unknown) = update(
    test_emit(),
    SemanticReviewSectionToggled("missing"),
    expanded,
    test_ctx(),
  )
  assert_true(unknown == expanded)
}
