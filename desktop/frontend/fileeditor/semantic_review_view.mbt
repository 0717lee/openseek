///|
/// The working-tree document behind Token/Tree's synthetic Modified models.
/// Historical comparisons and a deleted working file deliberately carry no
/// live document because current-checkout IDE requests would be misleading.
pub(all) struct SemanticReviewLiveDocument {
  resource : @common.Uri
  path : @pathx.Relative
} derive(Eq, Debug)

///|
/// The smallest input that can change a Token/Tree section plan. Layout is
/// deliberately absent: switching split/inline updates existing DiffEditors
/// and never reruns MoonDiff.
pub(all) struct SemanticReviewInput {
  old_name : String
  new_name : String
  old_source : String
  new_source : String
  mode : @moon_diff_provider.MoonDiffMode
  ignore_comments : Bool
  ignore_tests : Bool
  live_modified : SemanticReviewLiveDocument?
} derive(Eq, Debug)

///|
fn ReviewDiffMode::semantic_mode(
  self : ReviewDiffMode,
) -> @moon_diff_provider.MoonDiffMode? {
  match self {
    ReviewDiffCore => None
    ReviewDiffToken => Some(@moon_diff_provider.Token)
    ReviewDiffTree => Some(@moon_diff_provider.Tree)
  }
}

///|
/// Extract the visible semantic comparison from either a working-tree review
/// or Git history. Core, source mode, non-MoonBit files, and unavailable text
/// deliberately produce no input.
fn semantic_review_input(state : State, ctx : Ctx) -> SemanticReviewInput? {
  guard state.review_diff_mode.semantic_mode() is Some(mode) else {
    return None
  }
  let (old_name, new_name, old_source, new_source, live_modified) = match
    ctx.active_history_diff {
    Some(diff) => {
      guard supports_moon_diff(diff.path.0) &&
        state.history_docs.get(history_diff_key(diff)) is Some(history) &&
        history.original.text() is Some(old_source) &&
        history.modified.text() is Some(new_source) else {
        return None
      }
      (
        diff.original_path.unwrap_or(diff.path).0,
        diff.path.0,
        old_source,
        new_source,
        None,
      )
    }
    None => {
      guard ctx.active_file is Some(path) &&
        supports_moon_diff(path.0) &&
        state.docs.get(path) is Some(doc) &&
        doc.visible_diff() is Some((old_source, new_source)) else {
        return None
      }
      let live_modified = match doc.state {
        TabLoaded(absolute~, ..) => Some({ resource: absolute, path, })
        TabDeleted
        | TabLoading
        | TabBinary
        | TabOversized
        | TabReadFailed(_)
        | TabUnavailable(_) => None
      }
      (doc.name, doc.name, old_source, new_source, live_modified)
    }
  }
  Some({
    old_name,
    new_name,
    old_source,
    new_source,
    mode,
    ignore_comments: state.review_diff_ignore_comments,
    ignore_tests: state.review_diff_ignore_tests,
    live_modified,
  })
}

///|
/// Cache the expensive MoonDiff computation in panel state. The renderer and
/// imperative editor lifecycle consume the same immutable section plan.
fn State::sync_semantic_review(self : State, ctx : Ctx) -> State {
  let input = semantic_review_input(self, ctx)
  if input == self.semantic_review_input {
    return self
  }
  let plan = input.bind(input => {
    @moon_diff_provider.compute_sectioned_semantic_review_plan(
      input.old_source,
      input.new_source,
      input.mode,
      old_name=input.old_name,
      new_name=input.new_name,
      ignore_comments=input.ignore_comments,
      ignore_tests=input.ignore_tests,
    )
  })
  {
    ..self,
    semantic_review_input: input,
    semantic_review_plan: plan,
    semantic_review_collapsed: [],
  }
}

///|
fn semantic_range_label(
  range : @moon_diff_provider.SemanticReviewSourceRange,
) -> String {
  if range.line_count <= 1 {
    "L\{range.start_line_number}"
  } else {
    "L\{range.start_line_number}-\{range.start_line_number + range.line_count - 1}"
  }
}

///|
fn semantic_section_label(
  section : @moon_diff_provider.SemanticReviewSection,
) -> String {
  match (section.new_context, section.old_context, section.identity) {
    (Some(context), _, _) | (None, Some(context), _) => context
    (None, None, Some(identity)) => "Top-level #\{identity + 1}"
    (None, None, None) => "Whole file"
  }
}

///|
fn semantic_section_location(
  section : @moon_diff_provider.SemanticReviewSection,
) -> String {
  match (section.old_range, section.new_range) {
    (Some(old), Some(new)) =>
      "\{semantic_range_label(old)} → \{semantic_range_label(new)}"
    (Some(old), None) => semantic_range_label(old)
    (None, Some(new)) => semantic_range_label(new)
    (None, None) => ""
  }
}

///|
fn semantic_section_status(
  kind : @moon_diff_provider.SemanticReviewSectionKind,
) -> @html.Html {
  match kind {
    @moon_diff_provider.SemanticReviewSectionKind::Inserted =>
      @html.span(class="semantic-entry-status added", "A")
    @moon_diff_provider.SemanticReviewSectionKind::Deleted =>
      @html.span(class="semantic-entry-status deleted", "D")
    @moon_diff_provider.SemanticReviewSectionKind::Whole
    | @moon_diff_provider.SemanticReviewSectionKind::Matched => @html.nothing
  }
}

///|
fn semantic_editor_host_id(key : String) -> String {
  "semantic-diff-editor-\{key}"
}

///|
const SemanticReviewScrollWidthId = "semantic-review-scroll-width"

///|
/// Semantic fragments use side-specific schemes so the language registry can
/// expose current-checkout IDE actions on Modified without advertising them on
/// an Original revision that the host cannot answer for.
const SemanticReviewOriginalScheme = "openseek-semantic-diff-original"

///|
const SemanticReviewModifiedScheme = "openseek-semantic-diff-modified"

///|
priv enum SemanticReviewSide {
  SemanticReviewOriginal
  SemanticReviewModified
}

///|
fn semantic_fallback_notice(
  section : @moon_diff_provider.SemanticReviewSection,
  requested : @moon_diff_provider.MoonDiffMode,
) -> @html.Html {
  if section.fallbacks.is_empty() {
    return @html.nothing
  }
  let whole = section.kind
    is @moon_diff_provider.SemanticReviewSectionKind::Whole
  let tree = requested is @moon_diff_provider.Tree
  @html.div(
    class=if whole {
      "diff-notice fallback"
    } else {
      "diff-notice partial-fallback"
    },
    [
      @html.strong(
        if whole && tree {
          "Lexical fallback"
        } else if whole {
          "Sectioning fallback"
        } else if tree {
          "Section lexical fallback"
        } else {
          "Section diff fallback"
        },
      ),
      @html.span(section.fallbacks.join("; ")),
    ],
  )
}

///|
/// Rabbita owns only section chrome and this stable empty host. Source lines,
/// intraline spans, gutters, and alignment zones are all rendered by the real
/// DiffEditor mounted after paint.
fn semantic_section_view(
  dispatch : @cmd.Emit[Msg],
  section : @moon_diff_provider.SemanticReviewSection,
  requested : @moon_diff_provider.MoonDiffMode,
  collapsed : Bool,
) -> @html.Html {
  let label = semantic_section_label(section)
  let location = semantic_section_location(section)
  let content : Array[@html.Html] = [
    semantic_fallback_notice(section, requested),
    @html.div(
      class="semantic-entry-editor-parent",
      @html.div(
        attrs=@html.Attrs::build()
          .id(semantic_editor_host_id(section.key))
          .class("semantic-diff-editor-host")
          .data_set("semantic-section", section.key),
        ([] : Array[@html.Html]),
      ),
    ),
  ]
  @html.section(
    class=if collapsed {
      "semantic-diff-entry collapsed"
    } else {
      "semantic-diff-entry"
    },
    attrs=@html.Attrs::build().data_set("semantic-entry", section.key),
    [
      @html.header(
        class="semantic-entry-header",
        @html.button(
          type_="button",
          class="semantic-entry-header-content",
          title=if location.is_empty() {
            label
          } else {
            "\{label} · \{location}"
          },
          on_click=dispatch(SemanticReviewSectionToggled(section.key)),
          attrs=@html.Attrs::build()
            .aria_expanded((!collapsed).to_string())
            .aria_label(
              if collapsed {
                "Expand \{label}"
              } else {
                "Collapse \{label}"
              },
            ),
          [
            @html.span(
              class=if collapsed {
                "codicon codicon-chevron-right semantic-entry-chevron"
              } else {
                "codicon codicon-chevron-down semantic-entry-chevron"
              },
              "",
            ),
            @html.span(class="semantic-entry-file-icon", ""),
            @html.span(class="semantic-entry-path", [
              @html.span(class="semantic-entry-label", label),
              @html.span(class="semantic-entry-location", location),
            ]),
            semantic_section_status(section.kind),
          ],
        ),
      ),
      @html.div(class="semantic-entry-content", content),
    ],
  )
}

///|
fn semantic_empty_view(message : String) -> @html.Html {
  @html.div(class="semantic-empty", [@html.p(message)])
}

///|
fn semantic_status_empty_view(
  plan : @moon_diff_provider.SectionedSemanticReviewPlan,
  input : SemanticReviewInput,
) -> @html.Html? {
  match plan.status {
    @moon_diff_provider.SemanticReviewStatus::IgnoredOnly => {
      let subject = if input.ignore_comments && input.ignore_tests {
        "comments, blank lines, or test blocks"
      } else if input.ignore_tests {
        "test blocks"
      } else {
        "comments or blank lines"
      }
      Some(
        semantic_empty_view(
          "No changes besides ignored \{subject} were found. Turn off the relevant Ignore filter to view them.",
        ),
      )
    }
    @moon_diff_provider.SemanticReviewStatus::Identical =>
      Some(
        semantic_empty_view(
          if input.mode is @moon_diff_provider.Tree {
            "No structural changes found. Switch to Token or Core to inspect text."
          } else {
            "No token changes found."
          },
        ),
      )
    @moon_diff_provider.SemanticReviewStatus::NoStructuralChanges =>
      Some(
        semantic_empty_view(
          if input.mode is @moon_diff_provider.Tree {
            "No structural changes found. Switch to Token to view text changes."
          } else {
            "No declaration-owned token changes found. Switch to Core to inspect the complete file."
          },
        ),
      )
    @moon_diff_provider.SemanticReviewStatus::Changed
    | @moon_diff_provider.SemanticReviewStatus::Reordered => None
  }
}

///|
fn semantic_plan_view(
  dispatch : @cmd.Emit[Msg],
  plan : @moon_diff_provider.SectionedSemanticReviewPlan,
  input : SemanticReviewInput,
  collapsed : Array[String],
) -> @html.Html {
  if semantic_status_empty_view(plan, input) is Some(empty) {
    return empty
  }
  let sections : Map[String, @html.Html] = Map([])
  if plan.reordered {
    sections["reordered"] = @html.div(
      class="semantic-reorder",
      "Top-level declarations are reordered; each declaration keeps its own DiffEditor.",
    )
  }
  for section in plan.main_sections {
    sections["main:\{section.key}"] = semantic_section_view(
      dispatch,
      section,
      plan.requested,
      collapsed.contains(section.key),
    )
  }
  // Deleted identities cannot participate in the new-side order. Like VS
  // Code's multi-diff items, keep them in the same flat item list and use a D
  // status rather than introducing a second visual document hierarchy.
  for section in plan.deleted_sections {
    sections["deleted:\{section.key}"] = semantic_section_view(
      dispatch,
      section,
      plan.requested,
      collapsed.contains(section.key),
    )
  }
  if sections.is_empty() {
    semantic_empty_view(
      "No semantic section changes found. Switch to Core to inspect the complete file.",
    )
  } else {
    @html.div(class="semantic-document", sections)
  }
}

///|
/// Render section metadata and stable DiffEditor mount points. Source text is
/// intentionally absent from this HTML tree.
pub fn semantic_review_view(
  dispatch : @cmd.Emit[Msg],
  state : State,
) -> @html.Html {
  guard state.semantic_review_input is Some(input) else { return @html.nothing }
  guard state.semantic_review_plan is Some(plan) else {
    return @html.div(class="semantic-review", [
      semantic_empty_view(
        "The semantic result was invalid. Switch to Core to inspect the complete file.",
      ),
    ])
  }
  @html.div(
    class="semantic-review",
    attrs=@html.Attrs::build()
      .data_set(
        "mode",
        if input.mode is @moon_diff_provider.Token {
          "token"
        } else {
          "tree"
        },
      )
      .data_set(
        "layout",
        if state.review_diff_layout is ReviewSideBySide {
          "split"
        } else {
          "unified"
        },
      ),
    [
      semantic_plan_view(dispatch, plan, input, state.semantic_review_collapsed),
      // VS Code's MultiDiffEditor owns one horizontal scroll extent. The
      // imperative lifecycle sizes this otherwise invisible element from the
      // widest local DiffEditor and mirrors the outer scrollLeft into all
      // entries.
      @html.div(
        attrs=@html.Attrs::build()
          .id(SemanticReviewScrollWidthId)
          .class("semantic-review-scroll-width")
          .aria_hidden("true"),
        ([] : Array[@html.Html]),
      ),
    ],
  )
}

///|
priv struct SemanticReviewEditorHost {
  section : @moon_diff_provider.SemanticReviewSection
  old_name : String
  new_name : String
  live_modified : SemanticReviewLiveDocument?
  host : @dom.Element
  editor : @viewer.DiffEditor
  provider : @moon_diff_provider.MoonFragmentDiffProvider?
  subscription : @common.Disposable
}

///|
let semantic_review_editors : Map[String, SemanticReviewEditorHost] = Map([])

///|
fn update_semantic_review_scroll_width() -> Unit {
  guard @dom.document().get_element_by_id(SemanticReviewHostId).to_option()
    is Some(host) &&
    @dom.document().get_element_by_id(SemanticReviewScrollWidthId).to_option()
    is Some(spacer) else {
    return
  }
  let mut max_scroll = 0.0
  for _, entry in semantic_review_editors {
    if @base_browser.element_is_connected(entry.host) {
      max_scroll = max_scroll.max(entry.editor.get_max_scroll_left())
    }
  }
  @base_browser.set_style_property(
    spacer,
    "width",
    "\{(host.get_client_width() + max_scroll).ceil()}px",
  )
  sync_semantic_review_scroll_left(host.get_scroll_left())
}

///|
/// Project the single outer MultiDiffEditor scrollbar into every item. This
/// mirrors VS Code's `VirtualizedViewItem.setScrollLeft` without exposing each
/// DiffEditor's own horizontal scrollbar.
fn sync_semantic_review_scroll_left(scroll_left : Double) -> Unit {
  // A native overflow element supplies the one visible scrollbar, but VS
  // Code's SmoothScrollableElement does not translate the MultiDiff item DOM.
  // Counter the browser's native translation, then project the offset into
  // every DiffEditor so headers stay put and code moves exactly once.
  if @dom.document().get_element_by_id(SemanticReviewHostId).to_option()
    is Some(host) &&
    host.query_selector(".semantic-document") is Some(document) {
    @base_browser.set_style_property(
      document,
      "transform",
      "translateX(\{scroll_left}px)",
    )
  }
  for _, entry in semantic_review_editors {
    entry.editor.set_scroll_left(scroll_left)
  }
}

///|
fn semantic_diff_options(
  layout : ReviewDiffLayout,
) -> @viewer.DiffEditorOptions {
  @viewer.DiffEditorOptions(
    editor_options=current_diff_pane_options(),
    layout=match layout {
      ReviewSideBySide => @viewer.SideBySide
      ReviewInline => @viewer.Inline
    },
    automatic_inline=false,
    sash_enabled=true,
    diff_word_wrap=@viewer.Off,
    overview_ruler=false,
    render_indicators=true,
    render_markdown_comments=false,
    handle_mouse_wheel=false,
    // Semantic diff items must expose comment changes as source rows. Rich
    // documentation replaces and hides those rows, which makes a comment-only
    // MoonDiff section look unchanged even though its fragment is correct.
    // The outer MultiDiff scroll plane owns wheel input, matching VS Code's
    // per-item `handleMouseWheel: false` configuration.
  )
}

///|
fn semantic_model_uri(side : SemanticReviewSide, key : String) -> @common.Uri? {
  let uri = @common.Uri::from(
    scheme=match side {
      SemanticReviewOriginal => SemanticReviewOriginalScheme
      SemanticReviewModified => SemanticReviewModifiedScheme
    },
    path="/\{key}.mbt",
  ) catch {
    _ => return None
  }
  Some(uri)
}

///|
/// The semantic model's line numbers are local to one MoonDiff section. Keep
/// the projection explicit instead of making a fragment impersonate the full
/// working file: the host IDE receives the real path and global line number,
/// while the editor continues rendering the section-local diff document.
priv struct SemanticModifiedModelProjection {
  resource : @common.Uri
  path : @pathx.Relative
  line_offset : Int
}

///|
fn @moon_diff_provider.SemanticReviewSection::modified_line_offset(
  self : @moon_diff_provider.SemanticReviewSection,
) -> Int? {
  match (self.kind, self.new_range) {
    (@moon_diff_provider.SemanticReviewSectionKind::Whole, _) => Some(0)
    (_, Some(range)) if range.start_line_number > 0 =>
      Some(range.start_line_number - 1)
    _ => None
  }
}

///|
/// Resolve only the Modified model of a currently mounted working-tree
/// section. Original and historical models intentionally return `None`.
fn semantic_modified_model_projection(
  model : @model.TextModel,
) -> SemanticModifiedModelProjection? {
  for _, entry in semantic_review_editors {
    match
      (
        entry.live_modified,
        entry.section.modified_line_offset(),
        entry.editor.get_model(),
      ) {
      (Some(live), Some(line_offset), Some(pair)) if pair.modified.same(model) =>
        return Some({ resource: live.resource, path: live.path, line_offset, })
      _ => ()
    }
  }
  None
}

///|
/// Project full-file diagnostics into one section-local Modified model. A
/// diagnostic outside the section is absent; one crossing a section boundary
/// is clipped to the visible model before `TextModel::validate_range` clamps
/// UTF-16 columns against the actual fragment text.
fn project_semantic_modified_diagnostics(
  diagnostics : ArrayView[@language.Diagnostic],
  model : @model.TextModel,
  line_offset : Int,
) -> Array[@language.Diagnostic] {
  let projected : Array[@language.Diagnostic] = []
  let line_count = model.get_line_count()
  for diagnostic in diagnostics {
    let local_start = diagnostic.range.start_line_number - line_offset
    let local_end = diagnostic.range.end_line_number - line_offset
    if local_end < 1 || local_start > line_count {
      continue
    }
    let start_line = local_start.max(1)
    let end_line = local_end.min(line_count)
    let range = model.validate_range(
      @common.Range(
        start_line,
        if local_start < 1 {
          1
        } else {
          diagnostic.range.start_column
        },
        end_line,
        if local_end > line_count {
          model.get_line_max_column(end_line)
        } else {
          diagnostic.range.end_column
        },
      ),
    )
    projected.push({ ..diagnostic, range, })
  }
  projected
}

///|
/// Seed or refresh the synthetic Modified resource from the diagnostics
/// already owned by the live working model. The shared marker service then
/// drives the ordinary diff-pane marker contribution without teaching the
/// reusable Viewer about OpenSeek's fragment projection.
fn sync_semantic_modified_diagnostics(
  services : DesktopViewerServices,
  live_modified : SemanticReviewLiveDocument?,
  section : @moon_diff_provider.SemanticReviewSection,
  model : @model.TextModel,
) -> Unit {
  guard live_modified is Some(live) &&
    section.modified_line_offset() is Some(line_offset) else {
    services.markers.remove_owner_resource(DiagnosticsOwner, model.uri)
    return
  }
  let diagnostics = services.markers.diagnostics_for_resource(live.resource)
  services.markers.set_diagnostics(
    DiagnosticsOwner,
    model.uri,
    project_semantic_modified_diagnostics(diagnostics, model, line_offset),
  )
}

///|
/// Refresh every mounted section backed by `resource` after the live LSP
/// diagnostic batch changes.
fn refresh_semantic_modified_diagnostics(resource : @common.Uri) -> Unit {
  guard viewer_state.services is Some(services) else { return }
  for _, entry in semantic_review_editors {
    guard entry.live_modified is Some(live) &&
      live.resource == resource &&
      entry.editor.get_model() is Some(pair) else {
      continue
    }
    sync_semantic_modified_diagnostics(
      services,
      entry.live_modified,
      entry.section,
      pair.modified,
    )
  }
}

///|
fn semantic_estimated_height(
  section : @moon_diff_provider.SemanticReviewSection,
  layout : ReviewDiffLayout,
) -> Double {
  let old_lines = section.original_source.split("\n").length()
  let new_lines = section.modified_source.split("\n").length()
  let lines = match layout {
    ReviewSideBySide => old_lines.max(new_lines)
    ReviewInline => old_lines + new_lines
  }
  (lines.max(1).to_double() * 20.0 + 8.0).max(40.0)
}

///|
fn resize_semantic_review_editor(key : String) -> Unit {
  guard semantic_review_editors.get(key) is Some(entry) &&
    @base_browser.element_is_connected(entry.host) else {
    return
  }
  let content_height = entry.editor.get_content_height()
  if content_height <= 0.0 {
    return
  }
  let height = (content_height.ceil() + 2.0).max(40.0)
  let css_height = "\{height}px"
  if @base_browser.element_style_value(entry.host, "height") != css_height {
    @base_browser.set_style_property(entry.host, "height", css_height)
    entry.editor.layout()
  }
  update_semantic_review_scroll_width()
}

///|
fn schedule_semantic_review_editor_resize(key : String) -> Unit {
  @dom.window().request_animation_frame(_ => {
    resize_semantic_review_editor(key)
    @dom.window().request_animation_frame(_ => {
      resize_semantic_review_editor(key)
    })
    |> ignore
  })
  |> ignore
}

///|
fn dispose_semantic_review_editor(entry : SemanticReviewEditorHost) -> Unit {
  entry.subscription.dispose()
  match entry.editor.set_model(None) {
    Some(previous) => {
      if viewer_state.services is Some(services) {
        services.markers.remove_owner_resource(
          DiagnosticsOwner,
          previous.modified.uri,
        )
      }
      dispose_diff_comparison_models(previous)
    }
    None => ()
  }
  entry.editor.dispose()
  // Keep the concrete fragment provider alive until after DiffEditor has
  // disposed its ViewModel and provider subscription.
  match entry.provider {
    Some(_) => ()
    None => ()
  }
}

///|
fn create_semantic_review_editor(
  input : SemanticReviewInput,
  section : @moon_diff_provider.SemanticReviewSection,
  layout : ReviewDiffLayout,
  host : @dom.Element,
) -> SemanticReviewEditorHost? {
  guard semantic_model_uri(SemanticReviewOriginal, section.key)
    is Some(original_uri) &&
    semantic_model_uri(SemanticReviewModified, section.key)
    is Some(modified_uri) &&
    viewer_state.services is Some(services) else {
    return None
  }
  viewer_state.version = viewer_state.version + 1
  let version = viewer_state.version
  let original = @model.TextModel(
    original_uri,
    input.old_name,
    "moonbit",
    version,
    "semantic-old-v\{version}",
    section.original_source,
  )
  let modified = @model.TextModel(
    modified_uri,
    input.new_name,
    "moonbit",
    version,
    "semantic-new-v\{version}",
    section.modified_source,
  )
  @base_browser.set_style_property(
    host,
    "height",
    "\{semantic_estimated_height(section, layout)}px",
  )
  let (editor, provider) = match section.diff {
    @moon_diff_provider.SemanticReviewDiff::Core =>
      (
        @viewer.DiffEditor::create(
          host,
          services=services.viewer_services,
          options=semantic_diff_options(layout),
        ),
        None,
      )
    @moon_diff_provider.SemanticReviewDiff::Fragment(document) => {
      let provider = @moon_diff_provider.MoonFragmentDiffProvider(document)
      (
        @viewer.DiffEditor::create(
          host,
          services=services.viewer_services,
          options=semantic_diff_options(layout),
          provider=provider.as_document_diff_provider(),
        ),
        Some(provider),
      )
    }
  }
  let key = section.key
  let subscription = editor.on_did_update_diff(() => {
    schedule_semantic_review_editor_resize(key)
  })
  editor.set_model(Some(@viewer.DiffEditorModel(original, modified))) |> ignore
  sync_semantic_modified_diagnostics(
    services,
    input.live_modified,
    section,
    modified,
  )
  // Each VS Code multi-diff item opens on its own first change. Without this,
  // a comment-only section can initially show only the unchanged declaration
  // body below the changed documentation comment.
  editor.reveal_first_diff()
  Some({
    section,
    old_name: input.old_name,
    new_name: input.new_name,
    live_modified: input.live_modified,
    host,
    editor,
    provider,
    subscription,
  })
}

///|
fn semantic_sections(
  plan : @moon_diff_provider.SectionedSemanticReviewPlan?,
) -> Array[@moon_diff_provider.SemanticReviewSection] {
  guard plan is Some(plan) else { return [] }
  let sections = plan.main_sections.copy()
  sections.append(plan.deleted_sections)
  sections
}

///|
fn layout_semantic_review_editors() -> Unit {
  for key, entry in semantic_review_editors {
    entry.editor.layout()
    schedule_semantic_review_editor_resize(key)
  }
  update_semantic_review_scroll_width()
}

///|
fn update_semantic_review_editor_layout(layout : ReviewDiffLayout) -> Unit {
  for key, entry in semantic_review_editors {
    entry.editor.update_options(semantic_diff_options(layout))
    entry.editor.layout()
    schedule_semantic_review_editor_resize(key)
  }
  update_semantic_review_scroll_width()
}

///|
fn refresh_semantic_review_editor_options() -> Unit {
  for key, entry in semantic_review_editors {
    let layout = match entry.editor.get_layout() {
      @viewer.SideBySide => ReviewSideBySide
      @viewer.Inline => ReviewInline
    }
    entry.editor.update_options(semantic_diff_options(layout))
    entry.editor.layout()
    schedule_semantic_review_editor_resize(key)
  }
  update_semantic_review_scroll_width()
}

///|
fn clear_semantic_review_editors() -> Unit {
  let keys = semantic_review_editors.to_array().map(pair => pair.0)
  for key in keys {
    if semantic_review_editors.get(key) is Some(entry) {
      dispose_semantic_review_editor(entry)
      semantic_review_editors.remove(key)
    }
  }
  update_semantic_review_scroll_width()
}

///|
/// Reconcile section widgets after Rabbita has committed their keyed hosts.
/// Unchanged sections retain their editor models, selection, and scroll state.
fn sync_semantic_review_editors(state : State) -> @cmd.Cmd {
  @cmd.custom_cmd(
    _scheduler => {
      guard state.semantic_review_input is Some(input) else {
        clear_semantic_review_editors()
        return
      }
      let desired = semantic_sections(state.semantic_review_plan)
      let desired_keys = desired.map(section => section.key)
      let stale = semantic_review_editors
        .to_array()
        .map(pair => pair.0)
        .filter(key => !desired_keys.contains(key))
      for key in stale {
        if semantic_review_editors.get(key) is Some(entry) {
          dispose_semantic_review_editor(entry)
          semantic_review_editors.remove(key)
        }
      }
      for section in desired {
        let key = section.key
        guard @dom.document()
          .get_element_by_id(semantic_editor_host_id(key))
          .to_option()
          is Some(host) else {
          if semantic_review_editors.get(key) is Some(previous) {
            dispose_semantic_review_editor(previous)
            semantic_review_editors.remove(key)
          }
          continue
        }
        let reusable = semantic_review_editors
          .get(key)
          .map(previous => {
            previous.section == section &&
            previous.old_name == input.old_name &&
            previous.new_name == input.new_name &&
            previous.live_modified == input.live_modified &&
            previous.host.is_same_node(host.as_node())
          })
          .unwrap_or(false)
        if reusable {
          let entry = semantic_review_editors[key]
          entry.editor.update_options(
            semantic_diff_options(state.review_diff_layout),
          )
          entry.editor.layout()
          schedule_semantic_review_editor_resize(key)
          continue
        }
        if semantic_review_editors.get(key) is Some(previous) {
          dispose_semantic_review_editor(previous)
          semantic_review_editors.remove(key)
        }
        if create_semantic_review_editor(
            input,
            section,
            state.review_diff_layout,
            host,
          )
          is Some(entry) {
          semantic_review_editors[key] = entry
          schedule_semantic_review_editor_resize(key)
        }
      }
      update_semantic_review_scroll_width()
    },
    kind=@cmd.after_render,
  )
}

///|
pub extend SemanticReviewInput with Eq::{equal, not_equal}

///|
pub extend SemanticReviewInput with Debug::{to_repr}
