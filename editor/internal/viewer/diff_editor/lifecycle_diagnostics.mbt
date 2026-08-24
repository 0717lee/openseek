///|
/// Internal runtime evidence for the composite widget's construction and
/// teardown invariants. The public editor facade deliberately does not forward
/// this diagnostic.
pub(all) struct DiffEditorWidgetLifecycleSnapshot {
  kernel_count : Int
  original_kernel_id : String
  modified_kernel_id : String
  kernels_are_distinct : Bool
  view_model_count : Int
  widget_disposed : Bool
  dispose_pass_count : Int
  original_kernel_disposed : Bool
  modified_kernel_disposed : Bool
  view_model_disposed : Bool
  model_pair_is_committing : Bool
  committed_model_generation : Int
  overview_ruler_present : Bool
  overview_ruler_disposed : Bool
  inline_deleted_zone_count : Int
  resize_observer_present : Bool
  resize_observer_disposed : Bool
  after_render_waiter_count : Int
  after_render_remaining : Int
  view_model_pending_scheduler_count : Int
  lifetime_subscription_count : Int
}

///|
pub fn DiffEditorWidget::lifecycle_snapshot(
  self : DiffEditorWidget,
) -> DiffEditorWidgetLifecycleSnapshot {
  let original_kernel_id = self.editors.original.get_id()
  let modified_kernel_id = self.editors.modified.get_id()
  let overview_ruler_disposed = match
    (self.original_overview_ruler, self.modified_overview_ruler) {
    (Some(original), Some(modified)) =>
      original.is_disposed() && modified.is_disposed()
    (None, None) => self.overview_ruler_disposed
    _ => false
  }
  let view_model_pending_scheduler_count = (if self.view_model.immediate.is_scheduled() {
      1
    } else {
      0
    }) +
    (if self.view_model.content_debounce.is_scheduled() { 1 } else { 0 })
  {
    kernel_count: 2,
    original_kernel_id,
    modified_kernel_id,
    kernels_are_distinct: original_kernel_id != modified_kernel_id,
    view_model_count: 1,
    widget_disposed: self.disposed,
    dispose_pass_count: self.dispose_pass_count,
    original_kernel_disposed: self.editors.original.is_disposed(),
    modified_kernel_disposed: self.editors.modified.is_disposed(),
    view_model_disposed: self.view_model.disposed,
    model_pair_is_committing: self.editors.is_committing_model_pair(),
    committed_model_generation: self.editors.committed_model_generation(),
    overview_ruler_present: self.original_overview_ruler is Some(_) &&
    self.modified_overview_ruler is Some(_),
    overview_ruler_disposed,
    inline_deleted_zone_count: self.inline_deleted_zones.length(),
    resize_observer_present: self.resize_observer is Some(_),
    resize_observer_disposed: self.resize_observer_disposed,
    after_render_waiter_count: self.layout_render_waiters.length(),
    after_render_remaining: self.layout_render_remaining,
    view_model_pending_scheduler_count,
    lifetime_subscription_count: self.lifetime.length(),
  }
}
