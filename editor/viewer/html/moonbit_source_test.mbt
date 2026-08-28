///|
#warnings("-alert_unstable")
test "MoonBit source uses editor token classes and escaped text nodes" {
  let rendered = @rabbita.render_to_string(() => {
    @rabbita.Val::constant(
      moonbit_source_code(
        (
          #|fn main {
          #|  let greeting = "<hello>"
          #|}
        ),
      ),
    )
  })
  assert_true(rendered.contains("class=\"language-moonbit\""))
  assert_true(rendered.contains("<span class=\"mtk3\">fn</span>"))
  assert_true(rendered.contains("<span class=\"mtk3\">let</span>"))
  assert_true(
    rendered.contains("<span class=\"mtk5\">\"&lt;hello&gt;\"</span>"),
  )
  assert_false(rendered.contains("<hello>"))
}

///|
#warnings("-alert_unstable")
test "numbered MoonBit source pads every gutter to the last line's width" {
  // Ten lines so the gutter crosses a digit boundary: single-digit numbers
  // must pad to the width of "10" or the per-row grids would misalign.
  let lines : Array[String] = []
  for index in 0..<10 {
    lines.push("let x\{index} = \{index}")
  }
  let source = lines.join("\n")
  let rendered = @rabbita.render_to_string(() => {
    @rabbita.Val::constant(moonbit_source_code(source, numbered=true))
  })
  assert_true(rendered.contains("<span class=\"moonbit-gutter\"> 1</span>"))
  assert_true(rendered.contains("<span class=\"moonbit-gutter\">10</span>"))
  assert_false(rendered.contains("<span class=\"moonbit-gutter\">1</span>"))
  assert_eq(rendered.split("class=\"moonbit-line\"").length(), 11)
  assert_true(rendered.contains("class=\"language-moonbit moonbit-code\""))
  assert_true(rendered.contains("<span class=\"mtk3\">let</span>"))
}

///|
#warnings("-alert_unstable")
test "a degenerate numbered line count elides the middle under true numbers" {
  let lines : Array[String] = []
  for index in 0..<600 {
    lines.push("let x\{index} = \{index}")
  }
  let rendered = @rabbita.render_to_string(() => {
    @rabbita.Val::constant(moonbit_source_code(lines.join("\n"), numbered=true))
  })
  // Head rows 1..400, one unnumbered skip row, tail rows 501..600 — never a
  // renumbered tail.
  assert_eq(rendered.split("class=\"moonbit-line\"").length(), 502)
  assert_true(rendered.contains("<span class=\"moonbit-gutter\">400</span>"))
  assert_true(rendered.contains("⋯ 100 lines skipped ⋯"))
  assert_true(rendered.contains("<span class=\"moonbit-gutter\">501</span>"))
  assert_true(rendered.contains("<span class=\"moonbit-gutter\">600</span>"))
  assert_false(rendered.contains("<span class=\"moonbit-gutter\">401</span>"))
  assert_true(rendered.contains("class=\"moonbit-code moonbit-skip\""))
}

///|
#warnings("-alert_unstable")
test "one enormous numbered line stays a single honestly numbered row" {
  // Longer than any historical code-unit clamp: the row count is what the
  // renderer bounds, never a line's own length.
  let rendered = @rabbita.render_to_string(() => {
    @rabbita.Val::constant(
      moonbit_source_code("let x = \"\{"y".repeat(25_000)}\"", numbered=true),
    )
  })
  assert_eq(rendered.split("class=\"moonbit-line\"").length(), 2)
  assert_true(rendered.contains("<span class=\"moonbit-gutter\">1</span>"))
  assert_false(rendered.contains("skipped"))
}

///|
#warnings("-alert_unstable")
test "per-line MoonBit fragments keep line boundaries and token classes" {
  let lines = moonbit_source_lines("fn main {\n  let answer = 42\n}")
  assert_eq(lines.length(), 3)
  let first = @rabbita.render_to_string(() => @rabbita.Val::constant(lines[0]))
  assert_true(first.contains("<span class=\"mtk3\">fn</span>"))
  let second = @rabbita.render_to_string(() => @rabbita.Val::constant(lines[1]))
  assert_true(second.contains("<span class=\"mtk3\">let</span>"))
  assert_false(second.contains("\n"))
}
