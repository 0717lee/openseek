// Deliberate exports with no in-repo production consumer (see
// shrink_package.md): test seams, round-trip/protocol surface, and
// future-proof API kept on purpose. Each entry documents its reason.

///|
/// The schema version this build emits and accepts.
pub let current_schema_version : Int = 1

///|
/// Allowed severity values, ordered most to least severe.
pub fn severities() -> Array[String] {
  ["blocker", "high", "medium", "low", "nit"]
}

///|
/// Parse a report from JSON, returning the report or a human-readable error.
pub fn ReviewReport::parse(json : Json) -> Result[ReviewReport, String] {
  let report : ReviewReport = @json.from_json(json) catch {
    e => return Err("invalid review report JSON: \{e}")
  }
  Ok(report)
}

///|
/// Validate a report against the contract. Returns the list of problems; an
/// empty list means the report is valid. The `submit_review` tool uses this to
/// reject malformed model output and ask for a retry.
pub fn ReviewReport::validate(self : ReviewReport) -> Array[String] {
  let problems : Array[String] = []
  if self.schema_version != current_schema_version {
    problems.push(
      "schema_version must be \{current_schema_version}, got \{self.schema_version}",
    )
  }
  if self.summary.trim() == "" {
    problems.push("summary must not be empty")
  }
  let allowed = severities()
  for finding in self.findings {
    if !allowed.contains(finding.severity) {
      problems.push(
        "finding '\{finding.title}': invalid severity '\{finding.severity}'",
      )
    }
    if finding.file == "" {
      problems.push("a finding has an empty file path")
    }
    if finding.title == "" {
      problems.push("a finding has an empty title")
    }
    if finding.category == "" {
      problems.push("finding '\{finding.title}': empty category")
    }
    if finding.detail == "" {
      problems.push("finding '\{finding.title}': empty detail")
    }
  }
  problems
}
