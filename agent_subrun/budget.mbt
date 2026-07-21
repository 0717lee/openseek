///|
/// Below this many remaining steps a child cannot do useful work (read a few
/// files and submit), so `reserve` refuses rather than launching a doomed
/// run that burns its allowance on a truncated attempt.
pub let min_useful_subrun_steps : Int = 8

///|
/// The per-turn allowance shared by EVERY subrun tool in a session (explore,
/// the goal-review gate, callable review): one child must not be able to
/// stretch a turn unboundedly, and the tools must not each carry a private
/// quota that sums to one.
///
/// The owner is the CLI layer: it creates one budget per session, passes it
/// to every subrun tool definition, and calls `reset_turn` at each turn
/// start. Enforcement is reserve-BEFORE-launch: the executor reserves the
/// child's requested steps up front — deriving the child's effective
/// `max_steps` from what remains — and `reconcile`s the unused part after
/// the run. Debit-only-after-return would let one child overshoot the whole
/// remaining allowance.
pub struct SubrunBudget {
  max_calls_per_turn : Int
  max_steps_per_turn : Int
  mut used_calls : Int
  mut reserved_steps : Int
}

///|
/// Defaults sized for explore-style children: a few delegations per turn,
/// each bounded well below a whole child allowance.
pub fn SubrunBudget::SubrunBudget(
  max_calls_per_turn? : Int = 4,
  max_steps_per_turn? : Int = 120,
) -> SubrunBudget {
  { max_calls_per_turn, max_steps_per_turn, used_calls: 0, reserved_steps: 0 }
}

///|
/// Start a new parent turn: the allowance refills.
pub fn SubrunBudget::reset_turn(self : SubrunBudget) -> Unit {
  self.used_calls = 0
  self.reserved_steps = 0
}

///|
/// Reserve capacity for one child BEFORE launching it. Returns the child's
/// effective step ceiling — `requested_steps` clamped to the remaining
/// allowance — or `None` when the per-turn call count is spent or the
/// remaining steps could not fund a useful run. The reservation holds until
/// `reconcile` returns the unused portion.
pub fn SubrunBudget::reserve(
  self : SubrunBudget,
  requested_steps : Int,
) -> Int? {
  if self.used_calls >= self.max_calls_per_turn {
    return None
  }
  let remaining = self.max_steps_per_turn - self.reserved_steps
  if remaining < min_useful_subrun_steps {
    return None
  }
  let effective = if requested_steps < remaining {
    requested_steps
  } else {
    remaining
  }
  self.used_calls += 1
  self.reserved_steps += effective
  Some(effective)
}

///|
/// Return a reservation's unused part after the child ran. `reserved` is
/// what `reserve` granted; `used` is the child's actual `steps_used` (from
/// its `SubrunResult`). Steps the child never took flow back into the
/// turn's allowance; the call count does not.
pub fn SubrunBudget::reconcile(
  self : SubrunBudget,
  reserved~ : Int,
  used~ : Int,
) -> Unit {
  let spent = if used < 0 {
    0
  } else if used > reserved {
    reserved
  } else {
    used
  }
  self.reserved_steps -= reserved - spent
}

///|
test "reserve clamps to the remaining allowance and refuses dust" {
  let budget = SubrunBudget(max_calls_per_turn=3, max_steps_per_turn=50)
  // First reservation: full request fits.
  assert_true(budget.reserve(40) is Some(40))
  // Second: only 10 remain, clamped.
  assert_true(budget.reserve(40) is Some(10))
  // Third: nothing useful remains.
  assert_true(budget.reserve(40) is None)
}

///|
test "the call count is its own ceiling" {
  let budget = SubrunBudget(max_calls_per_turn=2, max_steps_per_turn=1_000)
  assert_true(budget.reserve(10) is Some(10))
  assert_true(budget.reserve(10) is Some(10))
  assert_true(budget.reserve(10) is None)
}

///|
test "reconcile returns unused steps but never the call slot" {
  let budget = SubrunBudget(max_calls_per_turn=2, max_steps_per_turn=40)
  guard budget.reserve(30) is Some(granted) else { fail("expected a grant") }
  // The child used 5 of its 30: 25 flow back.
  budget.reconcile(reserved=granted, used=5)
  assert_true(budget.reserve(40) is Some(35))
  // Both call slots are now spent regardless of steps returned.
  assert_true(budget.reserve(10) is None)
}

///|
test "reset_turn refills everything" {
  let budget = SubrunBudget(max_calls_per_turn=1, max_steps_per_turn=20)
  assert_true(budget.reserve(20) is Some(20))
  assert_true(budget.reserve(20) is None)
  budget.reset_turn()
  assert_true(budget.reserve(20) is Some(20))
}

///|
test "reconcile clamps a pathological used count" {
  let budget = SubrunBudget(max_calls_per_turn=2, max_steps_per_turn=30)
  guard budget.reserve(20) is Some(granted) else { fail("expected a grant") }
  // used > reserved must not mint steps; used < 0 must not either.
  budget.reconcile(reserved=granted, used=99)
  assert_true(budget.reserve(30) is Some(10))
}
