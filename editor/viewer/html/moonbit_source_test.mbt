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
