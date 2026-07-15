///|
test "goal status facade exposes decoded verdicts" {
  debug_inspect(
    [
      @goal.decode_status({ "status": "met" }),
      @goal.decode_status({ "status": "continuing", "remaining": "parser left" }),
      @goal.decode_status({
        "status": "blocked",
        "reason": "waiting for credentials",
      }),
    ],
    content=(
      #|[Met, Continuing("parser left"), Blocked("waiting for credentials")]
    ),
  )
}

///|
test "goal definition identifies a control tool" {
  let definition = @goal.definition()
  debug_inspect(
    (definition.name, definition.control),
    content=(
      #|("goal", true)
    ),
  )
}
