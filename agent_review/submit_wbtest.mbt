///|
test "submit captures a valid report and finishes" {
  let captured : Ref[ReviewReport?] = { val: None }
  let action = submit(captured, sample_report().to_json())
  guard action is Control(Finish(_)) else { fail("expected Finish") }
  guard captured.val is Some(_) else { fail("expected captured report") }
}

///|
test "submit rejects an invalid report without capturing" {
  let captured : Ref[ReviewReport?] = { val: None }
  let bad = {
    ..sample_report(),
    findings: [
      {
        file: "",
        line: None,
        severity: "urgent",
        category: "x",
        title: "",
        detail: "d",
        suggestion: None,
      },
    ],
  }
  let action = submit(captured, bad.to_json())
  guard action is Respond(output) else { fail("expected Respond") }
  assert_true(output.is_error)
  guard captured.val is None else { fail("must not capture an invalid report") }
}
