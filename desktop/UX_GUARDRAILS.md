# Desktop UX operational guardrails

This document provides shared implementation defaults for the experience values
and interaction principles in [`UX_GUIDELINES.md`](UX_GUIDELINES.md). Read the
core guidelines first; consult this document when designing or reviewing
feedback, progress, motion, recovery, or perceivable state.

These guardrails are not additional product values and do not prescribe a
feature-specific state machine. A feature may become more specific, but should
not weaken them. The normative terms **must**, **must not**, **never**, **do
not**, **should**, **prefer**, and **avoid** inherit the meanings defined in the
core guidelines.

## Feedback and activity

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

## Motion and attention

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

## Reduced motion

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

## Control and recovery

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

## Perceivable state

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

## Sources and attribution

SeekMoon's top-level experience values—**Natural**, **Certain**,
**Meaningful**, and **Growing**—are adapted from Ant Design's
[Design Values][Ant Design Values] ([source file][Ant Design Values source])
and reinterpreted for an agentic software-development workspace. The
explanations and implications in [`UX_GUIDELINES.md`](UX_GUIDELINES.md) are
SeekMoon's own; this attribution does not imply that SeekMoon uses the Ant
Design component framework or is affiliated with or endorsed by Ant Design.

Ant Design publishes the Design Values source in its MIT-licensed repository
([license][Ant Design License], Copyright (c) 2015-present Ant UED). The license
permits use and modification of software and associated documentation and
requires its copyright and permission notice to accompany copies or
substantial portions. The core guide adopts only the four value names and gives
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
