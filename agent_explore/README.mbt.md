# agent_explore

The `explore` tool: delegate one self-contained question to a read-only scout
subagent (a dedicated `openseek subrun explore` child process on the `@agent_subrun` substrate) and get back a bounded, cited answer.

Why it exists: long autonomous runs burn their context on fan-out reading,
and MoonBit is young enough that model priors about its APIs are unreliable.
The scout answers workspace questions ("where is X handled") and MoonBit API
questions (what a package offers, exact signatures) with `moon ide doc` as
its primary instrument, returning `file:line` citations the parent can
spot-check — conclusions enter the parent's context, never file dumps.

Contract highlights:

- Child toolset: `read` + `shell(read_only=true)` + `submit_answer` — no edit
  tools, no nested subagent tools.
- Every report field is capped at submission (`ExploreReport::validate`), so
  the rendered result stays far below the loop's tool-result clamp.
- Cost is reserved from the shared per-turn `SubrunBudget` BEFORE launch and
  reconciled after; an exhausted budget refuses without spending anything.
- Failure is graceful: no report / timeout / budget exhaustion all return an
  is_error result telling the parent to fall back to reading directly.
