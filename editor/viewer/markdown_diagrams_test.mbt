///|
test "public Viewer UML renderer returns SVG only for valid diagrams" {
  let valid =
    #|@startuml
    #|participant Alice
    #|Alice -> Bob : hello
    #|@enduml
  guard render_uml_diagram_svg(valid) is Some(svg) else {
    fail("expected UML SVG")
  }
  assert_true(svg.contains("<svg"))
  assert_true(svg.contains("--vscode-editor-foreground"))
  assert_true(render_uml_diagram_svg("@startuml\n@enduml") is None)
}

///|
test "public Viewer MBTI renderer accepts a bare generated interface" {
  let source =
    #|package "example/geometry"
    #|
    #|pub struct Point {
    #|  x : Double
    #|  y : Double
    #|}
    #|
    #|pub trait Shape {
    #|  area(Self) -> Double
    #|}
    #|
    #|impl Shape for Point
  guard render_mbti_diagram_svg(source) is Some(svg) else {
    fail("expected MBTI SVG")
  }
  assert_true(svg.contains("<svg"))
  assert_true(svg.contains("Point"))
  assert_true(svg.contains("--vscode-editor-foreground"))
  assert_true(render_mbti_diagram_svg("pub struct MissingPackage") is None)
}
