///|
/// Opaque service capabilities shared by the embeddable Viewer and its
/// feature controllers. Concrete host backings never cross this root facade.
///
/// The hover participant registry is *not* held here: it is a free global in
/// `internal/viewer/contrib/hover` populated by that feature's contribution,
/// mirroring Monaco's `HoverParticipantRegistry`. `Viewer::request_hover`
/// projects these services into a `@hover.HoverParticipantServices` when it
/// builds a hover computer.
pub struct ViewerServices {
  priv languages : @languages.LanguageHandle
  priv marker_decorations : @markers.MarkerDecorationsHandle
  priv agent_feedback : @agent_feedback_api.AgentFeedbackHandle
  priv quick_diff : @quick_diff_api.QuickDiffHandle
  priv log_service : @log.LogHandle
  /// Concrete defaults owned by this exact bundle. Caller-supplied handles
  /// never appear here and therefore can never be disposed by the bundle.
  priv owned_marker_decorations : @markers.MarkerDecorationsService?
  priv owned_markers : @markers.MarkerService?
  priv owned_agent_feedback : @agent_feedback.AgentFeedbackService?
  priv mut disposed : Bool
}

///|
/// Creates a service bundle. Passing the returned value explicitly to a
/// Viewer keeps ownership with the caller, allowing multiple Viewers to share
/// model registrations and host state. Omitting the Viewer constructor's
/// `services` argument creates the same shape internally and transfers only
/// that internal bundle's lifetime to the Viewer.
#alias(new, deprecated)
pub fn ViewerServices::ViewerServices(
  languages? : @languages.LanguageHandle,
  markers? : @markers.MarkerDecorationsSource,
  agent_feedback? : @agent_feedback_api.AgentFeedbackHandle,
  quick_diff? : @quick_diff_api.QuickDiffHandle,
  log_service? : @log.LogHandle,
) -> ViewerServices {
  let log_service = match log_service {
    Some(handle) => handle
    None => @log.LogService().log_handle()
  }
  let languages = match languages {
    Some(handle) => handle
    None => @languages.default_languages().language_handle(log_service)
  }
  let (marker_decorations, owned_marker_decorations, owned_markers) = match
    markers {
    None => {
      // The change event merges same-tick updates on a real microtask here
      // (Monaco's `MicrotaskEmitter`); headless tests use the sync default.
      let store = @markers.MarkerService(schedule=@base_browser.queue_microtask)
      let decorations = @markers.MarkerDecorationsService(
        store.marker_service_handle(),
      )
      (decorations.marker_decorations_handle(), Some(decorations), Some(store))
    }
    Some(MarkerStore(store)) => {
      let decorations = @markers.MarkerDecorationsService(store)
      (decorations.marker_decorations_handle(), Some(decorations), None)
    }
    Some(Decorations(decorations)) => (decorations, None, None)
  }
  let (agent_feedback, owned_agent_feedback) = match agent_feedback {
    Some(handle) => (handle, None)
    None => {
      let service = @agent_feedback.AgentFeedbackService()
      (service.agent_feedback_handle(), Some(service))
    }
  }
  let quick_diff = match quick_diff {
    Some(handle) => handle
    None => @quick_diff.QuickDiffService().quick_diff_handle()
  }
  {
    languages,
    marker_decorations,
    agent_feedback,
    quick_diff,
    log_service,
    owned_marker_decorations,
    owned_markers,
    owned_agent_feedback,
    disposed: false,
  }
}

///|
/// Releases only backings created by this bundle, in the fixed
/// marker-decorations → marker-store → feedback order. The operation is
/// idempotent and never disposes a caller-supplied handle or captured backing.
pub fn ViewerServices::dispose(self : ViewerServices) -> Unit {
  if self.disposed {
    return
  }
  self.disposed = true
  match self.owned_marker_decorations {
    Some(service) => service.dispose()
    None => ()
  }
  match self.owned_markers {
    Some(service) => service.dispose()
    None => ()
  }
  match self.owned_agent_feedback {
    Some(service) => service.dispose()
    None => ()
  }
}

///|
/// Services an embedding application owns when it needs to feed diagnostics
/// and file comments into a Viewer. The concrete editor services remain
/// private; applications operate through the methods below and pass
/// `viewer_services()` to `Viewer::create`.
pub struct EmbeddedViewerServices {
  priv services : ViewerServices
  priv markers : @markers.MarkerService
  priv agent_feedback : @agent_feedback.AgentFeedbackService
  priv mut disposed : Bool
}

///|
/// Creates one application-owned service set for an embedded Viewer.
#alias(new, deprecated)
pub fn EmbeddedViewerServices::EmbeddedViewerServices() -> EmbeddedViewerServices {
  let markers = @markers.MarkerService(schedule=@base_browser.queue_microtask)
  let agent_feedback = @agent_feedback.AgentFeedbackService()
  let services = ViewerServices(
    markers=MarkerStore(markers.marker_service_handle()),
    agent_feedback=agent_feedback.agent_feedback_handle(),
  )
  { services, markers, agent_feedback, disposed: false }
}

///|
/// Returns the service bundle to pass to `Viewer::create`.
pub fn EmbeddedViewerServices::viewer_services(
  self : EmbeddedViewerServices,
) -> ViewerServices {
  self.services
}

///|
/// Subscribes to user feedback accepted through the Viewer's inline input.
pub fn EmbeddedViewerServices::on_did_add_feedback(
  self : EmbeddedViewerServices,
  listener : (@agent_feedback_api.AgentFeedbackAddedEvent) -> Unit,
) -> @base_common.Disposable {
  self.agent_feedback.on_did_add_feedback(listener)
}

///|
/// Enables or disables the Viewer's feedback controls for one document.
pub fn EmbeddedViewerServices::set_feedback_enabled(
  self : EmbeddedViewerServices,
  resource : @base_common.Uri,
  enabled : Bool,
) -> Unit {
  self.agent_feedback.set_feedback_enabled(resource, enabled)
}

///|
/// Removes all feedback currently displayed for one document.
pub fn EmbeddedViewerServices::clear_feedback(
  self : EmbeddedViewerServices,
  resource : @base_common.Uri,
) -> Unit {
  self.agent_feedback.clear_feedback(resource)
}

///|
/// Adds one feedback item for an embedding application to display.
pub fn EmbeddedViewerServices::add_feedback(
  self : EmbeddedViewerServices,
  resource : @base_common.Uri,
  range : @base_common.Range,
  text : String,
  kind? : @agent_feedback_api.AgentFeedbackKind,
  state? : @agent_feedback_api.AgentFeedbackState,
) -> @agent_feedback_api.AgentFeedback {
  self.agent_feedback.add_feedback(resource, range, text, kind?, state?)
}

///|
/// Removes one feedback item from the Viewer.
pub fn EmbeddedViewerServices::remove_feedback(
  self : EmbeddedViewerServices,
  resource : @base_common.Uri,
  feedback_id : String,
) -> Unit {
  self.agent_feedback.remove_feedback(resource, feedback_id)
}

///|
/// Replaces the diagnostics owned by `owner` for one document.
pub fn EmbeddedViewerServices::set_diagnostics(
  self : EmbeddedViewerServices,
  owner : String,
  resource : @base_common.Uri,
  diagnostics : Array[@language.Diagnostic],
) -> Unit {
  self.markers.set_diagnostics(owner, resource, diagnostics)
}

///|
/// Releases the Viewer adapters and their concrete backing services.
pub fn EmbeddedViewerServices::dispose(self : EmbeddedViewerServices) -> Unit {
  if self.disposed {
    return
  }
  self.disposed = true
  self.services.dispose()
  self.markers.dispose()
  self.agent_feedback.dispose()
}
