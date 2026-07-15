///|
test "raising goal decoder errors stay actionable at the agent boundary" {
  debug_inspect(
    decode_goal_status({ "status": "continuing" }),
    content=(
      #|Err("goal requires a string \"remaining\" when status is \"continuing\"")
    ),
  )
}
