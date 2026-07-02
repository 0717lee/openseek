///|
/// Shared accessors over `@argparse.Matches` for the command mains
/// (`cmd/openseek`, `cmd/tui`, `cmd/viz_server`). Each main used to carry its
/// own byte-identical copies; keeping one copy here removes the risk of the
/// copies drifting apart. Error messages are part of each command's contract
/// and must not change when helpers move.

///|
/// First parsed occurrence of option `name`. Command tables give every
/// looked-up option a default, so a missing entry is a wiring bug in the
/// command definition, not a user error.
pub fn value(matches : @argparse.Matches, name : String) -> String raise {
  match matches.values.get(name) {
    Some([value, ..]) => value
    _ => fail("missing parsed argument: \{name}")
  }
}

///|
/// Every parsed occurrence of option `name`. Absent options read as empty so
/// repeatable options without a default stay optional.
pub fn values(matches : @argparse.Matches, name : String) -> Array[String] {
  match matches.values.get(name) {
    Some(values) => values
    None => []
  }
}

///|
/// Whether boolean flag `name` was set; unset flags read as `false`.
pub fn flag(matches : @argparse.Matches, name : String) -> Bool {
  matches.flags.get(name) is Some(true)
}

///|
/// Trimmed text of option `name`, with whitespace-only input mapped to
/// `None` so "unset" and "set to blanks" behave the same.
pub fn non_empty_value(
  matches : @argparse.Matches,
  name : String,
) -> String? raise {
  let key = value(matches, name).trim()
  if key.is_empty() {
    None
  } else {
    Some("\{key}")
  }
}

///|
/// Trimmed text of option `name`, failing with `message` when the input is
/// empty or whitespace-only. The caller supplies `message` so each command
/// keeps its own flag/env-var guidance verbatim.
pub fn require_non_empty(
  matches : @argparse.Matches,
  name : String,
  message : String,
) -> String raise {
  let text = value(matches, name).trim()
  if text.is_empty() {
    fail(message)
  }
  "\{text}"
}

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
