///|
/// Shared accessors over `@argparse.Matches` for the command mains
/// (`cmd/openseek`, `cmd/tui`, `cmd/viz_server`). Each main used to carry its
/// own byte-identical copies; keeping one copy here removes the risk of the
/// copies drifting apart. Error messages are part of each command's contract
/// and must not change when helpers move.

///|
/// Parse `input` as a strictly positive integer; `label` names the offending
/// option in the failure message.
pub fn parse_positive_int(input : String, label : String) -> Int raise {
  let parsed = @string.parse_int(input) catch {
    _ => fail("\{label} must be a positive integer, got: \{input}")
  }
  guard parsed > 0 else {
    fail("\{label} must be a positive integer, got: \{input}")
  }
  parsed
}

///|
test "parse_positive_int accepts positives and rejects zero, negatives, junk" {
  assert_eq(parse_positive_int("42", "--max-steps"), 42)
  for bad in ["0", "-3", "", "abc"] {
    try ignore(parse_positive_int(bad, "--max-steps")) catch {
      err => assert_true("\{err}".contains("must be a positive integer"))
    } noraise {
      _ => fail("expected \{bad} to be rejected")
    }
  }
}
