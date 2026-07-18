// Deliberate exports with no in-repo production consumer (see
// shrink_package.md): test seams for the command mains' argument tests.

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
