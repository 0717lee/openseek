# Agent Notes

## Start Here

- Architecture and dependency rules: `docs/architecture.md`
- Package contracts: the owning package's `README.md` and
  `pkg.generated.mbti`
- Commands and test-layer selection: `docs/harness.md`
- Required checks and conformance-test rules: `docs/quality.md`
- Style: `docs/styles.md`
- Active cross-package plans and planning rules: `docs/exec-plans/`
- Monaco/CodeMirror source maps: `docs/references/{monaco,codemirror}.md`

## UI Development Loop

OpenSeek's desktop file editor (`../desktop/frontend/fileeditor`) is the primary
downstream, user-facing host. `internal/shell` is the fast development and E2E
host for the editor; do not use a full OpenSeek build and preview as the routine
inner loop for editor UI work.

- For a visual or behavioral improvement to existing Viewer UI, implement and
  preview it in `internal/shell`, keep the existing public host seam stable, and
  expect OpenSeek to receive the change with no or minimal adaptation. If that
  is not true, inspect the coupling before expanding either host API.
- For a new editor UI intended for OpenSeek, inspect
  `../desktop/frontend/fileeditor/{editor_panel,viewer_services}.mbt` and the
  relevant provider/capability adapters before finalizing the public contract.
  Unless the task explicitly scopes a feature to editor-only exploration,
  treat new user-facing Viewer UI as intended for OpenSeek. Build the generic
  editor surface and its `internal/shell` preview first, then add the OpenSeek
  adapter in the same implementation task. Do not leave known downstream
  adaptation as an unspecified follow-up; separate coherent commits are fine.
- Keep OpenSeek product policy, host RPC, storage, and workspace behavior under
  `../desktop/**`. Keep the editor API host-neutral, and use `ViewerServices`
  and the public `viewer/common/**` capability handles as the integration seam.
- During iteration, run focused editor tests/browser scenarios and a targeted
  JS check of every touched OpenSeek adapter package. Run the required editor
  and root integration gates before declaring the cross-host work complete;
  package or launch the full desktop app only when OpenSeek-specific layout,
  effects, assets, or packaging are part of the behavior under test.

## Architecture Changes

Follow `docs/architecture.md` and review dependency changes in `moon.pkg`.
Review public API changes through the owning `pkg.generated.mbti`. Do not add
architecture-lint scripts for one-time design decisions; automate only a
repeated concrete failure mode, and keep the check generic rather than naming
current methods or implementation types.

## Reference Ports

Follow `docs/exec-plans/_PORT_PLAYBOOK.md` for Monaco/VS Code or CodeMirror
ports. Monaco is the behavioral oracle, not a required MoonBit representation.
The non-negotiables are:

1. Choose and state the port mode: behavior port by default, algorithm-fidelity
   port for sensitive arithmetic/state machines, or full source audit only when
   explicitly requested.
2. Account for observable behavior, boundary cases, algorithmic invariants, and
   intentional exclusions. Do not create one ledger row per TypeScript member
   unless the selected full-audit mode needs it.
3. Preserve exact control flow and constants only where they affect the selected
   algorithm-fidelity contract. Otherwise prefer MoonBit-native concrete types,
   enums, handles, callback records, and ownership.
4. Link each claimed behavior to focused evidence or mark it `DEFERRED (reason)`
   / `N-A (reason)`. Green repository checks alone do not prove parity.

## Execution Plan Continuation

When the user asks to execute a checked-in plan, carry it through inventory,
review, implementation, validation, and milestone commits without pausing for
user approval. `Gate A`, `review gate`, and `STOP FOR REVIEW` are internal
quality checkpoints: produce the required artifact, review it against the plan
and current source, record the result, and continue.

Pause only when the user explicitly requests a review stop or when the gate
reveals a material choice that the plan and current repository evidence cannot
resolve without changing scope, public API, or behavior.

## Version Control

- Commit each coherent, validated milestone without waiting to be asked.
- Do not rewrite, squash, amend, reset, or revert history without approval.
