///|
/// All concrete services Desktop owns for its embedded Viewer. Keeping them
/// together makes their shared lifetime explicit without changing editor's
/// public API.
priv struct DesktopViewerServices {
  viewer_services : @viewer.ViewerServices
  markers : @markers.MarkerService
  feedback : @feedback.DesktopFeedbackService
  // Retaining the registry handles keeps ownership explicit. The desktop
  // mounts exactly one Viewer for the page lifetime; a future page teardown
  // can dispose these without reaching into the process-wide registry.
  _navigation_registrations : Array[@common.Disposable]
}

///|
fn DesktopViewerServices::DesktopViewerServices(
  location_opener : @navigation_api.LocationOpenerHandle,
  text_model_resolver : @navigation_api.TextModelResolverHandle,
) -> DesktopViewerServices {
  let markers = @markers.MarkerService(schedule=@base_browser.queue_microtask)
  let feedback = @feedback.DesktopFeedbackService()
  let navigation_registrations = register_moon_ide_navigation_providers()
  let viewer_services = @viewer.ViewerServices(
    markers=@markers.MarkerStore(markers.marker_service_handle()),
    agent_feedback=feedback.agent_feedback_handle(),
    location_opener~,
    text_model_resolver~,
  )
  {
    viewer_services,
    markers,
    feedback,
    _navigation_registrations: navigation_registrations,
  }
}
