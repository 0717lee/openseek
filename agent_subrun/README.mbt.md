# agent_subrun

The substrate for nested, ephemeral agent turns — sub-runs. A sub-run is one
bounded child turn with a fresh in-memory session, a restricted caller-built
toolset, and a structured result captured through a submit-style control tool
(`capture_tool`). The review engine runs on it today; the `explore` tool and
the goal-review gate are its next clients.

Guarantees:

- **Event isolation.** The child's protocol events go to the caller's
  `event_sink` — by default nowhere. A child's `AgentFinished` must never
  reach the host stream, where the TUI and desktop hosts would read it as
  the outer run's terminal.
- **Cost accounting.** `SubrunResult` reports the steps and provider tokens
  the child actually spent, observed from its own event stream.
- **Bounded execution.** A step ceiling always; a wall deadline
  (`wall_deadline_ms`) that cancels the child internally and reports
  `TimedOut` when set.
- **Cancellation discipline.** External cancellation re-raises; only the
  runner-owned deadline is absorbed. A value captured before the deadline
  cut the turn still reports `Captured`.
- **Ceiling salvage.** Capture tools declare `control=true`, so a child
  hitting its context ceiling on the submitting step seals with its report
  instead of losing it (see the loop's control-call salvage).
