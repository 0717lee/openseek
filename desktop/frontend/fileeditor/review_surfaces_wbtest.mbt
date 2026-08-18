///|
#warnings("-alert_unstable")
fn render_review_html(node : @html.Html) -> String {
  @rabbita.render_to_string(() => @rabbita.Val::constant(node))
}

///|
test "desktop review keeps sibling hosts stable across source and diff modes" {
  let path = @pathx.Relative("src/main.mbt")
  let ctx = { ..test_ctx(), open_files: [path], active_file: Some(path) }
  let selected = test_modified_change(path)
  let source_doc = {
    ..loaded_doc("src/main.mbt"),
    review: Some({
      generation: 1,
      working_generation: 1,
      baseline: ReviewContent("old source"),
      view_mode: ReviewSource,
      selected,
    }),
  }
  let source_docs = owned_state().docs.copy()
  source_docs[path] = source_doc
  let source_state = {
    ..owned_state(),
    docs: source_docs,
    explorer_mode: ExplorerChanges,
    changes: ChangeListReady(
      repository=true,
      files=[selected],
      refreshing=false,
      refresh_again=false,
    ),
  }
  let source = render_review_html(body_view(test_emit(), source_state, ctx))
  assert_true(
    source.contains("id=\"viewer-host\" class=\"viewer-host editor-shell\""),
  )
  assert_true(
    source.contains(
      "id=\"unified-diff-host\" class=\"viewer-host editor-shell moonbit-viewer-surface-hidden\"",
    ),
  )
  let source_breadcrumb = render_review_html(
    breadcrumb_view(test_emit(), source_state, ctx),
  )
  assert_true(source_breadcrumb.contains("aria-label=\"Full diff\""))
  assert_true(source_breadcrumb.contains("aria-pressed=\"false\""))
  assert_true(source_breadcrumb.contains(">View full diff</button>"))
  assert_false(source_breadcrumb.contains("aria-label=\"Unified diff layout\""))
  assert_true(source_breadcrumb.contains(">Mark reviewed</button>"))
  assert_true(
    source_breadcrumb.contains("aria-label=\"Changed file navigation\""),
  )
  assert_true(source_breadcrumb.contains(">1 of 1</span>"))

  let diff_doc = {
    ..source_doc,
    review: source_doc.review.map(review => {
      ..review,
      view_mode: ReviewUnifiedDiff,
    }),
  }
  let diff_docs = source_docs.copy()
  diff_docs[path] = diff_doc
  let diff_state = { ..source_state, docs: diff_docs }
  let diff = render_review_html(body_view(test_emit(), diff_state, ctx))
  assert_true(
    diff.contains(
      "id=\"viewer-host\" class=\"viewer-host editor-shell moonbit-viewer-surface-hidden\"",
    ),
  )
  assert_true(
    diff.contains("id=\"unified-diff-host\" class=\"viewer-host editor-shell\""),
  )
  let diff_breadcrumb = render_review_html(
    breadcrumb_view(test_emit(), diff_state, ctx),
  )
  assert_true(diff_breadcrumb.contains("aria-label=\"Full diff\""))
  assert_true(diff_breadcrumb.contains("aria-pressed=\"true\""))
  assert_true(diff_breadcrumb.contains(">View file</button>"))
  assert_true(diff_breadcrumb.contains("aria-label=\"Unified diff layout\""))
  assert_true(diff_breadcrumb.contains("aria-pressed=\"false\""))
  assert_true(diff_breadcrumb.contains("data-layout=\"split\""))
  assert_true(diff_breadcrumb.contains("review-layout-icon split"))

  let unified_breadcrumb = render_review_html(
    breadcrumb_view(
      test_emit(),
      { ..diff_state, review_diff_layout: ReviewUnified },
      ctx,
    ),
  )
  assert_true(unified_breadcrumb.contains("aria-label=\"Unified diff layout\""))
  assert_true(unified_breadcrumb.contains("aria-pressed=\"true\""))
  assert_true(unified_breadcrumb.contains("data-layout=\"unified\""))
  assert_true(unified_breadcrumb.contains("review-layout-icon unified"))

  let reviewed_state = { ..diff_state, reviewed_changes: [selected] }
  let reviewed_breadcrumb = render_review_html(
    breadcrumb_view(test_emit(), reviewed_state, ctx),
  )
  assert_true(reviewed_breadcrumb.contains(">✓ Reviewed</button>"))
  let reviewed_tree = render_review_html(
    tree_pane(test_emit(), reviewed_state, ctx),
  )
  assert_true(reviewed_tree.contains("1 of 1 reviewable files reviewed"))
  assert_true(reviewed_tree.contains("change-row selected reviewed"))
  assert_true(reviewed_tree.contains("id=\"changed-file-row-0\""))
}

///|
test "pending full diff never reveals the source surface" {
  let path = @pathx.Relative("src/main.mbt")
  let ctx = { ..test_ctx(), open_files: [path], active_file: Some(path) }
  let selected = test_modified_change(path)
  let pending_doc = {
    ..loaded_doc(path.0),
    review: Some({
      generation: 1,
      working_generation: 1,
      baseline: ReviewLoading,
      view_mode: ReviewUnifiedDiff,
      selected,
    }),
  }
  let pending_docs = owned_state().docs.copy()
  pending_docs[path] = pending_doc
  let pending_state = { ..owned_state(), docs: pending_docs }
  let pending = render_review_html(body_view(test_emit(), pending_state, ctx))
  assert_true(
    pending.contains(
      "id=\"viewer-host\" class=\"viewer-host editor-shell moonbit-viewer-surface-hidden\"",
    ),
  )
  assert_true(
    pending.contains(
      "id=\"unified-diff-host\" class=\"viewer-host editor-shell\"",
    ),
  )
  assert_false(pending.contains("Loading diff for main.mbt…"))
  assert_true(pending.contains("viewer-notice diff-transition-shield"))

  let (_, delayed_state) = update(
    test_emit(),
    DiffLoadingDue(owner=test_ctx().owner, path~, generation=1),
    pending_state,
    ctx,
  )
  let delayed = render_review_html(body_view(test_emit(), delayed_state, ctx))
  assert_true(delayed.contains("Loading diff for main.mbt…"))
  assert_false(delayed.contains("viewer-notice diff-transition-shield"))

  // Once the baseline is known to be unavailable there is no comparison to
  // wait for, so the ordinary file surface becomes usable again.
  let unavailable_docs = pending_docs.copy()
  unavailable_docs[path] = {
    ..pending_doc,
    review: pending_doc.review.map(review => {
      ..review,
      baseline: ReviewFailed("missing baseline"),
    }),
  }
  let unavailable = render_review_html(
    body_view(test_emit(), { ..delayed_state, docs: unavailable_docs }, ctx),
  )
  assert_true(
    unavailable.contains(
      "id=\"viewer-host\" class=\"viewer-host editor-shell\"",
    ),
  )
  assert_true(
    unavailable.contains(
      "id=\"unified-diff-host\" class=\"viewer-host editor-shell moonbit-viewer-surface-hidden\"",
    ),
  )
}
