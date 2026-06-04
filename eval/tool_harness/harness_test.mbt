///|
async test "deterministic harness exercises every tool" {
  let report = @tool_harness.run_harness()
  assert_eq(report.rows.length(), 8)
  let markdown = report.markdown()
  if report.successes() != 8 || report.all_passed() == false {
    fail(markdown)
  }
  assert_true(markdown.contains("# Tool Harness"))
  assert_false(markdown.contains("`check_daemon`"))
  assert_true(markdown.contains("`moon_ide`"))
  assert_true(markdown.contains("| 8 | `finish` | pass"))
}

///|
async test "harness report can be written for inspection" {
  let root = @fs.tmpdir(prefix="openseek-tool-harness-report-")
  let report = @tool_harness.run_harness()
  report.write_files(root)
  let markdown = @fs.read_file("\{root}/report.md").text()
  let json = @fs.read_file("\{root}/report.json").text()
  assert_true(
    markdown.contains(
      "| # | Case | Result | Mode | Action | Reason | Warnings |",
    ),
  )
  assert_true(json.contains("\"title\":\"Tool Harness\""))
  @fs.rmdir(root, recursive=true)
}
