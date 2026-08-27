# Desktop UX guidelines

This document defines interaction principles that should remain true as the
Desktop product grows. It complements [`DESIGN.md`](DESIGN.md): that document
defines the visual language, while this one defines how the interface behaves,
communicates, and protects the user's attention. CSS implementation rules remain
in [`styles/README.md`](styles/README.md).

> **Let people entrust real software work to agents without losing context,
> evidence, or control.**

These guidelines deliberately avoid application-specific state machines and
component APIs. A feature specification may add more detail, but should not
weaken these principles. In this document, **must** is a product requirement;
**must not**, **never**, and **do not** are product prohibitions; **should** and
**prefer** are defaults that need a clear reason to override; and **avoid** means
**should not**.

## Experience values

Values are the highest-level test for product decisions. They describe the
experience we want to create, not a component catalog or a checklist of UI
states. The four value names below are adapted from [Ant Design Values]; their
definitions and the principles derived from them are specific to Desktop. The
functional and emotional framing is influenced by [Fluent Design Principles].

### Natural

**Promise:** the workspace behaves the way sustained software work teaches the
user to expect.

Functionally, the interface builds on what the user already understands about
their platform and their work. Intent, action, and effect form a coherent whole
instead of making the user translate between the task and the interface.

Emotionally, Desktop should feel familiar, calm, and direct. The agent may do
complex work, but using it should not feel like managing a performance.

### Certain

**Promise:** the user can tell what the system is doing, what it affected, what
is known, and what remains uncertain.

Functionally, the interface gives an honest and legible account of its state,
effects, evidence, and limits. It reduces ambiguity without manufacturing
confidence that the underlying work cannot support.

Emotionally, Desktop should feel dependable without pretending to be infallible.
Confidence comes from legible state, honest uncertainty, and recoverable
outcomes.

### Meaningful

**Promise:** every visible signal and interruption helps the user understand or
advance the work.

Functionally, each part of the experience serves the user's intent and helps
them understand or advance the work. Detail, emphasis, and interruption are
proportional to their value in the moment.

Emotionally, Desktop should feel focused and purposeful. A quiet interface is
not an inactive one; it is an interface that spends attention carefully.

### Growing

**Promise:** the workspace can become more capable without making the user
relearn it or confront all of its complexity at once.

Functionally, deeper capability builds on familiar ideas and becomes available
in proportion to the user's need and understanding. Growth adds fluency rather
than continually resetting it.

Emotionally, Desktop should reward learning with increasing fluency and agency,
not increasing caution.

## Derived interaction principles

These principles turn the values into reusable product judgments. A feature
specification may define its own states and transitions, but it must preserve
these relationships.

| Value | Principles it primarily governs |
| --- | --- |
| Natural | The user's flow outranks system chatter |
| Certain | State follows work, not focus; Evidence, not theater, earns trust |
| Meaningful | Attention follows agency, not activity |
| Growing | Autonomy follows reversibility; Hide complexity, never consequence |

### State follows work, not focus

A consequential state belongs to the work it describes. Selection may change
its detail or emphasis, but must not determine whether it is discoverable.
Event streams are history, not the sole representation of current state. An
active operation remains glanceable at its owning surface and, when work can
continue in multiple contexts, from a selection-independent overview. Its
outcome and supporting evidence remain available for as long as they can affect
the user's decisions, trust, or recovery; they do not disappear merely because
an event or animation ended.

This principle catches a whole class of defects: a working conversation that
looks idle until another event arrives, a background conversation whose
activity disappears when focus moves elsewhere, or a completed operation that
has no durable result. These are not separate exceptions; each confuses view
state with work state.

### Attention follows agency, not activity

Activity should be observable without automatically becoming an interruption.
Escalate attention when the user can make a useful decision, when work is at
risk, or when an outcome changes what the user can safely do next. Routine
background work should remain quiet even when it is busy.

### Evidence, not theater, earns trust

Feedback must describe what the system can support as true. Distinguish an
accepted request from running work, a produced result from a verified result,
and confidence from evidence whenever the difference matters. Animation,
confident language, and a generic “working” state must never substitute for an
inspectable result or an honest limitation.

### Autonomy follows reversibility

Within the goal and scope the user has authorized, the easier an action is to
stop, inspect, undo, or repair, the more freely the system may perform it.
Reversibility does not create permission. As consequences become broader, less
predictable, or harder to reverse, the interface must make scope clearer and
give the user more opportunity to preview, constrain, or confirm the action.

### The user's flow outranks system chatter

Background updates should preserve focus, selection, scroll position, open
context, and unfinished input. They must not move controls or steal focus merely
to announce progress or routine success. If the user leaves a live-following
position, the system must respect that choice instead of pulling the viewport
back.

### Hide complexity, never consequence

Progressive disclosure may simplify machinery, diagnostics, or advanced
controls. It must not conceal what will change, what did change, whether the
result is trustworthy, what failed, or how the user can recover. Simplicity is
the removal of unnecessary decisions, not the removal of necessary truth.

## Operational guardrails

The guardrails below are shared implementation defaults, not additional product
values. They make the principles reviewable without prescribing a
feature-specific state machine.

### Feedback and activity

Every intentional user action must receive prompt acknowledgment at the
narrowest surface that fully explains its effect. Escalate feedback in this
order:

1. Update the control or content that owns the action.
2. Show persistent status in the affected view or workspace.
3. Use a notification when relevant work finishes elsewhere or needs attention
   outside its original context.
4. Use a modal only when work cannot safely continue without an immediate
   decision.

Do not use a disappearing notification as the only record of an actionable
error, unfinished operation, or continuing condition. Do not interrupt merely
to announce routine success. This follows the contextual escalation model in
[VS Code Notifications], [VS Code Status Bar], and [Apple Feedback].

Status should answer useful questions: what is happening, what it affects,
whether the user can continue, and what they can do next. Expose an internal
stage only when it changes understanding, the next useful action, confidence in
the result, or recovery options.

- Prefer a specific verb and object over a generic label such as “Working”.
- Acknowledge acceptance without implying completion.
- Use determinate progress when it can be measured. Never invent a percentage
  or time estimate, and never make multi-stage progress appear to rewind.
- Use indeterminate progress only while useful progress cannot be measured. For
  long work, add meaningful phase text, details or logs, timeout behavior, and
  cancellation when safe.
- Replace activity feedback with an explanation and recovery action when work
  stalls or fails. Stop the activity indication when the activity ends.

Use these elapsed-wait thresholds as shared defaults. Start at the appropriate
level when a long wait is known in advance; otherwise escalate as the operation
crosses a boundary:

| Elapsed wait | Default feedback |
| --- | --- |
| Under `1s` | No loading animation; acknowledge input in the initiating control |
| `1–3s` | A small, local, labeled activity indicator |
| Over `3s` | Descriptive status and measurable progress when available |

An AI conversation may need immediate acknowledgment even for a short expected
wait because silence breaks the conversational turn. The thresholds and
progress guidance are based on [Fluent Wait UX] and [Fluent Progress]. VS Code
also recommends details, cancellation, and timeout behavior for long-running
progress ([VS Code Notifications]).

### Motion and attention

Motion may explain a change, preserve spatial continuity, acknowledge an
interaction, or direct attention. If removing an animation loses no useful
information or context, remove it.

Readable content must remain readable while the system is active.

- Never pulse, blink, shimmer, jitter, or repeatedly fade the opacity of a
  sentence, message, label, command, diagnostic, log line, or other readable
  content.
- Put activity motion in a small adjacent indicator. Stable text, an icon, a
  shape, or a value must still communicate the state when motion is removed.
- Do not replay entrance animations when restoring history or loading a saved
  view. Do not animate every item in a large batch. Animate genuinely new
  content only when doing so explains where it came from.
- Use at most one primary continuous signal for an operation. Surfaces that
  mirror the same activity should use static status.
- Stop an activity animation as soon as the activity ends.
- Direct manipulation must track the pointer or keyboard immediately. Do not
  add a trailing transition to dragging, resizing, typing, selection, or focus.

Continuous motion is a scarce attention signal. Use it only while an operation
is active and a static state would leave meaningful uncertainty. Keep loops
small and visually quiet; they must not change nearby geometry or legibility.
Never use a loop to advertise importance, unread content, success, or a state
that is waiting for the user. Prefer determinate progress whenever honest
measurement exists.

This is intentionally stricter than WCAG's minimum. WCAG requires a way to
pause, stop, or hide certain nonessential auto-started motion or blinking that
lasts more than five seconds beside other content ([WCAG Pause, Stop, Hide]). A
sustained-work surface should avoid creating that distraction in the first
place.

Choose motion by semantic purpose rather than inventing durations for individual
components:

| Motion role | Duration | Typical purpose |
| --- | ---: | --- |
| Instant | `0ms` | Focus, selection, direct manipulation, critical feedback |
| Micro | `50ms` or `100ms` | Hover, press, color, or compact disclosure feedback |
| Small enter | `150ms` | Popup, tooltip, or inline content entering |
| Small exit | `100ms` | Dismissal that should clear the way quickly |
| Context transition | `200ms` or `250ms` | Panel or modal transition that establishes location |
| Rare large spatial transition | `400ms` maximum | Movement whose spatial relationship aids orientation |

Implementations should choose the nearest shared duration from `0ms`, `50ms`,
`100ms`, `150ms`, `200ms`, `250ms`, and `400ms`. The duration includes the whole
transition and must not delay input, focus, error presentation, or
assistive-technology feedback. Frequent interactions should stay at or below
`150ms`; exits should usually be faster and less prominent than entrances.

- Use `ease-out` for entrances, `ease-in` for exits, and `ease-in-out` for an
  element that repositions or transforms in place.
- Use linear easing only for motion that represents a real constant rate.
- Prefer a quick fade for large context changes unless spatial movement teaches
  where content came from or where it went.
- Animate at most one or two visual properties. Avoid ornamental choreography.
- Never require the user to wait for an animation before acting.

These defaults synthesize functional motion guidance and timing ranges from
[Fluent Motion], [Atlassian Motion], [Atlassian Applying Motion], and
[Apple Motion].

### Reduced motion

Reduced motion is a supported product mode, not an optional polish pass.

- Start from a usable static presentation and add nonessential motion only
  under `prefers-reduced-motion: no-preference` where practical.
- Under reduced motion, remove spatial transitions, scale, bounce, parallax,
  blinking, pulsing, shimmer, and decorative rotation. Make the corresponding
  state change immediate.
- Replace an essential animated activity cue with stable text and an icon or
  progress value. Motion must never be the only carrier of information.
- Test complete workflows with all animation disabled. Focus order, status,
  progress, errors, and control availability must remain understandable.

W3C documents the static-first media-query pattern in Technique C39. Atlassian
requires the interface to remain usable with motion off, while Apple recommends
reducing repetitive and spatial motion in response to the platform preference
([W3C Technique C39], [Atlassian Motion], [Apple Accessibility]).

### Control and recovery

The interface should make exploration safe and recovery inexpensive.

- Prefer reversible actions. Preserve drafts, selections, and completed work
  when cancellation, navigation, or an error does not require discarding them.
- Offer Cancel, Undo, Retry, or an equivalent recovery path when safe and
  meaningful. Explain irreversible consequences before commitment.
- An error should state what happened, what was affected, what remains safe
  when relevant, and the next useful action. Keep exact diagnostics available
  without forcing everyone to read them first.
- Do not confirm routine, expected, reversible actions. Interrupt for unexpected
  and difficult-to-recover consequences.

For automated or AI-driven actions, make scope and likely consequence clear,
ask for clarification when uncertainty makes acting risky, and make it easy to
stop, dismiss, inspect, or correct the system. Claims of completion should be
supported by inspectable results. These rules follow [Apple Design Principles]
and [Human-AI Interaction Guidelines].

### Perceivable state

Do not rely on color, animation, sound, or position alone to communicate state.
Use concise text and a recognizable icon or shape where appropriate.

Meaningful status changes must be available to assistive technology without
moving keyboard focus. Announce changes that affect the user's next action,
availability, or a final result, and coalesce frequent updates. Do not announce
every internal phase, streamed fragment, progress tick, or decorative update.
Critical feedback and focus indicators must appear immediately rather than
waiting for an entrance animation.

This follows WCAG's requirement that status messages be programmatically
determinable without receiving focus and its intent to avoid unnecessary
interruption ([WCAG Status Messages]).

## Review with the values

Use the values before checking individual pixels or component conventions:

- **Natural:** Does the interaction fit the user's existing mental model and
  preserve continuity while work changes?
- **Certain:** Can the user discover the state of relevant work regardless of
  focus or whether a new event just arrived? Does the UI distinguish claims
  from evidence and uncertainty from failure?
- **Meaningful:** Does every signal change understanding or enable an action?
  Is interruption proportional to the user's agency, and does motion explain
  something that would otherwise be lost?
- **Growing:** Can capability expand without destabilizing familiar workflows?
  Are complexity and advanced controls disclosed progressively while
  consequences remain explicit?

Then verify the non-negotiable guardrails: readable content never flashes or
moves while it must be read; ongoing work remains observable while active and
its consequential outcome remains available; progress is honest; recovery
preserves unrelated work; and the complete workflow remains understandable with
motion disabled.

## Sources and attribution

SeekMoon's top-level experience values—**Natural**, **Certain**,
**Meaningful**, and **Growing**—are adapted from Ant Design's
[Design Values][Ant Design Values] ([source file][Ant Design Values source])
and reinterpreted here for an agentic software-development workspace. The
explanations and implications in this guide are SeekMoon's own; this
attribution does not imply that SeekMoon uses the Ant Design component
framework or is affiliated with or endorsed by Ant Design.

Ant Design publishes the Design Values source in its MIT-licensed repository
([license][Ant Design License], Copyright (c) 2015-present Ant UED). The license
permits use and modification of software and associated documentation and
requires its copyright and permission notice to accompany copies or
substantial portions. This guide adopts only the four value names and gives
them original interpretations; it does not reproduce Ant Design's explanatory
prose, components, logo, or visual identity. The attribution is retained
deliberately even though this is not a substantial copy. Any future substantial
reuse must include the upstream copyright and full MIT permission notice. Ant
Design's name is used here only to identify the source.

The following primary sources further informed the derived guidance. They are
references for principles, not framework or component dependencies.

- [Fluent Design Principles], [Fluent Motion], [Fluent Wait UX], and
  [Fluent Progress]: functional and emotional framing, purposeful motion,
  easing, wait thresholds, contextual feedback, and honest progress.
- [Atlassian Motion] and [Atlassian Applying Motion]: semantic motion roles,
  duration ranges, attention management, entrance and exit behavior, and
  reduced motion.
- [VS Code Notifications] and [VS Code Status Bar]: contextual progress,
  notification restraint, background status, cancellation, and modal use in a
  high-density developer tool.
- [WCAG Pause, Stop, Hide], [W3C Technique C39], and [WCAG Status Messages]:
  accessibility requirements and techniques for persistent motion, platform
  motion preferences, and non-interrupting status announcements.
- [Apple Motion], [Apple Feedback], [Apple Accessibility], and
  [Apple Design Principles]: purposeful motion, proportional interruption,
  recovery, and multimodal feedback.
- [Human-AI Interaction Guidelines]: expectation setting, uncertainty,
  dismissal, correction, explanation, and user control for AI-driven behavior.

[Apple Accessibility]: https://developer.apple.com/design/human-interface-guidelines/accessibility
[Apple Design Principles]: https://developer.apple.com/design/human-interface-guidelines/design-principles
[Apple Feedback]: https://developer.apple.com/design/human-interface-guidelines/feedback
[Apple Motion]: https://developer.apple.com/design/human-interface-guidelines/motion
[Atlassian Applying Motion]: https://atlassian.design/foundations/motion/applying-motion
[Atlassian Motion]: https://atlassian.design/foundations/motion
[Ant Design License]: https://github.com/ant-design/ant-design/blob/master/LICENSE
[Ant Design Values]: https://ant.design/docs/spec/values/
[Ant Design Values source]: https://github.com/ant-design/ant-design/blob/master/docs/spec/values.en-US.md
[Fluent Design Principles]: https://fluent2.microsoft.design/design-principles
[Fluent Motion]: https://fluent2.microsoft.design/motion
[Fluent Progress]: https://fluent2.microsoft.design/components/web/react/core/progressbar/usage
[Fluent Wait UX]: https://fluent2.microsoft.design/wait-ux
[Human-AI Interaction Guidelines]: https://www.microsoft.com/en-us/haxtoolkit/ai-guidelines/
[VS Code Notifications]: https://code.visualstudio.com/api/ux-guidelines/notifications
[VS Code Status Bar]: https://code.visualstudio.com/api/ux-guidelines/status-bar
[WCAG Pause, Stop, Hide]: https://www.w3.org/WAI/WCAG22/Understanding/pause-stop-hide.html
[W3C Technique C39]: https://www.w3.org/WAI/WCAG22/Techniques/css/C39
[WCAG Status Messages]: https://www.w3.org/WAI/WCAG22/Understanding/status-messages.html
