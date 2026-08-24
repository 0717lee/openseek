///|
#warnings("-alert_unstable")
fn render_review_html(node : @html.Html) -> String {
  @rabbita.render_to_string(() => @rabbita.Val::constant(node))
}

///|
test "external MoonBit source keeps the viewer and explains its IDE scope" {
  let path = @pathx.Relative("../shared/lib.mbt")
  let ctx = { ..test_ctx(), open_files: [path], active_file: Some(path) }
  let docs = owned_state().docs.copy()
  docs[path] = {
    name: "lib.mbt",
    state: TabLoaded(
      content="pub fn answer() -> Int { 42 }",
      absolute=ctx.test_resource("/shared/lib.mbt"),
      sig="1:0",
    ),
    review: None,
    stale: false,
  }
  let external = render_review_html(
    body_view(test_emit(), { ..owned_state(), docs, }, ctx),
  )
  assert_true(external.contains("class=\"ide-scope-notice\""))
  assert_true(
    external.contains(
      "This file is outside the workspace. MoonBit IDE features are unavailable. File watching is also unavailable, so changes on disk will not refresh automatically.",
    ),
  )
  assert_true(external.contains("id=\"viewer-host\""))

  let internal_path = @pathx.Relative("src/main.mbt")
  let internal_ctx = {
    ..test_ctx(),
    open_files: [internal_path],
    active_file: Some(internal_path),
  }
  let internal_docs = owned_state().docs.copy()
  internal_docs[internal_path] = loaded_doc(internal_path.0)
  let internal = render_review_html(
    body_view(
      test_emit(),
      { ..owned_state(), docs: internal_docs },
      internal_ctx,
    ),
  )
  assert_true(internal.contains("class=\"ide-scope-notice hidden\""))
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
      "id=\"markdown-viewer-host\" class=\"viewer-host editor-shell moonbit-viewer-surface-hidden\"",
    ),
  )
  assert_true(
    source.contains(
      "id=\"diff-editor-host\" class=\"viewer-host editor-shell moonbit-viewer-surface-hidden\"",
    ),
  )
  let source_breadcrumb = render_review_html(
    breadcrumb_view(test_emit(), source_state, ctx),
  )
  assert_true(source_breadcrumb.contains("aria-label=\"Full diff\""))
  assert_true(source_breadcrumb.contains("aria-pressed=\"false\""))
  assert_true(source_breadcrumb.contains(">View full diff</button>"))
  assert_false(source_breadcrumb.contains("aria-label=\"Inline diff layout\""))
  assert_true(source_breadcrumb.contains(">Mark reviewed</button>"))
  assert_true(
    source_breadcrumb.contains("aria-label=\"Changed file navigation\""),
  )
  assert_true(source_breadcrumb.contains(">1 of 1</span>"))

  let diff_doc = {
    ..source_doc,
    review: source_doc.review.map(review => { ..review, view_mode: ReviewDiff }),
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
    diff.contains(
      "id=\"markdown-viewer-host\" class=\"viewer-host editor-shell moonbit-viewer-surface-hidden\"",
    ),
  )
  assert_true(
    diff.contains("id=\"diff-editor-host\" class=\"viewer-host editor-shell\""),
  )
  let diff_breadcrumb = render_review_html(
    breadcrumb_view(test_emit(), diff_state, ctx),
  )
  assert_true(diff_breadcrumb.contains("aria-label=\"Full diff\""))
  assert_true(diff_breadcrumb.contains("aria-pressed=\"true\""))
  assert_true(diff_breadcrumb.contains(">View file</button>"))
  assert_true(diff_breadcrumb.contains("aria-label=\"Inline diff layout\""))
  assert_true(diff_breadcrumb.contains("aria-pressed=\"false\""))
  assert_true(diff_breadcrumb.contains("data-layout=\"side-by-side\""))
  assert_true(diff_breadcrumb.contains("review-layout-icon split"))
  assert_true(diff_breadcrumb.contains("aria-label=\"Comparison algorithm\""))
  assert_true(diff_breadcrumb.contains("data-diff-mode=\"core\""))
  assert_true(diff_breadcrumb.contains("data-diff-mode=\"token\""))
  assert_true(diff_breadcrumb.contains("data-diff-mode=\"tree\""))
  assert_true(diff_breadcrumb.contains("aria-label=\"Ignore comments\""))

  let fallback_breadcrumb = render_review_html(
    breadcrumb_view(
      test_emit(),
      {
        ..diff_state,
        review_diff_mode: ReviewDiffTree,
        review_diff_status: Some({
          requested: ReviewDiffTree,
          effective: ReviewDiffToken,
          fell_back: true,
        }),
      },
      ctx,
    ),
  )
  assert_true(
    fallback_breadcrumb.contains("Tree unavailable — showing Token diff"),
  )
  assert_true(fallback_breadcrumb.contains("aria-live=\"polite\""))

  let inline_breadcrumb = render_review_html(
    breadcrumb_view(
      test_emit(),
      { ..diff_state, review_diff_layout: ReviewInline },
      ctx,
    ),
  )
  assert_true(inline_breadcrumb.contains("aria-label=\"Inline diff layout\""))
  assert_true(inline_breadcrumb.contains("aria-pressed=\"true\""))
  assert_true(inline_breadcrumb.contains("data-layout=\"inline\""))
  assert_true(inline_breadcrumb.contains("review-layout-icon inline"))

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
test "desktop explicitly routes Markdown source while DiffEditor stays code-only" {
  let path = @pathx.Relative("docs/Guide.MD")
  let ctx = { ..test_ctx(), open_files: [path], active_file: Some(path) }
  let docs = owned_state().docs.copy()
  docs[path] = loaded_doc(path.0)
  let source_state = { ..owned_state(), docs, }
  let source = render_review_html(body_view(test_emit(), source_state, ctx))
  assert_true(
    source.contains(
      "id=\"viewer-host\" class=\"viewer-host editor-shell moonbit-viewer-surface-hidden\"",
    ),
  )
  assert_true(
    source.contains(
      "id=\"markdown-viewer-host\" class=\"viewer-host editor-shell\"",
    ),
  )
  assert_true(
    source.contains(
      "id=\"diff-editor-host\" class=\"viewer-host editor-shell moonbit-viewer-surface-hidden\"",
    ),
  )

  let selected = test_modified_change(path)
  let diff_docs = docs.copy()
  diff_docs[path] = {
    ..loaded_doc(path.0),
    review: Some({
      generation: 1,
      working_generation: 1,
      baseline: ReviewContent("# Before"),
      view_mode: ReviewDiff,
      selected,
    }),
  }
  let diff = render_review_html(
    body_view(test_emit(), { ..source_state, docs: diff_docs }, ctx),
  )
  assert_true(
    diff.contains(
      "id=\"viewer-host\" class=\"viewer-host editor-shell moonbit-viewer-surface-hidden\"",
    ),
  )
  assert_true(
    diff.contains(
      "id=\"markdown-viewer-host\" class=\"viewer-host editor-shell moonbit-viewer-surface-hidden\"",
    ),
  )
  assert_true(
    diff.contains("id=\"diff-editor-host\" class=\"viewer-host editor-shell\""),
  )
}

///|
test "non-MoonBit full diff omits specialized provider controls" {
  let path = @pathx.Relative("README.md")
  let ctx = { ..test_ctx(), open_files: [path], active_file: Some(path) }
  let selected = test_modified_change(path)
  let docs = owned_state().docs.copy()
  docs[path] = {
    ..loaded_doc(path.0),
    review: Some({
      generation: 1,
      working_generation: 1,
      baseline: ReviewContent("old text"),
      view_mode: ReviewDiff,
      selected,
    }),
  }
  let breadcrumb = render_review_html(
    breadcrumb_view(
      test_emit(),
      { ..owned_state(), docs, review_diff_mode: ReviewDiffTree },
      ctx,
    ),
  )
  assert_false(breadcrumb.contains("aria-label=\"Comparison algorithm\""))
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
      view_mode: ReviewDiff,
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
      "id=\"diff-editor-host\" class=\"viewer-host editor-shell\"",
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
      "id=\"diff-editor-host\" class=\"viewer-host editor-shell moonbit-viewer-surface-hidden\"",
    ),
  )
}
