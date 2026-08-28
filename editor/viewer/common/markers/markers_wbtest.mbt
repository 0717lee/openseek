///|
/// Builds error marker input matching Monaco's `randomMarkerData` shape
/// (line/col all 1), with a deterministic message.
fn marker_data(severity : MarkerSeverity, message : String) -> MarkerData {
  MarkerData(
    severity~,
    message~,
    start_line_number=1,
    start_column=1,
    end_line_number=1,
    end_column=1,
  )
}

///|
test "marker service replaces owner resource and supports limits" {
  let service = MarkerService()
  let uri = try! @base_common.Uri::from(
    scheme="inmemory",
    authority="model",
    path="/markers.mbt",
  )
  service.set_diagnostics("owner-a", uri, [
    {
      range: Range(1, 1, 1, 2),
      severity: Warning,
      message: "first",
      tags: None,
    },
    {
      range: Range(1, 3, 1, 4),
      severity: Error,
      message: "second",
      tags: None,
    },
  ])
  service.set_diagnostics("owner-b", uri, [
    { range: Range(1, 5, 1, 6), severity: Info, message: "third", tags: None, },
  ])
  assert_eq(service.markers_for_resource(uri).length(), 3)
  service.set_diagnostics("owner-a", uri, [
    {
      range: Range(1, 7, 1, 8),
      severity: Warning,
      message: "replacement",
      tags: None,
    },
  ])
  let markers = service.markers_for_resource(uri)
  assert_eq(markers.length(), 2)
  assert_eq(service.markers_for_resource(uri, limit=1).length(), 1)
}

///|
test "MarkerData sanitize clamps line/column and drops empty message" {
  let uri = try! @base_common.Uri::from(
    scheme="inmemory",
    authority="model",
    path="/sanitize.mbt",
  )
  // empty message dropped (markerService.ts:238)
  assert_true(marker_data(Error, "").to_marker("o", uri) is None)
  // start/end clamping (markerService.ts:243-246)
  let raw = MarkerData(
    severity=Error,
    message="m",
    start_line_number=0,
    start_column=0,
    end_line_number=-3,
    end_column=0,
  )
  let marker = raw.to_marker("o", uri).unwrap()
  assert_eq(marker.start_line_number, 1)
  assert_eq(marker.start_column, 1)
  assert_eq(marker.end_line_number, 1)
  assert_eq(marker.end_column, 1)
}
