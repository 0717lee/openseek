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
fn diff_editor_lifecycle_snapshot_json(
  widget : @diff_editor.DiffEditorWidget,
) -> String {
  let snapshot = widget.lifecycle_snapshot()
  Json::object({
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
  let widget = @diff_editor.DiffEditorWidget::create(
    host,
    provider_object,
    editor_options=@code_widget.CodeEditorOptions::default(),
    options=DiffEditorOptions(layout=Inline, automatic_inline=false),
  )
  let original = diff_editor_lifecycle_model(
    "original",
    "deleted line\n".repeat(260) + "shared tail",
  )
  let modified = diff_editor_lifecycle_model("modified", "shared tail")
  widget.set_model(Some({ original, modified })) |> ignore
  install_diff_editor_lifecycle_controls(
    () => diff_editor_lifecycle_snapshot_json(widget),
    () => widget.dispose(),
    () => {
      original.dispose()
      modified.dispose()
    },
  )
}

///|
extern "js" fn install_diff_editor_lifecycle_controls(
  snapshot : () -> String,
  dispose : () -> Unit,
  dispose_models : () -> Unit,
) -> Unit =
  #| (snapshot, dispose, disposeModels) => {
  #|   globalThis.__diffEditorLifecycleControls = Object.freeze({
  #|     snapshot() { return JSON.parse(snapshot()); },
  #|     dispose,
  #|     dispose_models: disposeModels,
  #|   });
  #| }
