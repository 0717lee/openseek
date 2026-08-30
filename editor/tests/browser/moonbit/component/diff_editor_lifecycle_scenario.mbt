///|
fn diff_editor_lifecycle_model(
  name : String,
  content : String,
) -> @model.TextModel {
  let uri = @base_common.Uri::from(
    scheme="memory",
    authority="diff-lifecycle",
    path="/\{name}.mbt",
  ) catch {
    _ => abort("invalid lifecycle fixture URI")
  }
  TextModel(uri, "\{name}.mbt", "moonbit", 1, "diff-lifecycle-\{name}", content)
}

///|
fn diff_editor_lifecycle_numbered_lines(start : Int, end : Int) -> String {
  let lines : Array[String] = []
  for line in start..<end {
    lines.push("stable line \{line}")
  }
  lines.join("\n")
}

///|
priv suberror DiffLifecycleProviderError {
  ComputeFailed
}

///|
priv struct FailingDiffLifecycleProvider {
  marker : Unit
}

///|
fn FailingDiffLifecycleProvider::FailingDiffLifecycleProvider() -> FailingDiffLifecycleProvider {
  { marker: (), }
}

///|
impl @diff.DocumentDiffProvider for FailingDiffLifecycleProvider with fn compute_diff(
  self,
  _original,
  _modified,
  _options,
) {
  self.marker |> ignore
  raise DiffLifecycleProviderError::ComputeFailed
}

///|
impl @diff.DocumentDiffProvider for FailingDiffLifecycleProvider with fn on_did_change(
  _self,
  _listener,
) {
  @base_common.Disposable::from(() => ())
}

///|
priv struct InvalidDiffLifecycleProvider {
  marker : Unit
}

///|
fn InvalidDiffLifecycleProvider::InvalidDiffLifecycleProvider() -> InvalidDiffLifecycleProvider {
  { marker: (), }
}

///|
impl @diff.DocumentDiffProvider for InvalidDiffLifecycleProvider with fn compute_diff(
  self,
  _original,
  _modified,
  _options,
) {
  self.marker |> ignore
  {
    changes: [DetailedLineRangeMapping(LineRange(0, 2), LineRange(1, 2), None)],
    additional_alignments: [],
  }
}

///|
impl @diff.DocumentDiffProvider for InvalidDiffLifecycleProvider with fn on_did_change(
  _self,
  _listener,
) {
  @base_common.Disposable::from(() => ())
}

///|
fn diff_editor_lifecycle_snapshot_json(
  widget : @diff_editor.DiffEditorWidget,
) -> String {
  let snapshot = widget.lifecycle_snapshot()
  Json({
    "kernelCount": snapshot.kernel_count.to_json(),
    "originalKernelId": snapshot.original_kernel_id.to_json(),
    "modifiedKernelId": snapshot.modified_kernel_id.to_json(),
    "kernelsAreDistinct": snapshot.kernels_are_distinct.to_json(),
    "viewModelCount": snapshot.view_model_count.to_json(),
    "widgetDisposed": snapshot.widget_disposed.to_json(),
    "disposePassCount": snapshot.dispose_pass_count.to_json(),
    "originalKernelDisposed": snapshot.original_kernel_disposed.to_json(),
    "modifiedKernelDisposed": snapshot.modified_kernel_disposed.to_json(),
    "viewModelDisposed": snapshot.view_model_disposed.to_json(),
    "modelPairIsCommitting": snapshot.model_pair_is_committing.to_json(),
    "committedModelGeneration": snapshot.committed_model_generation.to_json(),
    "overviewRulerPresent": snapshot.overview_ruler_present.to_json(),
    "overviewRulerDisposed": snapshot.overview_ruler_disposed.to_json(),
    "inlineDeletedZoneCount": snapshot.inline_deleted_zone_count.to_json(),
    "resizeObserverPresent": snapshot.resize_observer_present.to_json(),
    "resizeObserverDisposed": snapshot.resize_observer_disposed.to_json(),
    "afterRenderWaiterCount": snapshot.after_render_waiter_count.to_json(),
    "afterRenderRemaining": snapshot.after_render_remaining.to_json(),
    "viewModelPendingSchedulerCount": snapshot.view_model_pending_scheduler_count.to_json(),
    "diffUpToDate": snapshot.diff_up_to_date.to_json(),
    "lifetimeSubscriptionCount": snapshot.lifetime_subscription_count.to_json(),
  }).stringify()
}

///|
fn run_diff_editor_lifecycle_test() -> Unit {
  let document = @rdom.document()
  guard document.query_selector("#app").to_option() is Some(app) else {
    abort("missing #app mount point")
  }
  let host = document.create_element("div")
  host.set_attribute("class", "diff-lifecycle-host")
  host.set_attribute("style", "width:700px;height:420px;")
  app.append_child(host.as_node())
  let provider = @diff.CoreDocumentDiffProvider()
  let provider_object : &@diff.DocumentDiffProvider = provider
  let failing_provider = FailingDiffLifecycleProvider::FailingDiffLifecycleProvider()
  let failing_provider_object : &@diff.DocumentDiffProvider = failing_provider
  let invalid_provider = InvalidDiffLifecycleProvider::InvalidDiffLifecycleProvider()
  let invalid_provider_object : &@diff.DocumentDiffProvider = invalid_provider
  let widget = @diff_editor.DiffEditorWidget::create(
    host,
    provider_object,
    editor_options=@code_widget.CodeEditorOptions::default()
      .with_soft_wrap(true)
      .with_line_numbers_min_chars(1),
    options=DiffEditorOptions(layout=Inline, automatic_inline=false),
  )
  let original = diff_editor_lifecycle_model(
    "original",
    ("deleted line " + "x".repeat(400) + "\n").repeat(260) +
    "shared tail\n".repeat(120) +
    "end",
  )
  let modified = diff_editor_lifecycle_model(
    "modified",
    "shared tail\n".repeat(120) + "end",
  )
  let digit_original = diff_editor_lifecycle_model(
    "digit-original",
    "digit line\n".repeat(8) + "digit line",
  )
  let digit_modified = diff_editor_lifecycle_model(
    "digit-modified",
    "digit line\n".repeat(8) + "digit line",
  )
  let indicator_original = diff_editor_lifecycle_model(
    "indicator-original", "shared head\nold value\nshared tail",
  )
  let indicator_modified = diff_editor_lifecycle_model(
    "indicator-modified", "shared head\nnew value\nshared tail",
  )
  let identical_original = diff_editor_lifecycle_model(
    "identical-original", "identical 1\nidentical 2\nidentical 3\nidentical 4\nidentical 5\nidentical 6\nidentical 7\nidentical 8",
  )
  let identical_modified = diff_editor_lifecycle_model(
    "identical-modified", "identical 1\nidentical 2\nidentical 3\nidentical 4\nidentical 5\nidentical 6\nidentical 7\nidentical 8",
  )
  let late_prefix = diff_editor_lifecycle_numbered_lines(1, 121) + "\n"
  let late_middle = "\n" + diff_editor_lifecycle_numbered_lines(122, 190) + "\n"
  let late_suffix = "\n" + diff_editor_lifecycle_numbered_lines(191, 241)
  let late_original = diff_editor_lifecycle_model(
    "late-original",
    late_prefix +
    "old first hunk" +
    late_middle +
    "old second hunk" +
    late_suffix,
  )
  let late_modified = diff_editor_lifecycle_model(
    "late-modified",
    late_prefix +
    "new first hunk" +
    late_middle +
    "new second hunk" +
    late_suffix,
  )
  let first_line_middle = "\n" +
    diff_editor_lifecycle_numbered_lines(2, 100) +
    "\n"
  let first_line_suffix = "\n" + diff_editor_lifecycle_numbered_lines(101, 141)
  let first_line_original = diff_editor_lifecycle_model(
    "first-line-original",
    "old first hunk at line 1" +
    first_line_middle +
    "old second hunk at line 100" +
    first_line_suffix,
  )
  let first_line_modified = diff_editor_lifecycle_model(
    "first-line-modified",
    "new first hunk at line 1" +
    first_line_middle +
    "new second hunk at line 100" +
    first_line_suffix,
  )
  widget.set_model(Some({ original, modified, })) |> ignore
  install_diff_editor_lifecycle_controls(
    () => diff_editor_lifecycle_snapshot_json(widget),
    fixture => {
      let pair : @diff_editor.DiffEditorModelData = match fixture {
        "digits" => { original: digit_original, modified: digit_modified, }
        "indicators" =>
          { original: indicator_original, modified: indicator_modified, }
        "identical" =>
          { original: identical_original, modified: identical_modified, }
        "late" => { original: late_original, modified: late_modified, }
        "first-line" =>
          { original: first_line_original, modified: first_line_modified, }
        _ => { original, modified, }
      }
      widget.set_model(Some(pair)) |> ignore
    },
    line_count => {
      let content = "digit line\n".repeat((line_count - 1).max(0)) +
        "digit line"
      digit_original.set_value(content)
      digit_modified.set_value(content)
    },
    (layout_name, render_indicators, font_size) => {
      let layout : @diff_editor.DiffEditorLayout = if layout_name == "split" {
        SideBySide
      } else {
        Inline
      }
      widget.update_options(
        @code_widget.CodeEditorOptions::default()
        .with_soft_wrap(true)
        .with_line_numbers_min_chars(1)
        .with_font_size(font_size),
        DiffEditorOptions(layout~, automatic_inline=false, render_indicators~),
      )
    },
    provider_kind => {
      match provider_kind {
        "provider" => widget.set_diff_provider(failing_provider_object)
        "validator" => widget.set_diff_provider(invalid_provider_object)
        _ => widget.set_diff_provider(provider_object)
      }
    },
    attached => {
      widget.set_model(
        if attached {
          Some({ original, modified, })
        } else {
          None
        },
      )
      |> ignore
    },
    () => widget.reveal_first_diff(),
    () => widget.dispose(),
    () => {
      original.dispose()
      modified.dispose()
      digit_original.dispose()
      digit_modified.dispose()
      indicator_original.dispose()
      indicator_modified.dispose()
      identical_original.dispose()
      identical_modified.dispose()
      late_original.dispose()
      late_modified.dispose()
      first_line_original.dispose()
      first_line_modified.dispose()
    },
  )
}

///|
extern "js" fn install_diff_editor_lifecycle_controls(
  snapshot : () -> String,
  set_fixture : (String) -> Unit,
  set_digit_line_count : (Int) -> Unit,
  set_options : (String, Bool, Double) -> Unit,
  set_provider : (String) -> Unit,
  set_model_attached : (Bool) -> Unit,
  reveal_first_diff : () -> Unit,
  dispose : () -> Unit,
  dispose_models : () -> Unit,
) -> Unit =
  #| (snapshot, setFixture, setDigitLineCount, setOptions, setProvider, setModelAttached, revealFirstDiff, dispose, disposeModels) => {
  #|   globalThis.__diffEditorLifecycleControls = Object.freeze({
  #|     snapshot() { return JSON.parse(snapshot()); },
  #|     set_fixture: setFixture,
  #|     set_digit_line_count: setDigitLineCount,
  #|     set_options: setOptions,
  #|     set_provider: setProvider,
  #|     set_model_attached: setModelAttached,
  #|     reveal_first_diff: revealFirstDiff,
  #|     dispose,
  #|     dispose_models: disposeModels,
  #|   });
  #| }
