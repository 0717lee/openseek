///|
/// The service capabilities used by the standalone Markdown surface. This
/// package owns no CodeEditorWidget and does not import its service façade.
struct MarkdownViewerServices {
  languages : @languages.LanguageHandle
  marker_decorations : @markers.MarkerDecorationsHandle
  location_opener : @navigation_api.LocationOpenerHandle?
  log_service : @log.LogHandle
  owned_marker_decorations : @markers.MarkerDecorationsService?
  owned_markers : @markers.MarkerService?
  mut disposed : Bool
}

///|
/// Builds a Markdown-only service bundle. Supplied handles remain caller-owned;
/// omitted marker services are created and released by this bundle.
pub fn MarkdownViewerServices::MarkdownViewerServices(
  languages? : @languages.LanguageHandle,
  markers? : @markers.MarkerDecorationsSource,
  location_opener? : @navigation_api.LocationOpenerHandle,
  log_service? : @log.LogHandle,
) -> MarkdownViewerServices {
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
  {
    languages,
    marker_decorations,
    location_opener,
    log_service,
    owned_marker_decorations,
    owned_markers,
    disposed: false,
  }
}

///|
pub fn MarkdownViewerServices::languages(
  self : MarkdownViewerServices,
) -> @languages.LanguageHandle {
  self.languages
}

///|
pub fn MarkdownViewerServices::marker_decorations(
  self : MarkdownViewerServices,
) -> @markers.MarkerDecorationsHandle {
  self.marker_decorations
}

///|
pub fn MarkdownViewerServices::location_opener(
  self : MarkdownViewerServices,
) -> @navigation_api.LocationOpenerHandle? {
  self.location_opener
}

///|
pub fn MarkdownViewerServices::log_service(
  self : MarkdownViewerServices,
) -> @log.LogHandle {
  self.log_service
}

///|
pub fn MarkdownViewerServices::dispose(self : MarkdownViewerServices) -> Unit {
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
}
