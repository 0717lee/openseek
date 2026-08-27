///|
fn lane(id : String, run? : String) -> @subrun.Lane {
  { id, kind: "task", label: "investigate", steps: 0, activity: "", run, }
}

///|
test "only the open run's lanes are shown" {
  let lanes = [
    lane("a", run="r1"),
    lane("b", run="r2"),
    // A lane the host never attributed cannot be claimed by any run.
    lane("c"),
  ]
  assert_eq(@subrun.owned_by(lanes, "r1").map(item => item.id), ["a"])
  assert_eq(@subrun.owned_by(lanes, "r2").map(item => item.id), ["b"])
  inspect(@subrun.owned_by(lanes, "r3").length(), content="0")
}
